//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

protocol PhotoCaptureDelegate: AnyObject {

    // MARK: Still Photo

    func photoCaptureDidStartPhotoCapture(_ photoCapture: PhotoCapture)
    func photoCapture(_ photoCapture: PhotoCapture, didFinishProcessingAttachment attachment: SignalAttachment)
    func photoCapture(_ photoCapture: PhotoCapture, processingDidError error: Error)

    // MARK: Video

    func photoCaptureDidBeginVideo(_ photoCapture: PhotoCapture)
    func photoCaptureDidCompleteVideo(_ photoCapture: PhotoCapture)
    func photoCaptureDidCancelVideo(_ photoCapture: PhotoCapture)

    // MARK: Utility

    func photoCapture(_ photoCapture: PhotoCapture, didChangeOrientation: AVCaptureVideoOrientation)
    func photoCaptureCanCaptureMoreItems(_ photoCapture: PhotoCapture) -> Bool
    func photoCaptureDidTryToCaptureTooMany(_ photoCapture: PhotoCapture)
    var zoomScaleReferenceHeight: CGFloat? { get }

    func beginCaptureButtonAnimation(_ duration: TimeInterval)
    func endCaptureButtonAnimation(_ duration: TimeInterval)
}

@objc
class PhotoCapture: NSObject {

    weak var delegate: PhotoCaptureDelegate?

    // There can only ever be one `CapturePreviewView` per AVCaptureSession
    lazy private(set) var previewView = CapturePreviewView(session: session)

    private let sessionQueue = DispatchQueue(label: "PhotoCapture.sessionQueue")

    private var currentCaptureInput: AVCaptureDeviceInput?
    private let captureOutput: CaptureOutput
    private var captureDevice: AVCaptureDevice? {
        return currentCaptureInput?.device
    }
    private(set) var desiredPosition: AVCaptureDevice.Position = .back

    private var _captureOrientation: AVCaptureVideoOrientation = .portrait
    var captureOrientation: AVCaptureVideoOrientation {
        get {
            assertIsOnSessionQueue()
            return _captureOrientation
        }
        set {
            assertIsOnSessionQueue()
            _captureOrientation = newValue
        }
    }

    private let recordingAudioActivity = AudioActivity(audioDescription: "PhotoCapture", behavior: .playAndRecord)

    override init() {
        self.session = AVCaptureSession()
        self.captureOutput = CaptureOutput()
    }

    // MARK: - Dependencies

    private var audioSession: OWSAudioSession {
        return Environment.shared.audioSession
    }

    private var audioDeviceInput: AVCaptureDeviceInput?

    // MARK: - Public

    public var flashMode: AVCaptureDevice.FlashMode {
        return captureOutput.flashMode
    }

    public let session: AVCaptureSession

    public func startAudioCapture() throws {
        assertIsOnSessionQueue()

        guard audioSession.startAudioActivity(recordingAudioActivity) else {
            throw PhotoCaptureError.assertionError(description: "unable to capture audio activity")
        }

        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }

        let audioDevice = AVCaptureDevice.default(for: .audio)
        // verify works without audio permissions
        let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)
        if session.canAddInput(audioDeviceInput) {
            //                self.session.addInputWithNoConnections(audioDeviceInput)
            session.addInput(audioDeviceInput)
            self.audioDeviceInput = audioDeviceInput
        } else {
            owsFailDebug("Could not add audio device input to the session")
        }
    }

    public func stopAudioCapture() {
        assertIsOnSessionQueue()

        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }

        guard let audioDeviceInput = self.audioDeviceInput else {
            owsFailDebug("audioDevice was unexpectedly nil")
            return
        }
        session.removeInput(audioDeviceInput)
        self.audioDeviceInput = nil
        audioSession.endAudioActivity(recordingAudioActivity)
    }

    @objc
    public func orientationDidChange(notification: Notification) {
        AssertIsOnMainThread()
        guard let captureOrientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation) else {
            return
        }

        sessionQueue.async {
            guard captureOrientation != self.captureOrientation else {
                return
            }
            self.captureOrientation = captureOrientation

            DispatchQueue.main.async {
                self.delegate?.photoCapture(self, didChangeOrientation: captureOrientation)
            }
        }
    }

    func updateVideoPreviewConnection(toOrientation orientation: AVCaptureVideoOrientation) {
        guard let videoConnection = previewView.previewLayer.connection else {
            Logger.info("previewView hasn't completed setup yet.")
            return
        }
        videoConnection.videoOrientation = orientation
    }

    public func startVideoCapture() -> Promise<Void> {
        AssertIsOnMainThread()

        // If the session is already running, no need to do anything.
        guard !self.session.isRunning else { return Promise.value(()) }

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(orientationDidChange),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: UIDevice.current)
        let initialCaptureOrientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation) ?? .portrait

        return sessionQueue.async(.promise) { [weak self] in
            guard let self = self else { return }
            guard let delegate = self.delegate else { return }

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            self.captureOrientation = initialCaptureOrientation
            self.session.sessionPreset = .medium

            try self.updateCurrentInput(position: .back)

            guard let photoOutput = self.captureOutput.photoOutput else {
                throw PhotoCaptureError.initializationFailed
            }

            guard self.session.canAddOutput(photoOutput) else {
                throw PhotoCaptureError.initializationFailed
            }

            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                connection.videoOrientation = self.captureOrientation
            }

            self.session.addOutput(photoOutput)

            let movieOutput = self.captureOutput.movieOutput

            if self.session.canAddOutput(movieOutput) {
                self.session.addOutput(movieOutput)
                guard let connection = movieOutput.connection(with: .video) else {
                    throw PhotoCaptureError.initializationFailed
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                connection.videoOrientation = self.captureOrientation

                if #available(iOS 11.0, *) {
                    guard movieOutput.availableVideoCodecTypes.contains(.h264) else {
                        throw PhotoCaptureError.initializationFailed
                    }
                    // Use the H.264 codec to encode the video rather than HEVC.
                    // Before iOS11, HEVC wasn't supported and H.264 was the default.
                    movieOutput.setOutputSettings([AVVideoCodecKey:
                        AVVideoCodecType.h264], for: connection)
                }
            }
        }.done {
            let captureOrientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation) ?? .portrait
            self.updateVideoPreviewConnection(toOrientation: captureOrientation)
        }.done(on: sessionQueue) {
            self.session.startRunning()
        }
    }

    public func stopCapture() -> Guarantee<Void> {
        return sessionQueue.async(.promise) {
            self.session.stopRunning()
        }
    }

    public func assertIsOnSessionQueue() {
        assertOnQueue(sessionQueue)
    }

    public func switchCamera() -> Promise<Void> {
        AssertIsOnMainThread()
        let newPosition: AVCaptureDevice.Position
        switch desiredPosition {
        case .front:
            newPosition = .back
        case .back:
            newPosition = .front
        case .unspecified:
            newPosition = .front
        @unknown default:
            owsFailDebug("Unexpected enum value.")
            newPosition = .front
            break
        }
        desiredPosition = newPosition

        return sessionQueue.async(.promise) { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            try self.updateCurrentInput(position: newPosition)
        }
    }

    // This method should be called on the serial queue,
    // and between calls to session.beginConfiguration/commitConfiguration
    public func updateCurrentInput(position: AVCaptureDevice.Position) throws {
        assertIsOnSessionQueue()

        guard let device = captureOutput.videoDevice(position: position) else {
            throw PhotoCaptureError.assertionError(description: description)
        }

        let newInput = try AVCaptureDeviceInput(device: device)

        if let oldInput = self.currentCaptureInput {
            session.removeInput(oldInput)
            NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceSubjectAreaDidChange, object: oldInput.device)
        }
        session.addInput(newInput)
        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange), name: .AVCaptureDeviceSubjectAreaDidChange, object: newInput.device)

        currentCaptureInput = newInput

        resetFocusAndExposure()
    }

    public func switchFlashMode() -> Guarantee<Void> {
        return sessionQueue.async(.promise) {
            switch self.captureOutput.flashMode {
            case .auto:
                Logger.debug("new flashMode: on")
                self.captureOutput.flashMode = .on
            case .on:
                Logger.debug("new flashMode: off")
                self.captureOutput.flashMode = .off
            case .off:
                Logger.debug("new flashMode: auto")
                self.captureOutput.flashMode = .auto
            @unknown default:
                owsFailDebug("unknown flashMode: \(self.captureOutput.flashMode)")
                self.captureOutput.flashMode = .auto
            }
        }
    }

    public func focus(with focusMode: AVCaptureDevice.FocusMode,
               exposureMode: AVCaptureDevice.ExposureMode,
               at devicePoint: CGPoint,
               monitorSubjectAreaChange: Bool) {
        sessionQueue.async {
            Logger.debug("focusMode: \(focusMode), exposureMode: \(exposureMode), devicePoint: \(devicePoint), monitorSubjectAreaChange:\(monitorSubjectAreaChange)")
            guard let device = self.captureDevice else {
                owsFailDebug("device was unexpectedly nil")
                return
            }
            do {
                try device.lockForConfiguration()

                // Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
                // Call set(Focus/Exposure)Mode() to apply the new point of interest.
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = focusMode
                }

                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = exposureMode
                }

                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch {
                owsFailDebug("error: \(error)")
            }
        }
    }

    public func resetFocusAndExposure() {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
    }

    @objc
    private func subjectAreaDidChange(notification: NSNotification) {
        resetFocusAndExposure()
    }

    // MARK: - Zoom

    private let minimumZoom: CGFloat = 1.0
    private let maximumZoom: CGFloat = 3.0
    private var previousZoomFactor: CGFloat = 1.0

    public func updateZoom(alpha: CGFloat) {
        assert(alpha >= 0 && alpha <= 1)
        sessionQueue.async {
            guard let captureDevice = self.captureDevice else {
                owsFailDebug("captureDevice was unexpectedly nil")
                return
            }

            // we might want this to be non-linear
            let scale = CGFloatLerp(self.minimumZoom, self.maximumZoom, alpha)
            let zoomFactor = self.clampZoom(scale, device: captureDevice)
            self.updateZoom(factor: zoomFactor)
        }
    }

    public func updateZoom(scaleFromPreviousZoomFactor scale: CGFloat) {
        sessionQueue.async {
            guard let captureDevice = self.captureDevice else {
                owsFailDebug("captureDevice was unexpectedly nil")
                return
            }

            let zoomFactor = self.clampZoom(scale * self.previousZoomFactor, device: captureDevice)
            self.updateZoom(factor: zoomFactor)
        }
    }

    public func completeZoom(scaleFromPreviousZoomFactor scale: CGFloat) {
        sessionQueue.async {
            guard let captureDevice = self.captureDevice else {
                owsFailDebug("captureDevice was unexpectedly nil")
                return
            }

            let zoomFactor = self.clampZoom(scale * self.previousZoomFactor, device: captureDevice)

            Logger.debug("ended with scaleFactor: \(zoomFactor)")

            self.previousZoomFactor = zoomFactor
            self.updateZoom(factor: zoomFactor)
        }
    }

    private func updateZoom(factor: CGFloat) {
        assertIsOnSessionQueue()

        guard let captureDevice = self.captureDevice else {
            owsFailDebug("captureDevice was unexpectedly nil")
            return
        }

        do {
            try captureDevice.lockForConfiguration()
            captureDevice.videoZoomFactor = factor
            captureDevice.unlockForConfiguration()
        } catch {
            owsFailDebug("error: \(error)")
        }
    }

    private func clampZoom(_ factor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        return min(factor.clamp(minimumZoom, maximumZoom), device.activeFormat.videoMaxZoomFactor)
    }

    // MARK: - Photo
    private func handleTap() {
        Logger.verbose("")
        guard let delegate = delegate else { return }
        guard delegate.photoCaptureCanCaptureMoreItems(self) else {
            delegate.photoCaptureDidTryToCaptureTooMany(self)
            return
        }

        delegate.photoCaptureDidStartPhotoCapture(self)
        sessionQueue.async {
            self.captureOutput.takePhoto(delegate: self)
        }
    }

    // MARK: - Video

    private func handleLongPressBegin() {
        AssertIsOnMainThread()
        Logger.verbose("")

        guard let delegate = delegate else { return }
        guard delegate.photoCaptureCanCaptureMoreItems(self) else {
            delegate.photoCaptureDidTryToCaptureTooMany(self)
            return
        }

        sessionQueue.async(.promise) {
            try self.startAudioCapture()
            self.captureOutput.beginVideo(delegate: self)
        }.done {
            self.delegate?.photoCaptureDidBeginVideo(self)
        }.catch { error in
            self.delegate?.photoCapture(self, processingDidError: error)
        }.retainUntilComplete()
    }

    private func handleLongPressComplete() {
        Logger.verbose("")
        sessionQueue.async {
            self.captureOutput.completeVideo(delegate: self)
            self.stopAudioCapture()
        }
        AssertIsOnMainThread()
        // immediately inform UI that capture is stopping
        delegate?.photoCaptureDidCompleteVideo(self)
    }

    private func handleLongPressCancel() {
        Logger.verbose("")
        AssertIsOnMainThread()
        sessionQueue.async {
            self.stopAudioCapture()
        }
        delegate?.photoCaptureDidCancelVideo(self)
    }
}

extension PhotoCapture: VolumeButtonObserver {
    func didPressVolumeButton(with identifier: VolumeButtons.Identifier) {
        delegate?.beginCaptureButtonAnimation(0.5)
    }

    func didReleaseVolumeButton(with identifier: VolumeButtons.Identifier) {
        delegate?.endCaptureButtonAnimation(0.2)
    }

    func didTapVolumeButton(with identifier: VolumeButtons.Identifier) {
        handleTap()
    }

    func didBeginLongPressVolumeButton(with identifier: VolumeButtons.Identifier) {
        handleLongPressBegin()
    }

    func didCompleteLongPressVolumeButton(with identifier: VolumeButtons.Identifier) {
        handleLongPressComplete()
    }

    func didCancelLongPressVolumeButton(with identifier: VolumeButtons.Identifier) {
        handleLongPressCancel()
    }
}

extension PhotoCapture: CaptureButtonDelegate {
    func didTapCaptureButton(_ captureButton: CaptureButton) {
        handleTap()
    }

    func didBeginLongPressCaptureButton(_ captureButton: CaptureButton) {
        handleLongPressBegin()
    }

    func didCompleteLongPressCaptureButton(_ captureButton: CaptureButton) {
        handleLongPressComplete()
    }

    func didCancelLongPressCaptureButton(_ captureButton: CaptureButton) {
        handleLongPressCancel()
    }

    var zoomScaleReferenceHeight: CGFloat? {
        return delegate?.zoomScaleReferenceHeight
    }

    func longPressCaptureButton(_ captureButton: CaptureButton, didUpdateZoomAlpha zoomAlpha: CGFloat) {
        updateZoom(alpha: zoomAlpha)
    }
}

extension PhotoCapture: CaptureOutputDelegate {

    // MARK: - Photo

    func captureOutputDidFinishProcessing(photoData: Data?, error: Error?) {
        Logger.verbose("")
        AssertIsOnMainThread()

        if let error = error {
            delegate?.photoCapture(self, processingDidError: error)
            return
        }

        guard let photoData = photoData else {
            owsFailDebug("photoData was unexpectedly nil")
            delegate?.photoCapture(self, processingDidError: PhotoCaptureError.captureFailed)

            return
        }

        let dataSource = DataSourceValue.dataSource(with: photoData, utiType: kUTTypeJPEG as String)

        let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeJPEG as String, imageQuality: .medium)
        delegate?.photoCapture(self, didFinishProcessingAttachment: attachment)
    }

    // MARK: - Movie

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Logger.verbose("")
        AssertIsOnMainThread()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Logger.verbose("")
        AssertIsOnMainThread()

        if let error = error {
            guard didSucceedDespiteError(error) else {
                delegate?.photoCapture(self, processingDidError: error)
                return
            }
            Logger.info("Ignoring error, since capture succeeded.")
        }

        guard let dataSource = try? DataSourcePath.dataSource(with: outputFileURL, shouldDeleteOnDeallocation: true) else {
            delegate?.photoCapture(self, processingDidError: PhotoCaptureError.captureFailed)
            return
        }

        // AVCaptureMovieFileOutput records to .mov, but for compatibility we need to send mp4's.
        // Because we take care to record with h264 compression (not hevc), this conversion
        // doesn't require re-encoding the media streams and happens quickly.
        let (attachmentPromise, _) = SignalAttachment.compressVideoAsMp4(dataSource: dataSource, dataUTI: kUTTypeMPEG4 as String)
        attachmentPromise.map { [weak self] attachment in
            guard let self = self else { return }
            self.delegate?.photoCapture(self, didFinishProcessingAttachment: attachment)
        }.retainUntilComplete()
    }

    /// The AVCaptureFileOutput can return an error even though recording succeeds.
    /// I can't find useful documentation on this, but Apple's example AVCam app silently
    /// discards these errors, so we do the same.
    /// These spurious errors can be reproduced 1/3 of the time when making a series of short videos.
    private func didSucceedDespiteError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard let successfullyFinished = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool else {
            return false
        }

        return successfullyFinished
    }
}

// MARK: - Capture Adapter

protocol CaptureOutputDelegate: AVCaptureFileOutputRecordingDelegate {
    var session: AVCaptureSession { get }
    func assertIsOnSessionQueue()
    func captureOutputDidFinishProcessing(photoData: Data?, error: Error?)
    var captureOrientation: AVCaptureVideoOrientation { get }
}

protocol ImageCaptureOutput: AnyObject {
    var avOutput: AVCaptureOutput { get }
    var flashMode: AVCaptureDevice.FlashMode { get set }
    func videoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice?

    func takePhoto(delegate: CaptureOutputDelegate)
}

class CaptureOutput {

    let imageOutput: ImageCaptureOutput
    let movieOutput: AVCaptureMovieFileOutput

    // MARK: - Init

    init() {
        if #available(iOS 10.0, *) {
            imageOutput = PhotoCaptureOutputAdaptee()
        } else {
            imageOutput = StillImageCaptureOutput()
        }

        movieOutput = AVCaptureMovieFileOutput()
        // disable movie fragment writing since it's not supported on mp4
        // leaving it enabled causes all audio to be lost on videos longer
        // than the default length (10s).
        movieOutput.movieFragmentInterval = CMTime.invalid
    }

    var photoOutput: AVCaptureOutput? {
        return imageOutput.avOutput
    }

    var flashMode: AVCaptureDevice.FlashMode {
        get { return imageOutput.flashMode }
        set { imageOutput.flashMode = newValue }
    }

    func videoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        return imageOutput.videoDevice(position: position)
    }

    func takePhoto(delegate: CaptureOutputDelegate) {
        delegate.assertIsOnSessionQueue()

        guard let photoOutput = photoOutput else {
            owsFailDebug("photoOutput was unexpectedly nil")
            return
        }

        guard let photoVideoConnection = photoOutput.connection(with: .video) else {
            owsFailDebug("photoVideoConnection was unexpectedly nil")
            return
        }

        let videoOrientation = delegate.captureOrientation
        photoVideoConnection.videoOrientation = videoOrientation
        Logger.verbose("videoOrientation: \(videoOrientation), deviceOrientation: \(UIDevice.current.orientation)")

        return imageOutput.takePhoto(delegate: delegate)
    }

    // MARK: - Movie Output

    func beginVideo(delegate: CaptureOutputDelegate) {
        delegate.assertIsOnSessionQueue()
        guard let videoConnection = movieOutput.connection(with: .video) else {
            owsFailDebug("videoConnection was unexpectedly nil")
            return
        }

        let videoOrientation = delegate.captureOrientation
        videoConnection.videoOrientation = videoOrientation

        let outputFilePath = OWSFileSystem.temporaryFilePath(withFileExtension: "mp4")
        movieOutput.startRecording(to: URL(fileURLWithPath: outputFilePath), recordingDelegate: delegate)
    }

    func completeVideo(delegate: CaptureOutputDelegate) {
        delegate.assertIsOnSessionQueue()
        movieOutput.stopRecording()
    }

    func cancelVideo(delegate: CaptureOutputDelegate) {
        delegate.assertIsOnSessionQueue()
        // There's currently no user-visible way to cancel, if so, we may need to do some cleanup here.
        owsFailDebug("video was unexpectedly canceled.")
    }
}

@available(iOS 10.0, *)
class PhotoCaptureOutputAdaptee: NSObject, ImageCaptureOutput {

    let photoOutput = AVCapturePhotoOutput()
    var avOutput: AVCaptureOutput {
        return photoOutput
    }

    var flashMode: AVCaptureDevice.FlashMode = .off

    override init() {
        photoOutput.isLivePhotoCaptureEnabled = false
        photoOutput.isHighResolutionCaptureEnabled = true
    }

    private var photoProcessors: [Int64: PhotoProcessor] = [:]

    func takePhoto(delegate: CaptureOutputDelegate) {
        delegate.assertIsOnSessionQueue()

        let settings = buildCaptureSettings()

        let photoProcessor = PhotoProcessor(delegate: delegate, completion: { [weak self] in
            self?.photoProcessors[settings.uniqueID] = nil
        })
        photoProcessors[settings.uniqueID] = photoProcessor
        photoOutput.capturePhoto(with: settings, delegate: photoProcessor)
    }

    func videoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // use dual camera where available
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    // MARK: -

    private func buildCaptureSettings() -> AVCapturePhotoSettings {
        let photoSettings = AVCapturePhotoSettings()
        photoSettings.flashMode = flashMode
        photoSettings.isHighResolutionPhotoEnabled = true

        photoSettings.isAutoStillImageStabilizationEnabled =
            photoOutput.isStillImageStabilizationSupported

        return photoSettings
    }

    private class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
        weak var delegate: CaptureOutputDelegate?
        let completion: () -> Void

        init(delegate: CaptureOutputDelegate, completion: @escaping () -> Void) {
            self.delegate = delegate
            self.completion = completion
        }

        @available(iOS 11.0, *)
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            let data = photo.fileDataRepresentation()
            DispatchQueue.main.async {
                self.delegate?.captureOutputDidFinishProcessing(photoData: data, error: error)
            }
            completion()
        }

        // for legacy (iOS10) devices
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {
            if #available(iOS 11, *) {
                owsFailDebug("unexpectedly calling legacy method.")
            }

            guard let photoSampleBuffer = photoSampleBuffer else {
                owsFailDebug("sampleBuffer was unexpectedly nil")
                return
            }

            let data = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(photoSampleBuffer)
            DispatchQueue.main.async {
                self.delegate?.captureOutputDidFinishProcessing(photoData: data, error: error)
            }
            completion()
        }
    }
}

class StillImageCaptureOutput: ImageCaptureOutput {
    var flashMode: AVCaptureDevice.FlashMode = .off

    let stillImageOutput = AVCaptureStillImageOutput()
    var avOutput: AVCaptureOutput {
        return stillImageOutput
    }

    init() {
        stillImageOutput.isHighResolutionStillImageOutputEnabled = true
    }

    // MARK: -

    func takePhoto(delegate: CaptureOutputDelegate) {
        guard let videoConnection = stillImageOutput.connection(with: .video) else {
            owsFailDebug("videoConnection was unexpectedly nil")
            return
        }

        stillImageOutput.captureStillImageAsynchronously(from: videoConnection) { [weak delegate] (sampleBuffer, error) in
            guard let sampleBuffer = sampleBuffer else {
                owsFailDebug("sampleBuffer was unexpectedly nil")
                return
            }

            let data = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(sampleBuffer)
            DispatchQueue.main.async {
                delegate?.captureOutputDidFinishProcessing(photoData: data, error: error)
            }
        }
    }

    func videoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let captureDevices = AVCaptureDevice.devices()
        guard let device = (captureDevices.first { $0.hasMediaType(.video) && $0.position == position }) else {
            Logger.debug("unable to find desired position: \(position)")
            return captureDevices.first
        }

        return device
    }
}

extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .unknown:
            return nil
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeRight
        case .landscapeRight: self = .landscapeLeft
        case .faceUp:
            return nil
        case .faceDown:
            return nil
        @unknown default:
            return nil
        }
    }

    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .unknown:
            return nil
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        @unknown default:
            return nil
        }
    }
}

extension AVCaptureDevice.FocusMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .locked:
            return "FocusMode.locked"
        case .autoFocus:
            return "FocusMode.autoFocus"
        case .continuousAutoFocus:
            return "FocusMode.continuousAutoFocus"
        @unknown default:
            return "FocusMode.unknown"
        }
    }
}

extension AVCaptureDevice.ExposureMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .locked:
            return "ExposureMode.locked"
        case .autoExpose:
            return "ExposureMode.autoExpose"
        case .continuousAutoExposure:
            return "ExposureMode.continuousAutoExposure"
        case .custom:
            return "ExposureMode.custom"
        @unknown default:
            return "ExposureMode.unknown"
        }
    }
}

extension AVCaptureVideoOrientation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .portrait:
            return "AVCaptureVideoOrientation.portrait"
        case .portraitUpsideDown:
            return "AVCaptureVideoOrientation.portraitUpsideDown"
        case .landscapeRight:
            return "AVCaptureVideoOrientation.landscapeRight"
        case .landscapeLeft:
            return "AVCaptureVideoOrientation.landscapeLeft"
        @unknown default:
            return "AVCaptureVideoOrientation.unknownDefault"
        }
    }
}

extension UIDeviceOrientation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown:
            return "UIDeviceOrientation.unknown"
        case .portrait:
            return "UIDeviceOrientation.portrait"
        case .portraitUpsideDown:
            return "UIDeviceOrientation.portraitUpsideDown"
        case .landscapeLeft:
            return "UIDeviceOrientation.landscapeLeft"
        case .landscapeRight:
            return "UIDeviceOrientation.landscapeRight"
        case .faceUp:
            return "UIDeviceOrientation.faceUp"
        case .faceDown:
            return "UIDeviceOrientation.faceDown"
        @unknown default:
            return "UIDeviceOrientation.unknownDefault"
        }
    }
}

extension UIInterfaceOrientation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown:
            return "UIInterfaceOrientation.unknown"
        case .portrait:
            return "UIInterfaceOrientation.portrait"
        case .portraitUpsideDown:
            return "UIInterfaceOrientation.portraitUpsideDown"
        case .landscapeLeft:
            return "UIInterfaceOrientation.landscapeLeft"
        case .landscapeRight:
            return "UIInterfaceOrientation.landscapeRight"
        @unknown default:
            return "UIInterfaceOrientation.unknownDefault"
        }
    }
}

extension UIImage.Orientation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .up:
            return "UIImageOrientation.up"
        case .down:
            return "UIImageOrientation.down"
        case .left:
            return "UIImageOrientation.left"
        case .right:
            return "UIImageOrientation.right"
        case .upMirrored:
            return "UIImageOrientation.upMirrored"
        case .downMirrored:
            return "UIImageOrientation.downMirrored"
        case .leftMirrored:
            return "UIImageOrientation.leftMirrored"
        case .rightMirrored:
            return "UIImageOrientation.rightMirrored"
        @unknown default:
            return "UIImageOrientation.unknownDefault"
        }
    }
}

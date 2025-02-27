//
//  Copyright 2022 • Sidetrack Tech Limited
//

import Foundation
import SwiftUI
import AVKit
import Combine
import os.log

public final class PipifyController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate,
                                       AVPictureInPictureSampleBufferPlaybackDelegate {
    
    public static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }
    
    @Published public var renderSize: CGSize = .zero
    @Published public var isPlaying: Bool = true
    
    @Published public var enabled: Bool = false
    internal var isPlayPauseEnabled = false
    
    internal var onSkip: ((Double) -> Void)? = nil {
        didSet {
            pipController?.requiresLinearPlayback = onSkip == nil
            pipController?.invalidatePlaybackState()
        }
    }
    
    internal var progress: Double = 1 {
        didSet {
            pipController?.invalidatePlaybackState()
        }
    }
    
    internal let bufferLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var rendererSubscriptions = Set<AnyCancellable>()
    private var pipPossibleObservation: NSKeyValueObservation?
    private var currentView: UIView?
    
    static func setupAudioSession() {
        #if !os(macOS)
        logger.info("configuring audio session")
        let session = AVAudioSession.sharedInstance()
        
        if session.category == .soloAmbient || session.mode == .default {
            try? session.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
        }
        #endif
    }
    
    public override init() {
        super.init()
        Self.setupAudioSession()
        setupController()
    }

    private func setupController() {
        logger.info("creating pip controller")
        
        bufferLayer.frame.size = .init(width: 300, height: 100)
        bufferLayer.videoGravity = .resizeAspect
        
        pipController = AVPictureInPictureController(contentSource: .init(
            sampleBufferDisplayLayer: bufferLayer,
            playbackDelegate: self
        ))
        
        pipController?.requiresLinearPlayback = onSkip == nil
        pipController?.delegate = self
    }
    
    private func screenshot(view: UIView) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, false, 0)
        defer { UIGraphicsEndImageContext() }
        
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    private func convertToBuffer(image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: cgImage.toPixelBuffer()!,
            formatDescriptionOut: &format
        )
        
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime.zero,
            decodeTimeStamp: CMTime.invalid
        )
        
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: cgImage.toPixelBuffer()!,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        
        return sampleBuffer
    }
    
    @MainActor func setView(_ view: some View, maximumUpdatesPerSecond: Double = 30) {
        let view = UIHostingController(rootView: view).view!
        
        self.currentView = view
        
        Timer.publish(every: 1.0 / maximumUpdatesPerSecond, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let view = self.currentView else { return }
                if let image = self.screenshot(view: view),
                   let buffer = self.convertToBuffer(image: image) {
                    self.render(buffer: buffer)
                }
            }
            .store(in: &rendererSubscriptions)
        
        // First draw
        if let image = screenshot(view: view),
           let buffer = convertToBuffer(image: image) {
            render(buffer: buffer)
        }
    }
    
    private func render(buffer: CMSampleBuffer) {
        if bufferLayer.status == .failed {
            bufferLayer.flush()
        }
        
        bufferLayer.enqueue(buffer)
    }
    
    // MARK: - Lifecycle
    
    internal func start() {
        guard let pipController else {
            logger.warning("could not start: no controller")
            return
        }
        
        guard pipController.isPictureInPictureActive == false else {
            logger.warning("could not start: already active")
            return
        }
        
        #if !os(macOS)
        logger.info("activating audio session")
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        
        // force the timestamp to update
        pipController.invalidatePlaybackState()
        
        if pipController.isPictureInPicturePossible {
            logger.info("starting picture in picture")
            pipController.startPictureInPicture()
        } else {
            logger.info("waiting for pip to be possible")
            
            // not currently possible, so wait until it is.
            let keyPath = \AVPictureInPictureController.isPictureInPicturePossible
            pipPossibleObservation = pipController.observe(keyPath, options: [ .new ]) { [weak self] controller, change in
                if change.newValue ?? false {
                    logger.info("starting picture in picture")
                    controller.startPictureInPicture()
                    self?.pipPossibleObservation = nil
                }
            }
        }
    }
    
    internal func stop() {
        guard let pipController else {
            logger.warning("could not stop: no controller")
            return
        }
        
        logger.info("stopping picture in picture")
        pipController.stopPictureInPicture()
        
        #if !os(macOS)
        logger.info("deactivating audio session")
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }
    
    // MARK: - AVPictureInPictureControllerDelegate

    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        logger.info("didStart")
    }
    
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        logger.info("didStop")
        enabled = false
    }
    
    public func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // We do not support audio through the pipify controller, as such we will allow other background audio to
        // continue playing
        return false
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        logger.error("failed to start: \(error.localizedDescription)")
        enabled = false
    }
    
    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        logger.info("restore UI")
        enabled = false
        completionHandler(true)
    }
    
    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if isPlayPauseEnabled {
            DispatchQueue.main.async {
                logger.info("setPlaying: \(playing)")
                self.isPlaying = playing
                pictureInPictureController.invalidatePlaybackState()
            }
        }
    }
    
    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return isPlayPauseEnabled && isPlaying == false
    }
    
    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        if onSkip == nil && progress == 1 {
            // By returning a positive time range in conjunction with enabling `requiresLinearPlayback`
            // PIP will only show the play/pause button and hide the 'Live' label and skip buttons.
            return CMTimeRange(start: .init(value: 1, timescale: 1), end: .init(value: 2, timescale: 1))
        } else {
            let currentTime = CMTime(
                seconds: CACurrentMediaTime(),
                preferredTimescale: 120
            )
            
            // We use one week as the value needs to be large enough that a user would not feasibly see time pass.
            let oneWeek: Double = 86400 * 7
            
            let multipliers: (Double, Double)
            switch progress {
            case 0: // 0%
                multipliers = (0, 1)
            default:
                multipliers = (1, 1 / progress - 1)
            }
            
            let startScaler = CMTime(seconds: oneWeek * multipliers.0, preferredTimescale: 120)
            
            // the 20 here (can be pretty much any number) ensures that the skip forward button works
            // if we don't add this little extra then Apple believes we're at the end of the clip
            // and as such disables the skip forward button. we don't want that.
            // because our oneWeek number is so large, the 20 here isn't noticeable to users.
            let endScaler = CMTime(seconds: oneWeek * multipliers.1 + 20, preferredTimescale: 120)
            
            return CMTimeRange(start: currentTime - startScaler, end: currentTime + endScaler)
        }
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        logger.trace("window resize: \(newRenderSize.width)x\(newRenderSize.height)")
        renderSize = .init(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        logger.info("skip by: \(skipInterval.seconds) seconds")
        onSkip?(skipInterval.seconds)
    }
}

extension CGImage {
    func toPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        
        let width = self.width
        let height = self.height
        
        CVPixelBufferCreate(kCFAllocatorDefault,
                           width,
                           height,
                           kCVPixelFormatType_32ARGB,
                           attrs,
                           &pixelBuffer)
        
        guard let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                              width: width,
                              height: height,
                              bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        
        context?.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        
        return buffer
    }
}


let logger = Logger(subsystem: "com.getsidetrack.pipify", category: "Pipify")

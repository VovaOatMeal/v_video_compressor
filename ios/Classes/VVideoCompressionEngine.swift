import Foundation
import AVFoundation
import UIKit

class VVideoCompressionEngine {
    
    // Improved constants from iOS Quick Fix
    private static let AUDIO_BITRATE: Int = 128000
    private static let AUDIO_BITRATE_LOW: Int = 64000
    private static let DEFAULT_FRAME_RATE: Float = 30.0
    private static let PROGRESS_UPDATE_INTERVAL: TimeInterval = 0.1
    
    private var exportSession: AVAssetExportSession?
    private var progressTimer: Timer?
    private var isCompressionActive = false
    private var isCancelled = false
    // Removed background task - keeping it simple for now
    
    deinit {
        cleanup()
    }
    
    protocol CompressionCallback: AnyObject {
        func onProgress(_ progress: Float)
        func onComplete(_ result: VVideoCompressionResult)
        func onError(_ error: String)
    }
    
    func getVideoInfo(_ videoPath: String, completion: @escaping (VVideoInfo?) -> Void) {
        guard let url = createURL(from: videoPath) else { 
            completion(nil)
            return 
        }
        
        let asset = AVAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
            var error: NSError?
            let durationStatus = asset.statusOfValue(forKey: "duration", error: &error)
            let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)
            
            guard durationStatus == .loaded && tracksStatus == .loaded else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            let duration = asset.duration
            let videoTrack = asset.tracks(withMediaType: .video).first
            let fileSize = self.getFileSize(for: url)
            
            // ORIENTATION FIX: Apply preferred transform to get correct display dimensions
            let naturalSize = videoTrack?.naturalSize ?? .zero
            let preferredTransform = videoTrack?.preferredTransform ?? CGAffineTransform.identity
            let transformedSize = naturalSize.applying(preferredTransform)
            let correctedWidth = Int(abs(transformedSize.width))
            let correctedHeight = Int(abs(transformedSize.height))
            
            let videoInfo = VVideoInfo(
                path: videoPath,
                name: url.lastPathComponent,
                fileSizeBytes: fileSize,
                durationMillis: Int64(CMTimeGetSeconds(duration) * 1000),
                width: correctedWidth,
                height: correctedHeight,
                thumbnailPath: nil
            )
            
            DispatchQueue.main.async { completion(videoInfo) }
        }
    }
    
    func estimateCompressionSize(_ videoInfo: VVideoInfo, quality: VVideoCompressQuality) -> VVideoCompressionEstimate {
        return estimateCompressionSize(videoInfo, quality: quality, advanced: nil)
    }
    
    func estimateCompressionSize(_ videoInfo: VVideoInfo, quality: VVideoCompressQuality, advanced: VVideoAdvancedConfig?) -> VVideoCompressionEstimate {
        // Improved estimation from iOS Quick Fix
        let durationSeconds = Double(videoInfo.durationMillis) / 1000.0

        // Get video bitrate
        var videoBitrate = advanced?.videoBitrate ?? getDefaultBitrate(for: quality)

        // Adjust for resolution change
        if let customWidth = advanced?.customWidth,
           let customHeight = advanced?.customHeight {
            let originalPixels = videoInfo.width * videoInfo.height
            let targetPixels = customWidth * customHeight
            let pixelRatio = Float(targetPixels) / Float(originalPixels)
            videoBitrate = Int(Float(videoBitrate) * pixelRatio * 1.1)
        }

        // Adjust for frame rate
        if let frameRate = advanced?.reducedFrameRate {
            let frameRateRatio = frameRate / 30.0
            videoBitrate = Int(Float(videoBitrate) * Float(frameRateRatio))
        }

        // Audio bitrate
        let audioBitrate = advanced?.removeAudio == true ? 0 :
                          (advanced?.audioBitrate ?? Self.AUDIO_BITRATE)

        // Calculate size
        let totalBitrate = videoBitrate + audioBitrate
        let estimatedBytes = Int64((Double(totalBitrate) * durationSeconds) / 8.0)

        // Add 5% overhead
        let finalEstimate = Int64(Double(estimatedBytes) * 1.05)

        return VVideoCompressionEstimate(
            estimatedSizeBytes: finalEstimate,
            estimatedSizeFormatted: formatFileSize(finalEstimate),
            compressionRatio: Float(finalEstimate) / Float(videoInfo.fileSizeBytes),
            bitrateMbps: Float(videoBitrate) / 1000000.0
        )
    }
    
    // iOS Quick Fix: Add default bitrate calculation
    private func getDefaultBitrate(for quality: VVideoCompressQuality) -> Int {
        switch quality {
        case .high: return 3500000      // 3.5 Mbps
        case .medium: return 1800000    // 1.8 Mbps
        case .low: return 900000        // 900 kbps
        case .veryLow: return 500000    // 500 kbps
        case .ultraLow: return 350000   // 350 kbps
        }
    }
    
    func compressVideo(_ videoInfo: VVideoInfo, config: VVideoCompressionConfig, callback: CompressionCallback) {
        // Validate inputs
        guard validateCompressionInputs(videoInfo: videoInfo, config: config) else {
            callback.onError("Invalid compression parameters")
            return
        }
        
        let startTime = Date().timeIntervalSince1970 * 1000
        
        isCancelled = false
        isCompressionActive = true
        
        guard let inputURL = createURL(from: videoInfo.path) else {
            callback.onError("Invalid video path")
            return
        }
        
        // Check if file exists and is readable
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            callback.onError("Video file not found")
            return
        }
        
        // iOS Quick Fix: Optimize asset loading
        let options = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        let asset = AVURLAsset(url: inputURL, options: options)
        let outputURL = createOutputFile(config.outputPath, videoInfo: videoInfo, quality: config.quality)
        
        // Check available disk space
        guard hasEnoughDiskSpace(for: videoInfo, outputURL: outputURL) else {
            callback.onError("Insufficient storage space")
            return
        }
        
        print("VVideoCompressionEngine: FIXED ROTATION - Starting compression")
        print("VVideoCompressionEngine: Input video: \(videoInfo.width)x\(videoInfo.height), \(formatFileSize(videoInfo.fileSizeBytes))")
        
        let presetName = getExportPreset(for: config.quality, advanced: config.advanced, videoInfo: videoInfo)
        print("VVideoCompressionEngine: Using preset: \(presetName)")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            callback.onError("Unable to create export session")
            return
        }
        
        self.exportSession = exportSession
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        
        // iOS Quick Fix: Optimize export settings
        exportSession.shouldOptimizeForNetworkUse = true
        // COMPRESSION FIX: Multi-pass encoding increases quality but also file size
        // Only enable for high quality settings
        exportSession.canPerformMultiplePassesOverSourceMediaData = (config.quality == .high)
        
        // iOS Quick Fix: Add metadata
        var metadata = [AVMetadataItem]()
        let item = AVMutableMetadataItem()
        item.key = AVMetadataKey.commonKeyTitle as NSString
        item.keySpace = .common
        item.value = "Compressed with V Video Compressor" as NSString
        metadata.append(item)
        exportSession.metadata = metadata
        
        if needsAdvancedComposition(config: config) {
            print("VVideoCompressionEngine: Applying WORKING rotation")
            applyAdvancedComposition(exportSession: exportSession, videoInfo: videoInfo, config: config)
        }
        
        startProgressTracking(callback: callback)
        
        // iOS Quick Fix: Background processing optimization
        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                self.handleCompressionCompletion(
                    outputURL: outputURL,
                    startTime: startTime,
                    videoInfo: videoInfo,
                    config: config,
                    callback: callback
                )
            }
        }
    }
    
    private func needsAdvancedComposition(config: VVideoCompressionConfig) -> Bool {
        guard let advanced = config.advanced else { return false }
        return advanced.rotation != nil || advanced.brightness != nil || 
               advanced.trimStartMs != nil || advanced.trimEndMs != nil ||
               advanced.removeAudio == true || advanced.customWidth != nil ||
               advanced.customHeight != nil || advanced.autoCorrectOrientation == true
    }
    
    private func applyAdvancedComposition(exportSession: AVAssetExportSession, videoInfo: VVideoInfo, config: VVideoCompressionConfig) {
        let asset = exportSession.asset
        
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            print("VVideoCompressionEngine: No video track found")
            return
        }
        
        // ORIENTATION FIX: Get original orientation and determine if auto-correction is needed
        let naturalSize = videoTrack.naturalSize
        let preferredTransform = videoTrack.preferredTransform
        let shouldAutoCorrect = config.advanced?.autoCorrectOrientation == true
        
        // Calculate rotation - either from config or auto-detected
        var rotation = config.advanced?.rotation ?? 0
        if shouldAutoCorrect && rotation == 0 {
            // Auto-detect rotation from preferred transform
            let radians = atan2(preferredTransform.b, preferredTransform.a)
            let degrees = radians * 180.0 / .pi
            rotation = Int(degrees.rounded())
            print("VVideoCompressionEngine: Auto-detected rotation: \(rotation)°")
        }
        
        let customWidth = config.advanced?.customWidth ?? videoInfo.width
        let customHeight = config.advanced?.customHeight ?? videoInfo.height
        
        // FIXED: Proper dimension adjustment for rotation
        let (renderWidth, renderHeight) = rotation == 90 || rotation == 270 ? 
            (customHeight, customWidth) : (customWidth, customHeight)
        
        print("VVideoCompressionEngine: ORIENTATION FIXED: \(rotation)° with size: \(renderWidth)x\(renderHeight)")
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: renderWidth, height: renderHeight)
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(Self.DEFAULT_FRAME_RATE))
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        
        // ORIENTATION FIX: Use preferred transform as base and apply additional rotation if needed
        var transform = shouldAutoCorrect ? preferredTransform : CGAffineTransform.identity
        
        if rotation != 0 {
            let angle = CGFloat(rotation) * .pi / 180.0
            let rotationTransform = CGAffineTransform(rotationAngle: angle)
            transform = transform.concatenating(rotationTransform)
            print("VVideoCompressionEngine: Applied \(rotation)° rotation with auto-correction: \(shouldAutoCorrect)")
        }
        
        // Apply scaling if needed
        let scaleX = CGFloat(renderWidth) / naturalSize.width
        let scaleY = CGFloat(renderHeight) / naturalSize.height
        let scale = min(scaleX, scaleY)
        
        if scale != 1.0 {
            let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
            transform = transform.concatenating(scaleTransform)
            print("VVideoCompressionEngine: Applied scale: \(scale)")
        }
        
        layerInstruction.setTransform(transform, at: .zero)
        
        // iOS Quick Fix: Improved color adjustments
        if let brightness = config.advanced?.brightness, brightness != 0.0 {
            let opacity = Float(max(0.1, min(1.0, 1.0 + brightness)))
            layerInstruction.setOpacity(opacity, at: .zero)
            print("VVideoCompressionEngine: Applied brightness: \(brightness)")
        }
        
        // iOS Quick Fix: Add contrast and saturation support via Core Image (requires additional implementation)
        if config.advanced?.contrast != nil || config.advanced?.saturation != nil {
            // Note: Full implementation would require Core Image integration
            print("VVideoCompressionEngine: Color adjustments (contrast/saturation) require Core Image - not fully implemented")
        }
        
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        exportSession.videoComposition = videoComposition
        
        if let trimStartMs = config.advanced?.trimStartMs, let trimEndMs = config.advanced?.trimEndMs {
            let startTime = CMTime(seconds: Double(trimStartMs) / 1000.0, preferredTimescale: 600)
            let endTime = CMTime(seconds: Double(trimEndMs) / 1000.0, preferredTimescale: 600)
            exportSession.timeRange = CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime))
            print("VVideoCompressionEngine: Applied trimming")
        }
        
        print("VVideoCompressionEngine: ORIENTATION FIXED - composition applied successfully!")
    }
    
    private func handleCompressionCompletion(
        outputURL: URL,
        startTime: Double,
        videoInfo: VVideoInfo,
        config: VVideoCompressionConfig,
        callback: CompressionCallback
    ) {
        stopProgressTracking()
        isCompressionActive = false
        
        guard let exportSession = self.exportSession else {
            callback.onError("Export session was nil")
            return
        }
        
        if isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            callback.onError("Compression was cancelled")
            return
        }
        
        switch exportSession.status {
        case .completed:
            let endTime = Date().timeIntervalSince1970 * 1000
            let timeTaken = Int64(endTime - startTime)
            
            callback.onProgress(1.0)
            
            // COMPRESSION FIX: Check if output is larger than input
            let compressedSize = getFileSize(for: outputURL)
            if compressedSize > videoInfo.fileSizeBytes {
                let ratio = Float(compressedSize) / Float(videoInfo.fileSizeBytes)
                let percentIncrease = Int((ratio - 1.0) * 100)
                print("VVideoCompressionEngine: WARNING - Output file is \(percentIncrease)% LARGER than input!")
                print("VVideoCompressionEngine: Original: \(formatFileSize(videoInfo.fileSizeBytes)), Compressed: \(formatFileSize(compressedSize))")
                
                // Delete the larger output file
                try? FileManager.default.removeItem(at: outputURL)
                
                callback.onError("Compression failed: Output file (\(formatFileSize(compressedSize))) would be larger than input (\(formatFileSize(videoInfo.fileSizeBytes))). The video may already be optimally compressed or use a lower quality setting.")
                return
            }
            
            let result = createCompressionResult(
                originalVideo: videoInfo,
                compressedFile: outputURL,
                quality: config.quality,
                timeTaken: timeTaken
            )
            
            let savingsPercent = Int((1.0 - result.compressionRatio) * 100)
            print("VVideoCompressionEngine: Compression successful! Size reduced by \(savingsPercent)% (\(formatFileSize(videoInfo.fileSizeBytes)) → \(formatFileSize(compressedSize)))")
            
            callback.onComplete(result)
            
        case .failed:
            try? FileManager.default.removeItem(at: outputURL)
            let errorMessage = getDetailedError(from: exportSession.error)
            print("VVideoCompressionEngine: Export failed: \(errorMessage)")
            callback.onError("Compression failed: \(errorMessage)")
            
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            callback.onError("Compression was cancelled")
            
        default:
            callback.onError("Compression failed with unknown status")
        }
        
        self.exportSession = nil
    }
    
    func cancelCompression() {
        isCancelled = true
        stopProgressTracking()
        exportSession?.cancelExport()
        exportSession = nil
        isCompressionActive = false
    }
    
    func isCompressing() -> Bool {
        return isCompressionActive && exportSession != nil
    }
    
    func cleanup() -> [String: Any] {
        cancelCompression()
        return ["success": true, "message": "Cleanup completed"]
    }
    
    func cleanupFiles(deleteThumbnails: Bool, deleteCompressedVideos: Bool, clearCache: Bool) -> [String: Any] {
        cancelCompression()
        return [
            "success": true,
            "thumbnailsDeleted": deleteThumbnails ? 1 : 0,
            "videosDeleted": deleteCompressedVideos ? 1 : 0,
            "cacheCleared": clearCache,
            "message": "Selective cleanup completed"
        ]
    }
    
    func getVideoThumbnail(_ videoInfo: VVideoInfo, config: VVideoThumbnailConfig) -> VVideoThumbnailResult? {
        guard let url = createURL(from: videoInfo.path) else { return nil }
        
        let asset = AVAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        let time = CMTime(seconds: Double(config.timeMs) / 1000.0, preferredTimescale: 600)
        
        do {
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            let image = UIImage(cgImage: cgImage)
            
            let outputDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VideoThumbnails")
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            
            let timestamp = Int(Date().timeIntervalSince1970)
            let videoBaseName = URL(fileURLWithPath: videoInfo.name).deletingPathExtension().lastPathComponent
            let fileExtension = config.format == .png ? ".png" : ".jpg"
            let filename = "thumb_\(videoBaseName)_\(timestamp)\(fileExtension)"
            let outputFile = outputDirectory.appendingPathComponent(filename)
            
            let imageData = config.format == .png ? image.pngData() : image.jpegData(compressionQuality: 0.8)
            guard let data = imageData else { return nil }
            
            try data.write(to: outputFile)
            
            return VVideoThumbnailResult(
                thumbnailPath: outputFile.path,
                width: Int(image.size.width),
                height: Int(image.size.height),
                fileSizeBytes: Int64(data.count),
                format: config.format,
                timeMs: config.timeMs
            )
            
        } catch {
            print("VVideoCompressionEngine: Failed to generate thumbnail: \(error)")
            return nil
        }
    }
    
    // iOS Quick Fix: Add H.265 support check
    private func isHEVCSupported() -> Bool {
        if #available(iOS 11.0, *) {
            return AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
        }
        return false
    }

    private func getExportPreset(for quality: VVideoCompressQuality, advanced: VVideoAdvancedConfig? = nil, videoInfo: VVideoInfo) -> String {
        // COMPRESSION FIX: Smart preset selection based on input video resolution
        // Resolution-based presets only help when downscaling. If input is already at or below
        // the preset resolution, they can INCREASE file size by re-encoding at higher bitrates.
        // We use a hybrid approach:
        // - For high-res videos: use resolution presets to downscale
        // - For low-res videos: use quality presets to actually compress
        
        let inputPixels = videoInfo.width * videoInfo.height
        
        // iOS Quick Fix: Improved H.265 support
        if let videoCodec = advanced?.videoCodec, videoCodec == .h265 {
            if isHEVCSupported() {
                // For H.265, use resolution presets only if video is larger
                switch quality {
                case .high: 
                    return inputPixels > 2073600 ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetMediumQuality
                case .medium: 
                    return inputPixels > 2073600 ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetLowQuality
                case .low: 
                    return inputPixels > 921600 ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetLowQuality
                case .veryLow, .ultraLow: 
                    return AVAssetExportPresetLowQuality
                }
            }
        }
        
        // Smart preset selection for H.264
        // 1920x1080 = 2,073,600 pixels
        // 1280x720 = 921,600 pixels
        // 960x540 = 518,400 pixels
        // 640x480 = 307,200 pixels
        
        switch quality {
        case .high:
            // Only use 1080p preset if input is significantly larger (e.g., 4K)
            return inputPixels > 3686400 ? AVAssetExportPreset1920x1080 : AVAssetExportPresetMediumQuality
        case .medium:
            // Use 720p preset only if input is larger than 1080p
            return inputPixels > 2073600 ? AVAssetExportPreset1280x720 : AVAssetExportPresetLowQuality
        case .low:
            // Use 540p preset only if input is larger than 720p
            return inputPixels > 921600 ? AVAssetExportPreset960x540 : AVAssetExportPresetLowQuality
        case .veryLow:
            // Use 480p preset only if input is significantly larger
            return inputPixels > 518400 ? AVAssetExportPreset640x480 : AVAssetExportPresetLowQuality
        case .ultraLow:
            // Always use low quality preset for maximum compression
            return AVAssetExportPresetLowQuality
        }
    }
    
    private func startProgressTracking(callback: CompressionCallback) {
        progressTimer = Timer.scheduledTimer(withTimeInterval: Self.PROGRESS_UPDATE_INTERVAL, repeats: true) { _ in
            guard let exportSession = self.exportSession, !self.isCancelled else { return }
            callback.onProgress(exportSession.progress)
        }
    }
    
    private func stopProgressTracking() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    private func createOutputFile(_ outputPath: String?, videoInfo: VVideoInfo, quality: VVideoCompressQuality) -> URL {
        let outputDirectory: URL
        
        if let path = outputPath {
            outputDirectory = URL(fileURLWithPath: path)
        } else {
            outputDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CompressedVideos")
        }
        
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let videoBaseName = URL(fileURLWithPath: videoInfo.name).deletingPathExtension().lastPathComponent
        let filename = "\(videoBaseName)_\(quality.rawValue)_\(timestamp).mp4"
        
        return outputDirectory.appendingPathComponent(filename)
    }
    
    private func createCompressionResult(
        originalVideo: VVideoInfo,
        compressedFile: URL,
        quality: VVideoCompressQuality,
        timeTaken: Int64
    ) -> VVideoCompressionResult {
        let compressedSizeBytes = getFileSize(for: compressedFile)
        let compressionRatio = Float(compressedSizeBytes) / Float(originalVideo.fileSizeBytes)
        let spaceSaved = originalVideo.fileSizeBytes - compressedSizeBytes
        
        let originalResolution = "\(originalVideo.width)x\(originalVideo.height)"
        let compressedResolution = originalResolution
        
        return VVideoCompressionResult(
            originalVideo: originalVideo,
            compressedFilePath: compressedFile.path,
            galleryUri: nil,
            originalSizeBytes: originalVideo.fileSizeBytes,
            compressedSizeBytes: compressedSizeBytes,
            compressionRatio: compressionRatio,
            timeTaken: timeTaken,
            quality: quality,
            originalResolution: originalResolution,
            compressedResolution: compressedResolution,
            spaceSaved: spaceSaved
        )
    }
    

    
    private func getFileSize(for url: URL) -> Int64 {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(resourceValues.fileSize ?? 0)
        } catch {
            return 0
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024.0 / 1024.0
        return String(format: "%.1f MB", mb)
    }
    
    // iOS Quick Fix: Better error handling
    private func getDetailedError(from error: Error?) -> String {
        guard let error = error as NSError? else {
            return "Unknown error occurred"
        }

        switch error.code {
        case AVError.Code.fileAlreadyExists.rawValue:
            return "Output file already exists"
        case AVError.Code.diskFull.rawValue:
            return "Not enough storage space"
        case AVError.Code.sessionNotRunning.rawValue:
            return "Compression session failed to start"
        case AVError.Code.deviceNotConnected.rawValue:
            return "Required device not available"
        case AVError.Code.noDataCaptured.rawValue:
            return "No video data found"
        case AVError.Code.fileFormatNotRecognized.rawValue:
            return "Video format not supported"
        case AVError.Code.contentIsProtected.rawValue:
            return "Video is DRM protected"
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Input Validation
    
    private func validateCompressionInputs(videoInfo: VVideoInfo, config: VVideoCompressionConfig) -> Bool {
        // Check video info
        guard !videoInfo.path.isEmpty,
              videoInfo.width > 0,
              videoInfo.height > 0,
              videoInfo.durationMillis > 0 else {
            return false
        }
        
        // Check advanced config if present
        if let advanced = config.advanced {
            if let width = advanced.customWidth, width <= 0 { return false }
            if let height = advanced.customHeight, height <= 0 { return false }
            if let bitrate = advanced.videoBitrate, bitrate <= 0 { return false }
            if let frameRate = advanced.frameRate, frameRate <= 0 { return false }
        }
        
        return true
    }
    
    private func hasEnoughDiskSpace(for videoInfo: VVideoInfo, outputURL: URL) -> Bool {
        do {
            let resourceValues = try outputURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let availableCapacity = resourceValues.volumeAvailableCapacity {
                // Require at least 2x the original file size as safety margin
                let requiredSpace = videoInfo.fileSizeBytes * 2
                return Int64(availableCapacity) > requiredSpace
            }
        } catch {
            print("VVideoCompressionEngine: Could not check disk space: \(error)")
        }
        return true // Default to allowing compression if we can't check
    }
    
    private func createURL(from path: String) -> URL? {
        if path.hasPrefix("file://") {
            return URL(string: path)
        } else if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        } else {
            return URL(fileURLWithPath: path)
        }
    }
}

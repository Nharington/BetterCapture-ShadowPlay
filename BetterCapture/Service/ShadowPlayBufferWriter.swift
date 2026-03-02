//
//  ShadowPlayBufferWriter.swift
//  BetterCapture
//
//  Created by NHarington / GPT 5.2 on 02.03.26.
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import OSLog
import os

/// Continuously records short segments into a rolling on-disk buffer.
///
/// Designed to be used as `CaptureEngine.sampleBufferDelegate` and invoked synchronously
/// on ScreenCaptureKit's sample handler queues. Public methods are thread-safe.
final class ShadowPlayBufferWriter: CaptureEngineSampleBufferDelegate, @unchecked Sendable {

    struct Configuration: Sendable, Hashable {
        let containerFormat: ContainerFormat
        let videoCodec: VideoCodec
        let audioCodec: AudioCodec
        let captureSystemAudio: Bool
        let captureMicrophone: Bool
        let captureAlphaChannel: Bool
        let captureHDR: Bool
        let bufferDuration: Duration
        let segmentDuration: Duration
    }

    // MARK: - State / locking

    private struct ActiveWriter {
        var writer: AVAssetWriter
        var url: URL
        var videoInput: AVAssetWriterInput
        var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
        var audioInput: AVAssetWriterInput?
        var microphoneInput: AVAssetWriterInput?

        var hasStartedSession: Bool
        var segmentStartPresentationTime: CMTime?
        var lastVideoPresentationTime: CMTime
    }

    private let lock = OSAllocatedUnfairLock()

    private var configuration: Configuration?
    private var videoSize: CGSize = .zero

    private var activeWriter: ActiveWriter?
    private var finalizedSegments: [ShadowPlaySegment] = []

    private var pinnedByToken: [UUID: Set<URL>] = [:]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "ShadowPlayBufferWriter")

    // MARK: - Public API

    func configure(_ configuration: Configuration, videoSize: CGSize) throws {
        try lock.withLockUnchecked {
            self.configuration = configuration
            self.videoSize = videoSize
        }
    }

    /// Clears all on-disk segments and resets internal state.
    func reset() {
        let urlsToDelete: [URL] = lock.withLockUnchecked {
            let urls = finalizedSegments.map(\.url) + (activeWriter.map { [$0.url] } ?? [])
            finalizedSegments.removeAll()
            activeWriter = nil
            pinnedByToken.removeAll()
            return urls
        }

        for url in urlsToDelete {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Returns the finalized segments currently available (oldest → newest).
    func snapshotSegments() -> [ShadowPlaySegment] {
        lock.withLockUnchecked { finalizedSegments }
    }

    /// Pins the given URLs so cleanup won’t delete them until the token is released.
    func pin(urls: [URL]) -> UUID {
        lock.withLockUnchecked {
            let token = UUID()
            pinnedByToken[token] = Set(urls)
            return token
        }
    }

    func unpin(token: UUID) {
        let urlsToMaybeDelete: [URL] = lock.withLockUnchecked {
            pinnedByToken.removeValue(forKey: token)
            return cleanupUnlocked()
        }
        for url in urlsToMaybeDelete {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Rotates the current segment (if any) and awaits finalization.
    /// Capture continues into a fresh segment immediately.
    func flushCurrentSegment() async {
        let finalize: (() async -> Void)? = rotateSegmentIfNeeded(force: true)
        guard let finalize else { return }
        await finalize()
    }

    // MARK: - CaptureEngineSampleBufferDelegate

    func captureEngine(_ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        appendVideoSample(sampleBuffer)
    }

    func captureEngine(_ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        appendAudioSample(sampleBuffer)
    }

    func captureEngine(_ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer) {
        appendMicrophoneSample(sampleBuffer)
    }

    // MARK: - Appending

    private func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let finalize: (() async -> Void)?
        do {
            finalize = try lock.withLockUnchecked {
                try ensureActiveWriterIfNeededUnlocked()

                guard var active = activeWriter,
                      active.writer.status == .writing,
                      active.videoInput.isReadyForMoreMediaData else {
                    return nil
                }

                if !active.hasStartedSession {
                    active.writer.startSession(atSourceTime: presentationTime)
                    active.hasStartedSession = true
                    active.segmentStartPresentationTime = presentationTime
                    active.lastVideoPresentationTime = .invalid
                } else if active.lastVideoPresentationTime.isValid && presentationTime <= active.lastVideoPresentationTime {
                    activeWriter = active
                    return nil
                }

                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    activeWriter = active
                    return nil
                }

                if active.pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                    active.lastVideoPresentationTime = presentationTime
                }

                activeWriter = active

                return rotateSegmentIfNeededUnlocked(nowPresentationTime: presentationTime)
            }
        } catch {
            logger.error("ShadowPlay writer failed to append video: \(error.localizedDescription)")
            return
        }

        if let finalize {
            Task.detached(priority: .utility) {
                await finalize()
            }
        }
    }

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }

        do {
            _ = try lock.withLockUnchecked {
                try ensureActiveWriterIfNeededUnlocked()

                guard var active = activeWriter,
                      active.writer.status == .writing,
                      let audioInput = active.audioInput,
                      audioInput.isReadyForMoreMediaData else {
                    return
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if !active.hasStartedSession {
                    active.writer.startSession(atSourceTime: presentationTime)
                    active.hasStartedSession = true
                    active.segmentStartPresentationTime = presentationTime
                    active.lastVideoPresentationTime = .invalid
                }

                _ = audioInput.append(sampleBuffer)
                active.audioInput = audioInput
                activeWriter = active
            }
        } catch {
            logger.error("ShadowPlay writer failed to append audio: \(error.localizedDescription)")
        }
    }

    private func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }

        do {
            _ = try lock.withLockUnchecked {
                try ensureActiveWriterIfNeededUnlocked()

                guard var active = activeWriter,
                      active.writer.status == .writing,
                      let micInput = active.microphoneInput,
                      micInput.isReadyForMoreMediaData else {
                    return
                }

                _ = micInput.append(sampleBuffer)
                active.microphoneInput = micInput
                activeWriter = active
            }
        } catch {
            logger.error("ShadowPlay writer failed to append microphone: \(error.localizedDescription)")
        }
    }

    // MARK: - Rotation / cleanup

    private func rotateSegmentIfNeeded(force: Bool) -> (() async -> Void)? {
        lock.withLockUnchecked {
            rotateSegmentIfNeededUnlocked(force: force)
        }
    }

    private func rotateSegmentIfNeededUnlocked(nowPresentationTime: CMTime) -> (() async -> Void)? {
        guard let configuration, let active = activeWriter else { return nil }
        guard let start = active.segmentStartPresentationTime else { return nil }

        let elapsedSeconds = max(0, nowPresentationTime.seconds - start.seconds)
        let elapsed = Duration.fromTimeInterval(elapsedSeconds)

        if elapsed >= configuration.segmentDuration {
            return rotateSegmentIfNeededUnlocked(force: true)
        }
        return nil
    }

    private func rotateSegmentIfNeededUnlocked(force: Bool) -> (() async -> Void)? {
        guard force else { return nil }

        guard let active = activeWriter else { return nil }
        activeWriter = nil

        do {
            try ensureActiveWriterIfNeededUnlocked()
        } catch {
            logger.error("Failed to start next segment writer: \(error.localizedDescription)")
        }

        return finalize(activeWriter: active)
    }

    private func finalize(activeWriter toFinalize: ActiveWriter) -> () async -> Void {
        let config = lock.withLockUnchecked { configuration }

        return { [weak self] in
            guard let self else { return }

            if !toFinalize.hasStartedSession {
                try? FileManager.default.removeItem(at: toFinalize.url)
                return
            }

            toFinalize.videoInput.markAsFinished()
            toFinalize.audioInput?.markAsFinished()
            toFinalize.microphoneInput?.markAsFinished()

            let url = toFinalize.url
            let writer = toFinalize.writer

            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }

            guard writer.status != .failed else {
                if let error = writer.error {
                    self.logger.error("Segment writer failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: url)
                return
            }

            let duration = await self.segmentDuration(url: url) ?? config?.segmentDuration ?? .zero
            let segment = ShadowPlaySegment(url: url, duration: duration, createdAt: Date())

            let urlsToDelete: [URL] = self.lock.withLockUnchecked {
                self.finalizedSegments.append(segment)
                return self.cleanupUnlocked()
            }

            for url in urlsToDelete {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func cleanupUnlocked() -> [URL] {
        guard let configuration else { return [] }
        let pinned = Set(pinnedByToken.values.flatMap { $0 })

        var urlsToDelete: [URL] = []
        var total = finalizedSegments.reduce(Duration.zero) { $0 + $1.duration }

        while total > configuration.bufferDuration, let first = finalizedSegments.first {
            if pinned.contains(first.url) {
                // Skip pinned segments; if we can’t delete any more, stop.
                break
            }
            finalizedSegments.removeFirst()
            total -= first.duration
            urlsToDelete.append(first.url)
        }

        return urlsToDelete
    }

    // MARK: - Writer creation

    private func ensureActiveWriterIfNeededUnlocked() throws {
        guard activeWriter == nil else { return }
        guard let configuration else { throw ShadowPlayWriterError.notConfigured }

        let segmentURL = try createNewSegmentURL(containerFormat: configuration.containerFormat)
        let fileType: AVFileType = configuration.containerFormat == .mov ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: segmentURL, fileType: fileType)

        let videoSettings = createVideoSettings(configuration: configuration, size: videoSize)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ShadowPlayWriterError.cannotAddVideoInput }
        writer.add(videoInput)

        let pixelFormat: OSType = (configuration.captureHDR && configuration.videoCodec.supportsHDR)
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height)
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        var audioInput: AVAssetWriterInput?
        if configuration.captureSystemAudio {
            let audioSettings = createAudioSettings(configuration: configuration)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        var micInput: AVAssetWriterInput?
        if configuration.captureMicrophone {
            let audioSettings = createAudioSettings(configuration: configuration)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                micInput = input
            }
        }

        guard writer.startWriting() else {
            throw ShadowPlayWriterError.failedToStartWriting(writer.error)
        }

        activeWriter = ActiveWriter(
            writer: writer,
            url: segmentURL,
            videoInput: videoInput,
            pixelBufferAdaptor: adaptor,
            audioInput: audioInput,
            microphoneInput: micInput,
            hasStartedSession: false,
            segmentStartPresentationTime: nil,
            lastVideoPresentationTime: .invalid
        )
    }

    private func createNewSegmentURL(containerFormat: ContainerFormat) throws -> URL {
        let directory = try shadowPlayCacheDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss.SSS"
        let name = "ShadowPlay_\(formatter.string(from: Date()))_\(UUID().uuidString).\(containerFormat.fileExtension)"
        return directory.appending(path: name)
    }

    private func shadowPlayCacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else { throw ShadowPlayWriterError.failedToResolveCacheDirectory }

        let directory = base
            .appending(path: "BetterCapture")
            .appending(path: "ShadowPlay")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Settings helpers

    private func createVideoSettings(configuration: Configuration, size: CGSize) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]

        switch configuration.videoCodec {
        case .h264:
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
        case .hevc:
            if configuration.captureAlphaChannel {
                settings[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
            } else {
                settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            }
        case .proRes422:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .proRes4444:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }

        if configuration.captureHDR && configuration.videoCodec.supportsHDR {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }

        return settings
    }

    private func createAudioSettings(configuration: Configuration) -> [String: Any] {
        switch configuration.audioCodec {
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000
            ]
        case .pcm:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    // MARK: - Duration probing

    private func segmentDuration(url: URL) async -> Duration? {
        let asset = AVURLAsset(url: url)
        do {
            let cmDuration = try await asset.load(.duration)
            return .fromTimeInterval(cmDuration.seconds)
        } catch {
            return nil
        }
    }
}

enum ShadowPlayWriterError: LocalizedError {
    case notConfigured
    case failedToResolveCacheDirectory
    case cannotAddVideoInput
    case failedToStartWriting(Error?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ShadowPlay is not configured."
        case .failedToResolveCacheDirectory:
            return "Failed to resolve cache directory for ShadowPlay segments."
        case .cannotAddVideoInput:
            return "Failed to configure ShadowPlay video input."
        case .failedToStartWriting(let error):
            return "Failed to start ShadowPlay writer: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}


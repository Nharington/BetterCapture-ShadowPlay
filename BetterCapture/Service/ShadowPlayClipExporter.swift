//
//  ShadowPlayClipExporter.swift
//  BetterCapture
//
//  Created by NHarington / GPT 5.2 on 02.03.26.
//

import Foundation
import AVFoundation

final class ShadowPlayClipExporter {

    func export(
        slices: [ShadowPlaySegmentSlice],
        to outputURL: URL,
        containerFormat: ContainerFormat
    ) async throws -> URL {
        guard !slices.isEmpty else { throw ShadowPlayClipExportError.noSegments }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ShadowPlayClipExportError.failedToCreateComposition
        }

        var compositionAudioTracks: [AVMutableCompositionTrack] = []

        var cursorTime: CMTime = .zero
        for slice in slices {
            let asset = AVURLAsset(url: slice.segment.url)

            let assetDuration = try await asset.load(.duration)
            let trimStart = CMTime(seconds: max(0, slice.trimFromStart.timeInterval), preferredTimescale: 600)
            let timeRange: CMTimeRange
            if trimStart > .zero {
                timeRange = CMTimeRange(
                    start: trimStart,
                    duration: CMTimeSubtract(assetDuration, trimStart)
                )
            } else {
                timeRange = CMTimeRange(start: .zero, duration: assetDuration)
            }

            guard timeRange.duration > .zero else { continue }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideoTrack = videoTracks.first else {
                throw ShadowPlayClipExportError.missingVideoTrack(slice.segment.url)
            }

            try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: cursorTime)

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if !audioTracks.isEmpty {
                while compositionAudioTracks.count < audioTracks.count {
                    guard let newTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        throw ShadowPlayClipExportError.failedToCreateComposition
                    }
                    compositionAudioTracks.append(newTrack)
                }

                for (index, sourceAudioTrack) in audioTracks.enumerated() {
                    try compositionAudioTracks[index].insertTimeRange(timeRange, of: sourceAudioTrack, at: cursorTime)
                }
            }

            cursorTime = CMTimeAdd(cursorTime, timeRange.duration)
        }

        guard cursorTime > .zero else { throw ShadowPlayClipExportError.noMedia }

        let fileType: AVFileType = containerFormat == .mov ? .mov : .mp4

        let presetNames = AVAssetExportSession.exportPresets(compatibleWith: composition)
        let preset: String = presetNames.contains(AVAssetExportPresetPassthrough)
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality

        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ShadowPlayClipExportError.failedToCreateExporter
        }

        // Ensure output directory exists and no conflicting file is present.
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path()) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = fileType
        exporter.shouldOptimizeForNetworkUse = false

        try await export(exporter)

        return outputURL
    }

    private func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: ShadowPlayClipExportError.exportFailed(exporter.error))
                case .cancelled:
                    continuation.resume(throwing: ShadowPlayClipExportError.exportCancelled)
                default:
                    continuation.resume(throwing: ShadowPlayClipExportError.exportFailed(exporter.error))
                }
            }
        }
    }
}

enum ShadowPlayClipExportError: LocalizedError {
    case noSegments
    case noMedia
    case failedToCreateComposition
    case failedToCreateExporter
    case missingVideoTrack(URL)
    case exportFailed(Error?)
    case exportCancelled

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "No ShadowPlay segments are available to export."
        case .noMedia:
            return "No media was available to export."
        case .failedToCreateComposition:
            return "Failed to create the export composition."
        case .failedToCreateExporter:
            return "Failed to create the export session."
        case .missingVideoTrack(let url):
            return "Missing video track in segment: \(url.lastPathComponent)"
        case .exportFailed(let error):
            return "Failed to export clip: \(error?.localizedDescription ?? "unknown error")"
        case .exportCancelled:
            return "Export was cancelled."
        }
    }
}


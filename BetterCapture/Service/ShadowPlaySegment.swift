//
//  ShadowPlaySegment.swift
//  BetterCapture
//
//  Created by NHarington / GPT 5.2 on 02.03.26.
//

import Foundation

struct ShadowPlaySegment: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let duration: Duration
    let createdAt: Date

    init(id: UUID = UUID(), url: URL, duration: Duration, createdAt: Date) {
        self.id = id
        self.url = url
        self.duration = duration
        self.createdAt = createdAt
    }
}

struct ShadowPlaySegmentSlice: Hashable, Sendable {
    let segment: ShadowPlaySegment
    /// Portion to skip from the start of the segment (tail-trim support).
    let trimFromStart: Duration

    init(segment: ShadowPlaySegment, trimFromStart: Duration = .zero) {
        self.segment = segment
        self.trimFromStart = trimFromStart
    }
}

enum ShadowPlaySegmentSelection {
    static func slicesForLast(duration: Duration, from segments: [ShadowPlaySegment]) -> [ShadowPlaySegmentSlice] {
        guard duration > .zero, !segments.isEmpty else { return [] }

        var remaining = duration
        var reversedSlices: [ShadowPlaySegmentSlice] = []

        for segment in segments.reversed() {
            guard remaining > .zero else { break }

            if segment.duration <= remaining {
                reversedSlices.append(.init(segment: segment, trimFromStart: .zero))
                remaining -= segment.duration
            } else {
                reversedSlices.append(.init(segment: segment, trimFromStart: segment.duration - remaining))
                remaining = .zero
            }
        }

        return reversedSlices.reversed()
    }
}

enum ShadowPlayClipDuration {
    static func clamped(requested: Duration, buffer: Duration) -> Duration {
        guard requested > .zero else { return .zero }
        guard buffer > .zero else { return .zero }
        return min(requested, buffer)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    static func fromTimeInterval(_ interval: TimeInterval) -> Duration {
        guard interval > 0 else { return .zero }
        let ms = (interval * 1000).rounded()
        return .milliseconds(Int64(ms))
    }
}

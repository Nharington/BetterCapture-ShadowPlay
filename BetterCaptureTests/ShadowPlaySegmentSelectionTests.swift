//
//  ShadowPlaySegmentSelectionTests.swift
//  BetterCaptureTests
//
//  Created by NHarington / GPT 5.2 on 02.03.26.
//

import Foundation
import Testing
@testable import BetterCapture

struct ShadowPlaySegmentSelectionTests {

    @Test func slicesForLastReturnsTailAndTrim() {
        let baseURL = URL(fileURLWithPath: "/tmp")
        let segments: [ShadowPlaySegment] = [
            ShadowPlaySegment(url: baseURL.appending(path: "a.mov"), duration: .seconds(10), createdAt: .distantPast),
            ShadowPlaySegment(url: baseURL.appending(path: "b.mov"), duration: .seconds(10), createdAt: .distantPast),
            ShadowPlaySegment(url: baseURL.appending(path: "c.mov"), duration: .seconds(10), createdAt: .distantPast),
        ]

        let slices = ShadowPlaySegmentSelection.slicesForLast(duration: .seconds(15), from: segments)

        #expect(slices.count == 2)
        #expect(slices[0].segment.url.lastPathComponent == "b.mov")
        #expect(slices[0].trimFromStart == .seconds(5))
        #expect(slices[1].segment.url.lastPathComponent == "c.mov")
        #expect(slices[1].trimFromStart == .zero)
    }

    @Test func slicesForLastReturnsAllWhenDurationExceedsTotal() {
        let baseURL = URL(fileURLWithPath: "/tmp")
        let segments: [ShadowPlaySegment] = [
            ShadowPlaySegment(url: baseURL.appending(path: "a.mov"), duration: .seconds(4), createdAt: .distantPast),
            ShadowPlaySegment(url: baseURL.appending(path: "b.mov"), duration: .seconds(6), createdAt: .distantPast),
        ]

        let slices = ShadowPlaySegmentSelection.slicesForLast(duration: .seconds(30), from: segments)

        #expect(slices.count == 2)
        #expect(slices.allSatisfy { $0.trimFromStart == .zero })
    }

    @Test func clipDurationClamp() {
        #expect(ShadowPlayClipDuration.clamped(requested: .seconds(0), buffer: .seconds(60)) == .zero)
        #expect(ShadowPlayClipDuration.clamped(requested: .seconds(10), buffer: .seconds(0)) == .zero)
        #expect(ShadowPlayClipDuration.clamped(requested: .seconds(10), buffer: .seconds(60)) == .seconds(10))
        #expect(ShadowPlayClipDuration.clamped(requested: .seconds(120), buffer: .seconds(60)) == .seconds(60))
    }
}


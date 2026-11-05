//
// LuxFFmpegProbeKitTests — 在 macOS 上真的跑一遍动态 framework。
//
// 夹具沿用 F0 的 lux/.build/fixtures/lux-f0-fixture.mkv(12s,H.264 + AAC,
// matroska 带 Cues);`lux/test/run.sh` 已经会生成它。
//
import Foundation
import XCTest

@testable import LuxFFmpegProbeKit

final class ProbeTests: XCTestCase {
    /// 从 #filePath 推导仓库根,避免硬编码路径,也避免依赖测试的 cwd。
    private func fixtureURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["LUX_FFMPEG_FIXTURE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // .../lux/test/swift-import/Tests/LuxFFmpegProbeKitTests/ProbeTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let luxRoot = thisFile
            .deletingLastPathComponent()   // LuxFFmpegProbeKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift-import
            .deletingLastPathComponent()   // test
            .deletingLastPathComponent()   // lux
        let candidate = luxRoot
            .appendingPathComponent(".build/fixtures/lux-f0-fixture.mkv")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw XCTSkip("fixture missing: \(candidate.path) — run lux/test/run.sh first")
        }
        return candidate
    }

    func testImportsFourModules() {
        // 只要这个测试能编译/运行,就说明四个 module 都能被 Swift import,
        // 并且 binaryTarget 的 xcframework 被正确链接。
        let version = versions()
        XCTAssertTrue(version.contains("libavformat 62."), version)
        XCTAssertTrue(version.contains("libavcodec 62."), version)
        XCTAssertTrue(version.contains("libavutil 60."), version)
        XCTAssertTrue(version.contains("libswresample 6."), version)
    }

    func testProbeReadsFixture() throws {
        let result = try runProbe(path: try fixtureURL().path)
        XCTAssertTrue(result.license.hasPrefix("LGPL"), "license = \(result.license)")
        XCTAssertEqual(result.formatName, "matroska,webm")
        XCTAssertEqual(result.streams.count, 2)
        XCTAssertEqual(result.streams.first?.mediaType, "video")
        XCTAssertEqual(result.streams.first?.codec, "h264")
        XCTAssertEqual(result.streams.first?.width, 320)
        XCTAssertEqual(result.streams.first?.height, 240)
        XCTAssertEqual(result.streams.last?.mediaType, "audio")
        XCTAssertEqual(result.streams.last?.codec, "aac")
        XCTAssertEqual(result.streams.last?.sampleRate, 48_000)
        XCTAssertEqual(result.streams.last?.channels, 2)
        XCTAssertEqual(result.firstFrame, "320x240 @yuv420p")
        XCTAssertGreaterThan(result.packetsRead, 0)
        XCTAssertEqual(result.durationSeconds, 12.0, accuracy: 0.2)
    }
}

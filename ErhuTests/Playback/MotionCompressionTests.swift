import AVFoundation
import XCTest
@testable import Erhu

final class MotionCompressionTests: XCTestCase {
    func testRealH264AndHEVCFramesAreDecodedAndValidatedWithoutTouchingOriginal() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "motion-source", withExtension: "mp4"))
        let candidate = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "motion-candidate", withExtension: "mp4"))
        let original = try Data(contentsOf: source)
        let before = try await MotionCoverCompressor.inspect(source)
        let after = try await MotionCoverCompressor.inspect(candidate)
        XCTAssertEqual(before.frameTimes.count, 30)
        XCTAssertEqual(after.frameTimes.count, 30)
        XCTAssertNoThrow(try MotionCoverCompressor.validate(before, after))
        XCTAssertEqual(try Data(contentsOf: source), original)
        let shortened = MotionVideoInfo(codec: after.codec, width: after.width, height: after.height,
                                        duration: after.duration, frameTimes: Array(after.frameTimes.dropLast()), colors: after.colors)
        XCTAssertThrowsError(try MotionCoverCompressor.validate(before, shortened))
        let recolored = MotionVideoInfo(codec: after.codec, width: after.width, height: after.height,
                                       duration: after.duration, frameTimes: after.frameTimes, colors: [:])
        XCTAssertThrowsError(try MotionCoverCompressor.validate(before, recolored))
    }
    func testNativeExportPreservesValidatedFramesAndOriginalWhenHEVCIsAvailable() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "motion-source", withExtension: "mp4"))
        let before = try await MotionCoverCompressor.inspect(source)
        let asset = AVURLAsset(url: source)
        guard AVAssetExportSession.exportPresets(compatibleWith: asset).contains(AVAssetExportPresetHEVCHighestQuality) else {
            throw XCTSkip("This simulator does not offer a compatible HEVC export preset")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("candidate.mp4")
        let original = try Data(contentsOf: source)
        do { try await MotionCoverCompressor.prepare(source, candidate: target) }
        catch MotionCompressionError.noSaving { /* A tiny fixture may encode larger; structural checks must still pass. */ }
        let after = try await MotionCoverCompressor.inspect(target)
        XCTAssertNoThrow(try MotionCoverCompressor.validate(before, after))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testOldSavedCoverDecodesWithoutCompressionFields() throws {
        let old = Data(#"{"albumId":1,"album":"Album","artist":"Artist","catalogId":2,"storefront":"us","fileName":"original.mp4"}"#.utf8)
        let cover = try JSONDecoder().decode(SavedMotionCover.self, from: old)
        XCTAssertEqual(cover.fileName, "original.mp4")
        XCTAssertNil(cover.compressedSquare)
        XCTAssertNil(cover.portraitFileName)
    }
}

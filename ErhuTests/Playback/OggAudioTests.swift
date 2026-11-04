import AVFoundation
import XCTest
@testable import Erhu

final class OggAudioTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    func testVorbisAndOpusDecodeFullyThroughTheExistingAudioReaderWithoutChangingOriginals() throws {
        for (name, ext, channels) in [("vorbis", "ogg", 2), ("opus", "opus", 1)] {
            let url = try fixture(name, ext)
            let original = try Data(contentsOf: url)
            let metadata = try DecodedAudioSource.inspect(url)
            let audio = try DecodedAudioSource.open(url)
            XCTAssertEqual(audio.length, 48000)
            XCTAssertEqual(audio.processingFormat.channelCount, AVAudioChannelCount(channels))
            let block = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096))
            try audio.read(into: block)
            XCTAssertEqual(block.frameLength, 4096)
            let samples = try XCTUnwrap(block.floatChannelData)
            XCTAssertTrue((0..<4096).allSatisfy { samples[0][$0].isFinite })
            XCTAssertGreaterThan((0..<4096).map { abs(samples[0][$0]) }.max() ?? 0, 0.01)
            audio.framePosition = 24000
            try audio.read(into: block)
            XCTAssertEqual(audio.framePosition, 28096, "The same reader supports accurate seeking")
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual((metadata["channels"] as? NSNumber)?.intValue, channels)
            XCTAssertEqual(TagReader.read(url).artist, "Erhu tests")
            XCTAssertEqual(AudioFormatInfo.read(url, fileSize: Int64(original.count)).durationMs, 1000)
        }
    }
    func testCorruptOggDoesNotPublishAPlayableCache() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("OggS not an audio stream".utf8).write(to: url)
        XCTAssertThrowsError(try DecodedAudioSource.prepare(url))
        XCTAssertFalse(DecodedAudioSource.isPrepared(url))
    }
    func testTransferAcceptsRealOggSignaturesAndRejectsRenamedText() {
        XCTAssertNotNil(TransferFiles.sanitize("track.opus"))
        XCTAssertNotNil(TransferFiles.sanitize("track.oga"))
        XCTAssertTrue(TransferFiles.looksLikeAudio("track.ogg", Array("OggS12345678".utf8)))
        XCTAssertFalse(TransferFiles.looksLikeAudio("track.opus", Array("plain text".utf8)))
    }
}

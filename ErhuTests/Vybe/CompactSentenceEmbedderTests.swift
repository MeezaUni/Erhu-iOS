import Foundation
import XCTest
@testable import Erhu

final class CompactSentenceEmbedderTests: XCTestCase {
    private struct Reference: Decodable {
        let text: String
        let ids: [Int32]
        let embedding: [Float]
    }

    func testBundledCompressedModelMatchesTheOriginalEncoderAndTokenizer() throws {
        let model = try CompactSentenceEmbedder()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vybe-reference-vectors", withExtension: "json"))
        let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: url))
        for reference in references {
            let tokens = model.tokenizer.encode(reference.text)
            XCTAssertEqual(tokens.ids, reference.ids, "Swift tokenization must match BERT WordPiece")
            XCTAssertEqual(tokens.mask, reference.ids.map { $0 == 0 ? 0 : 1 })
            let vector = try model.embed(reference.text, role: .query)
            XCTAssertEqual(vector.count, 384)
            XCTAssertGreaterThan(try XCTUnwrap(cosineSimilarity(vector, reference.embedding)), 0.985, reference.text)
            XCTAssertEqual(vector, try model.embed(reference.text, role: .query), "Repeated queries must stay stable")
        }
    }

    func testTokenizerBoundsLongInputsAndHandlesEmptyText() throws {
        let model = try CompactSentenceEmbedder()
        let empty = model.tokenizer.encode("")
        XCTAssertEqual(Array(empty.ids.prefix(3)), [101, 102, 0])
        XCTAssertEqual(empty.mask.reduce(0, +), 2)
        let long = model.tokenizer.encode(String(repeating: "music ", count: 2000))
        XCTAssertEqual(long.ids.count, 128)
        XCTAssertEqual(long.ids.last, 102)
        XCTAssertEqual(long.mask.reduce(0, +), 128)
        XCTAssertTrue(try model.embed("", role: .query).allSatisfy(\.isFinite))
    }

    func testCompiledModelStaysWithinItsStorageBudget() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "VybeSentence", withExtension: "mlmodelc"))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))
        var bytes = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
        }
        XCTAssertGreaterThan(bytes, 1_000_000, "The real model must ship in the app")
        XCTAssertLessThan(bytes, 25_000_000, "Keep the compiled model compact")
        print("VYBE compiled model storage: \(bytes) bytes")
    }

    func testMusicQueriesRankRelevantStylesWithTheRealCompressedModel() throws {
        let model = try CompactSentenceEmbedder()
        let descriptions = [
            "Artist: Quiet Hands. Genres: Ambient, Piano. Tempo: 70 BPM (slow tempo)",
            "Artist: Gym Crew. Genres: EDM, Hardstyle. Tempo: 150 BPM (fast tempo)",
            "Artist: MC Flow. Genres: Hip-Hop, Trap. Tempo: 140 BPM (fast tempo)",
            "Artist: Warm Voices. Genres: R&B, Soul. Tempo: 80 BPM (slow tempo)",
            "Artist: Iron Storm. Genres: Heavy Metal, Thrash Metal. Tempo: 160 BPM (fast tempo)",
            "Artist: Blue Quartet. Genres: Jazz, Bebop. Tempo: 110 BPM (moderate tempo)",
            "Artist: Wood And Strings. Genres: Acoustic Folk, Singer-Songwriter. Tempo: 90 BPM (slow tempo)",
            "Artist: Chamber Orchestra. Genres: Classical, Orchestral. Tempo: 85 BPM (slow tempo)",
            "Artist: Island Sound. Genres: Reggae, Dub. Tempo: 75 BPM (slow tempo)",
            "Artist: Open Roads. Genres: Country, Bluegrass. Tempo: 95 BPM (moderate tempo)",
        ]
        let vectors = try descriptions.enumerated().map { EmbeddedSong(songId: Int64($0.offset), vector: try model.embed($0.element, role: .document)) }
        let queries: [(String, Int64)] = [
            ("Gentle piano music to fall asleep to", 0),
            ("High energy electronic dance music for a workout", 1),
            ("Smooth soulful rhythm and blues", 3),
            ("Aggressive metal music with heavy guitars", 4),
            ("Jazz for a quiet evening", 5),
            ("Warm acoustic folk music", 6),
            ("Orchestral classical music", 7),
            ("Hip hop rap for running", 2),
        ]
        for (query, expected) in queries {
            let vector = try model.embed(query, role: .query)
            XCTAssertEqual(VybeRanker.rank(vector, songs: vectors, limit: 1).first?.songId, expected, query)
        }
        if let legacy = try? SentenceEmbedder() {
            let legacyVectors = try descriptions.enumerated().map { EmbeddedSong(songId: Int64($0.offset), vector: try legacy.embed($0.element, role: .document)) }
            var correct = 0
            for (query, expected) in queries {
                let vector = try legacy.embed(query, role: .query)
                if VybeRanker.rank(vector, songs: legacyVectors, limit: 1).first?.songId == expected { correct += 1 }
            }
            print("VYBE fixed style benchmark: previous Apple model \(correct)/\(queries.count); compact model checked above")
        }
    }
}

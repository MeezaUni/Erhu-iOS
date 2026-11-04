import CoreML
import XCTest
@testable import MiniLMProbe

final class ProbeTests: XCTestCase {
    struct Reference: Decodable { let text: String; let embedding: [Float] }
    func testCoreMLBackendNumerics() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "VybeSentence", withExtension: "mlmodelc"))
        let vocab = try XCTUnwrap(Bundle.main.url(forResource: "vybe-vocab", withExtension: "txt"))
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vybe-reference-vectors", withExtension: "json"))
        let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: fixture))
        let tokenizer = WordPieceTokenizer(vocabulary: try String(contentsOf: vocab, encoding: .utf8))
        var usable = 0
        let modes: [(String, MLComputeUnits)] = [("all", .all), ("cpuOnly", .cpuOnly)]
        for variant in ["MiniLM32"] {
            let source = try XCTUnwrap(Bundle.main.url(forResource: variant, withExtension: "mlmodelc"))
            for (name, units) in modes {
                do {
                    let config = MLModelConfiguration(); config.computeUnits = units
                    let model = try MLModel(contentsOf: source, configuration: config)
                    var worst = 1.0, finite = 0, count = 0, norm = 0.0
                    for reference in references {
                        let tokens = tokenizer.encode(reference.text)
                        let ids = try MLMultiArray(shape: [1, 128], dataType: .int32)
                        let mask = try MLMultiArray(shape: [1, 128], dataType: .int32)
                        for i in 0..<128 { ids[i] = NSNumber(value: tokens.ids[i]); mask[i] = NSNumber(value: tokens.mask[i]) }
                        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
                        let result = try model.prediction(from: input)
                        guard let array = result.featureValue(for: "embedding")?.multiArrayValue else { worst = -1; break }
                        let vector = (0..<array.count).map { array[$0].floatValue }
                        count = array.count; finite = vector.filter(\.isFinite).count
                        norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
                        guard count == reference.embedding.count, finite == count, norm > 0 else { worst = -1; break }
                        let other = sqrt(reference.embedding.reduce(0.0) { $0 + Double($1) * Double($1) })
                        let cosine = zip(vector, reference.embedding).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / (norm * other)
                        worst = min(worst, cosine)
                        if worst < 0.985 { break }
                    }
                    if worst > 0.985 { usable += 1 }
                    print("MINILM_PROBE variant=\(variant) mode=\(name) count=\(count) finite=\(finite) norm=\(norm) minReferenceCosine=\(worst)")
                } catch { print("MINILM_PROBE variant=\(variant) mode=\(name) error=\(error)") }
            }
        }
        do {
            let embedder = try CompactSentenceEmbedder()
            let vector = try embedder.embed(references[0].text, role: .query)
            print("MINILM_PROBE production count=\(vector.count) finite=\(vector.allSatisfy(\.isFinite))")
        } catch { print("MINILM_PROBE production error=\(error)") }
        XCTAssertGreaterThan(usable, 0, "At least one backend must reproduce a real reference vector")
    }
    func testProductionEmbedderReferencesEmptyInputStylesAndStorage() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vybe-reference-vectors", withExtension: "json"))
        let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: fixture))
        let model = try CompactSentenceEmbedder()
        func cosine(_ x: [Float], _ y: [Float]) -> Double {
            let dot = zip(x,y).reduce(0.0) { $0 + Double($1.0)*Double($1.1) }
            return dot / sqrt(x.reduce(0.0) { $0 + Double($1)*Double($1) } * y.reduce(0.0) { $0 + Double($1)*Double($1) })
        }
        for reference in references {
            let vector = try model.embed(reference.text, role: .query)
            XCTAssertEqual(vector.count, 384)
            XCTAssertGreaterThan(cosine(vector, reference.embedding), 0.985)
        }
        XCTAssertTrue(try model.embed("", role: .query).allSatisfy(\.isFinite))
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
            "Artist: Open Roads. Genres: Country, Bluegrass. Tempo: 95 BPM (moderate tempo)"
        ]
        let vectors = try descriptions.map { try model.embed($0, role: .document) }
        let queries: [(String, Int)] = [
            ("Gentle piano music to fall asleep to",0), ("High energy electronic dance music for a workout",1),
            ("Smooth soulful rhythm and blues",3), ("Aggressive metal music with heavy guitars",4),
            ("Jazz for a quiet evening",5), ("Warm acoustic folk music",6), ("Orchestral classical music",7), ("Hip hop rap for running",2)
        ]
        for (text, expected) in queries {
            let query = try model.embed(text, role: .query)
            let winner = vectors.indices.max { cosine(query,vectors[$0]) < cosine(query,vectors[$1]) }
            XCTAssertEqual(winner, expected, text)
        }
        let root = try XCTUnwrap(Bundle.main.url(forResource: "VybeSentence", withExtension: "mlmodelc"))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey,.isRegularFileKey]))
        var bytes = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
        }
        print("MINILM_PROBE production references=\(references.count) styles=\(queries.count) bytes=\(bytes)")
        XCTAssertLessThan(bytes, 25_000_000)
    }

}

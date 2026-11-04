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
        for variant in ["MiniLMIO32", "MiniLM8Bit", "MiniLM8BitIO32", "MiniLM32"] {
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
}

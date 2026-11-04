import CoreML
import XCTest
@testable import MiniLMProbe

final class ProbeTests: XCTestCase {
    struct Reference: Decodable { let text: String; let embedding: [Float] }
    func testCoreMLBackendNumerics() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "VybeSentence", withExtension: "mlmodelc"))
        let vocab = try XCTUnwrap(Bundle.main.url(forResource: "vybe-vocab", withExtension: "txt"))
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vybe-reference-vectors", withExtension: "json"))
        let reference = try XCTUnwrap(JSONDecoder().decode([Reference].self, from: Data(contentsOf: fixture)).first)
        let tokens = WordPieceTokenizer(vocabulary: try String(contentsOf: vocab, encoding: .utf8)).encode(reference.text)
        let ids = try MLMultiArray(shape: [1, 128], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, 128], dataType: .int32)
        for i in 0..<128 { ids[i] = NSNumber(value: tokens.ids[i]); mask[i] = NSNumber(value: tokens.mask[i]) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        var usable = 0
        let modes: [(String, MLComputeUnits)] = [("all", .all), ("cpuOnly", .cpuOnly), ("cpuAndGPU", .cpuAndGPU)]
        for (name, units) in modes {
            do {
                let config = MLModelConfiguration(); config.computeUnits = units
                let model = try MLModel(contentsOf: url, configuration: config)
                print("MINILM_PROBE mode=\(name) outputs=\(model.modelDescription.outputDescriptionsByName)")
                let result = try model.prediction(from: input)
                guard let array = result.featureValue(for: "embedding")?.multiArrayValue else {
                    print("MINILM_PROBE mode=\(name) missing array; features=\(result.featureNames)"); continue
                }
                let vector = (0..<array.count).map { array[$0].floatValue }
                let finite = vector.filter(\.isFinite).count
                let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
                var cosine = Double.nan
                if vector.count == reference.embedding.count, finite == vector.count, norm > 0 {
                    let other = sqrt(reference.embedding.reduce(0.0) { $0 + Double($1) * Double($1) })
                    cosine = zip(vector, reference.embedding).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / (norm * other)
                    if cosine > 0.985 { usable += 1 }
                }
                print("MINILM_PROBE mode=\(name) shape=\(array.shape) strides=\(array.strides) type=\(array.dataType.rawValue) count=\(array.count) finite=\(finite) norm=\(norm) cosine=\(cosine) first=\(Array(vector.prefix(4)))")
            } catch { print("MINILM_PROBE mode=\(name) error=\(error)") }
        }
        do {
            let embedder = try CompactSentenceEmbedder()
            let vector = try embedder.embed(reference.text, role: .query)
            print("MINILM_PROBE production count=\(vector.count) finite=\(vector.allSatisfy(\.isFinite))")
        } catch { print("MINILM_PROBE production error=\(error)") }
        XCTAssertGreaterThan(usable, 0, "At least one backend must reproduce a real reference vector")
    }
}

import CoreML
import Foundation

/// A 6-bit, 22M-parameter sentence transformer running on Apple's CPU/GPU/Neural Engine.
/// Query and document vectors share one space; all inference and resources stay on the phone.
final class CompactSentenceEmbedder: TextEmbedder {
    static let modelIdentity = "minilm-l6-v2-coreml-p6-v1"
    let modelId = "\(CompactSentenceEmbedder.modelIdentity)|doc\(VybeText.documentVersion)"
    let dimension = 384
    let weakBest: Float = 0.30
    let tokenizer: WordPieceTokenizer
    private let model: MLModel
    private var queryCache: [(text: String, vector: [Float])] = []

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "VybeSentence", withExtension: "mlmodelc"),
              let vocabulary = bundle.url(forResource: "vybe-vocab", withExtension: "txt") else {
            throw Failure.missingResources
        }
        tokenizer = WordPieceTokenizer(vocabulary: try String(contentsOf: vocabulary, encoding: .utf8))
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    func embed(_ text: String, role: EmbeddingRole) throws -> [Float] {
        if role == .query, let cached = queryCache.first(where: { $0.text == text }) { return cached.vector }
        let tokens = tokenizer.encode(text)
        let ids = try MLMultiArray(shape: [1, NSNumber(value: WordPieceTokenizer.sequenceLength)], dataType: .int32)
        let mask = try MLMultiArray(shape: ids.shape, dataType: .int32)
        for i in tokens.ids.indices { ids[i] = NSNumber(value: tokens.ids[i]); mask[i] = NSNumber(value: tokens.mask[i]) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        guard let result = try model.prediction(from: input).featureValue(for: "embedding")?.multiArrayValue,
              result.count == dimension else { throw Failure.invalidOutput }
        var vector = (0..<dimension).map { result[$0].floatValue }
        let norm = vector.reduce(Double(0)) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm.isFinite, norm > 0, vector.allSatisfy(\.isFinite) else { throw Failure.invalidOutput }
        vector = vector.map { Float(Double($0) / norm) }
        if role == .query {
            queryCache.insert((text, vector), at: 0)
            if queryCache.count > 24 { queryCache.removeLast() }
        }
        return vector
    }

    enum Failure: LocalizedError {
        case missingResources, invalidOutput
        var errorDescription: String? {
            switch self {
            case .missingResources: "The offline search model is missing. Please reinstall Erhu."
            case .invalidOutput: "The offline search model couldn't read this description."
            }
        }
    }
}

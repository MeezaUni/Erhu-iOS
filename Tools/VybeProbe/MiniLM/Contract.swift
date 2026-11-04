// Minimal contract for compiling the production embedder without the rest of the app.
enum EmbeddingRole: Equatable { case query, document }
enum VybeText { static let documentVersion = 1 }
protocol TextEmbedder {
    var modelId: String { get }
    var dimension: Int { get }
    var weakBest: Float { get }
    func embed(_ text: String, role: EmbeddingRole) throws -> [Float]
}

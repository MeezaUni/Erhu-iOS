import Foundation

/// The bundled encoder's BERT uncased tokenizer. No downloads or tokenizer runtime are needed.
struct WordPieceTokenizer {
    static let sequenceLength = 128
    private let vocabulary: [String: Int32]

    init(vocabulary: String) {
        self.vocabulary = Dictionary(vocabulary.components(separatedBy: "\n").enumerated()
            .filter { !$0.element.isEmpty }.map { ($0.element, Int32($0.offset)) }, uniquingKeysWith: { first, _ in first })
    }

    func encode(_ text: String) -> (ids: [Int32], mask: [Int32]) {
        var ids: [Int32] = [101] // [CLS]
        for word in basicTokens(text) {
            let pieces = wordPieces(word)
            ids.append(contentsOf: pieces.prefix(Self.sequenceLength - 1 - ids.count))
            if ids.count == Self.sequenceLength - 1 { break }
        }
        ids.append(102) // [SEP]
        let count = ids.count
        ids += repeatElement(0, count: Self.sequenceLength - count)
        return (ids, (0..<Self.sequenceLength).map { $0 < count ? 1 : 0 })
    }

    private func wordPieces(_ word: String) -> [Int32] {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count <= 100 else { return [100] } // [UNK]
        var pieces: [Int32] = []
        var start = 0
        while start < scalars.count {
            var end = scalars.count
            var found: Int32?
            while end > start {
                let piece = String(String.UnicodeScalarView(scalars[start..<end]))
                if let id = vocabulary[(start == 0 ? "" : "##") + piece] { found = id; break }
                end -= 1
            }
            guard let found else { return [100] }
            pieces.append(found)
            start = end
        }
        return pieces
    }

    private func basicTokens(_ text: String) -> [String] {
        var clean = ""
        // A bounded input prevents pathological pasted text from blocking library indexing.
        for scalar in text.unicodeScalars.prefix(8192) {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { clean.append(" ") }
            else if scalar.value == 0 || scalar.value == 0xFFFD || CharacterSet.controlCharacters.contains(scalar) { continue }
            else if Self.isChinese(scalar.value) { clean.append(" \(scalar) ") }
            else { clean.unicodeScalars.append(scalar) }
        }
        let lowered = clean.lowercased().decomposedStringWithCanonicalMapping
        var words: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { words.append(word); word = "" } }
        for scalar in lowered.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { flush() }
            else if Self.isPunctuation(scalar) { flush(); words.append(String(scalar)) }
            else { word.unicodeScalars.append(scalar) }
        }
        flush()
        return words
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let n = scalar.value
        return (33...47).contains(n) || (58...64).contains(n) || (91...96).contains(n)
            || (123...126).contains(n) || CharacterSet.punctuationCharacters.contains(scalar)
    }

    private static func isChinese(_ n: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(n) || (0x3400...0x4DBF).contains(n) || (0x20000...0x2A6DF).contains(n)
            || (0x2A700...0x2B73F).contains(n) || (0x2B740...0x2B81F).contains(n)
            || (0x2B820...0x2CEAF).contains(n) || (0xF900...0xFAFF).contains(n) || (0x2F800...0x2FA1F).contains(n)
    }
}

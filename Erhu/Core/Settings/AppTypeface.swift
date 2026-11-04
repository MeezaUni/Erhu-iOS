import SwiftUI

enum AppTypeface: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

import SwiftUI

extension Text {
    /// Interface copy that reaches a view as a `String` (a component's title, an empty-state message):
    /// looked up in the string catalog, and shown unchanged when there is no translation for it.
    /// Library content (song, album and artist names) must keep using `Text(_:)` or `Text(verbatim:)`.
    init(ui string: String) {
        self.init(LocalizedStringKey(string))
    }
}

extension String {
    /// The translated form of interface copy held in a `String`, or the string itself when the catalog has
    /// no entry. Use only for fixed interface text, never for library content.
    var ui: String {
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}

extension String.LocalizationValue.StringInterpolation {
    /// Lets translatable interface text include any value (an error, a count of another integer type, an
    /// enum): it is inserted as text, like a `%@` argument. Strings, integers and floating-point values
    /// still use their own, more specific overloads.
    mutating func appendInterpolation<T>(_ value: T) {
        appendInterpolation(String(describing: value))
    }
}

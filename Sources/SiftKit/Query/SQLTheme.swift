import MetalUI
import SiftCore

/// The SQL editor's colours, each with a light and a dark value, in this one place.
///
/// Keywords use the accent colour and comments `.secondary`, which already follow the scheme. Comments are also
/// italic: `CodeStyle` carries `italic` and `weight`, drawn with the font's real faces (G15).
enum SQLTheme {
    static let keyword = Color.accent
    static let string = Color(light: Color(hex: 0x1A7F37), dark: Color(hex: 0x56D364))
    static let number = Color(light: Color(hex: 0xB35900), dark: Color(hex: 0xFFA657))
    static let comment = Color.secondary
    static let parameter = Color(light: Color(hex: 0x8250DF), dark: Color(hex: 0xD2A8FF))
    /// The wavy underline and the gutter marker of an error.
    static let error = Color.red

    /// The colour a token kind is drawn in; nil for the kinds that keep the editor's text colour.
    static func color(for kind: SQLTokenKind) -> Color? {
        switch kind {
        case .keyword: return keyword
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .parameter: return parameter
        case .identifier, .quotedIdentifier, .operator_, .punctuation, .whitespace: return nil
        }
    }

    /// The style a token kind is drawn in; nil for the kinds that keep the editor's text style.
    static func style(for kind: SQLTokenKind) -> CodeStyle? {
        guard let color = color(for: kind) else { return nil }
        return CodeStyle(foreground: color, italic: kind == .comment ? true : nil)
    }
}

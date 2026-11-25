import Foundation
import SiftCore

/// How a cell is drawn.
public enum CellStyle: Equatable, Sendable {
    /// SQL NULL: italic, in the tertiary colour.
    case null
    /// An empty string.
    case empty
    case number
    case mono
    /// An enum label, on a subtle capsule.
    case enumLabel
    case plain
}

public enum CellAlignment: Equatable, Sendable {
    case leading
    case trailing
}

/// What a cell shows: its text, its style and the side it aligns to.
public struct CellText: Equatable, Sendable {
    public var text: String
    public var style: CellStyle
    public var alignment: CellAlignment

    public init(text: String, style: CellStyle = .plain, alignment: CellAlignment = .leading) {
        self.text = text
        self.style = style
        self.alignment = alignment
    }
}

/// The rules for drawing a value in a grid cell, as pure functions so they are testable without a window.
public enum CellFormat {
    /// A cell never holds more than this many characters: a megabyte of text is shaped lazily, not here.
    public static let characterLimit = 200

    static let numericTypes: Set<String> = [
        "int2", "int4", "int8", "float4", "float8", "numeric", "smallint", "integer", "bigint", "real", "double precision",
        "money", "oid"
    ]
    static let textTypes: Set<String> = ["text", "varchar", "bpchar", "name", "char", "character varying", "character", "citext"]

    public static func isNumeric(_ column: ResultColumn) -> Bool { numericTypes.contains(column.typeName.lowercased()) }
    public static func isTextLike(_ column: ResultColumn) -> Bool { textTypes.contains(column.typeName.lowercased()) }

    /// Numbers align trailing; everything else leading.
    public static func alignment(for column: ResultColumn) -> CellAlignment { isNumeric(column) ? .trailing : .leading }

    /// The cell for `value` in `column`. `timeZone` is the one a timestamptz is shown in.
    public static func format(_ value: SiftValue, column: ResultColumn, timeZone: TimeZone = .current) -> CellText {
        let alignment = alignment(for: column)
        switch value {
        case .null:
            return CellText(text: "NULL", style: .null, alignment: alignment)
        case .bool(let b):
            return CellText(text: b ? "true" : "false")
        case .int(let n):
            return CellText(text: String(n), style: .number, alignment: .trailing)
        case .double(let d):
            return CellText(text: SiftValue.double(d).displayText, style: .number, alignment: .trailing)
        case .bytes(let bytes):
            return CellText(text: bytesText(bytes), style: .mono)
        case .text(let s), .raw(let s):
            if s.isEmpty { return CellText(text: isTextLike(column) ? "\"\"" : "", style: .empty, alignment: alignment) }
            let type = column.typeName.lowercased()
            if isNumeric(column) { return CellText(text: clip(s), style: .number, alignment: .trailing) }
            if column.isEnum { return CellText(text: clip(s), style: .enumLabel) }
            switch type {
            case "uuid":
                return CellText(text: clip(s), style: .mono)
            case "timestamptz":
                return CellText(text: timestamptz(s, in: timeZone) ?? clip(s))
            case "json", "jsonb":
                return CellText(text: clip(JSONText.compact(s)))
            default:
                return CellText(text: clip(oneLine(s)), alignment: alignment)
            }
        }
    }

    /// The value as the server wrote it, with nothing cut: what ⌘C copies. NULL copies as an empty string.
    public static func rawText(_ value: SiftValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .double(let d): return "\(d)"
        case .text(let s), .raw(let s): return s
        case .bytes(let bytes): return "\\x" + hex(bytes)
        }
    }

    // MARK: Pieces

    static func clip(_ s: String) -> String {
        s.count > characterLimit ? String(s.prefix(characterLimit)) + "\u{2026}" : s
    }

    /// A cell is one line: a break reads as a space.
    static func oneLine(_ s: String) -> String {
        guard s.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else { return s }
        return String(s.map { $0 == "\n" || $0 == "\r" || $0 == "\t" ? " " : $0 })
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return out
    }

    /// `\xdeadbeef (4 bytes)`: the first 16 bytes in hex, then the length.
    static func bytesText(_ bytes: [UInt8]) -> String {
        let shown = hex(bytes.prefix(16)) + (bytes.count > 16 ? "\u{2026}" : "")
        return "\\x\(shown) (\(bytes.count) \(bytes.count == 1 ? "byte" : "bytes"))"
    }

    // MARK: timestamptz

    /// `2026-11-21 10:00:00+00` in `timeZone`, as `2026-11-21 02:00:00 PST`. Nil when the text is not that form
    /// (`infinity`, say), so the caller shows it unchanged. Fractions of a second are dropped; the inspector has them.
    public static func timestamptz(_ text: String, in timeZone: TimeZone) -> String? {
        guard let seconds = epochSeconds(ofTimestamptz: text) else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let offset = timeZone.secondsFromGMT(for: date)
        let local = civil(fromEpoch: seconds + offset)
        let zone = timeZone.abbreviation(for: date) ?? offsetName(offset)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let year = local.year < 1000 ? String(repeating: "0", count: 4 - String(local.year).count) + String(local.year) : String(local.year)
        return "\(year)-\(two(local.month))-\(two(local.day)) \(two(local.hour)):\(two(local.minute)):\(two(local.second)) \(zone)"
    }

    private static func offsetName(_ offset: Int) -> String {
        let sign = offset < 0 ? "-" : "+"
        let a = abs(offset)
        let h = a / 3600, m = (a % 3600) / 60
        return "UTC\(sign)\(h < 10 ? "0" : "")\(h):\(m < 10 ? "0" : "")\(m)"
    }

    /// Seconds since 1970-01-01T00:00:00Z of `YYYY-MM-DD HH:MM:SS[.ffffff]±HH[:MM[:SS]]`, or nil.
    static func epochSeconds(ofTimestamptz text: String) -> Int? {
        let bytes = Array(text.utf8)
        var i = 0
        func number(_ digits: Int) -> Int? {
            guard i + digits <= bytes.count else { return nil }
            var n = 0
            for k in 0..<digits {
                let b = bytes[i + k]
                guard b >= 48, b <= 57 else { return nil }
                n = n * 10 + Int(b - 48)
            }
            i += digits
            return n
        }
        func expect(_ ch: UInt8) -> Bool {
            guard i < bytes.count, bytes[i] == ch else { return false }
            i += 1
            return true
        }
        guard let y = number(4), expect(45), let mo = number(2), expect(45), let d = number(2),
            expect(32) || expect(84), let h = number(2), expect(58), let mi = number(2), expect(58), let s = number(2)
        else { return nil }
        if i < bytes.count, bytes[i] == 46 {
            i += 1
            while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 { i += 1 }
        }
        var offset = 0
        if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 {
            let sign = bytes[i] == 45 ? -1 : 1
            i += 1
            guard let oh = number(2) else { return nil }
            var om = 0, os = 0
            if expect(58) { guard let m = number(2) else { return nil }; om = m
                if expect(58) { guard let sec = number(2) else { return nil }; os = sec }
            }
            offset = sign * (oh * 3600 + om * 60 + os)
        } else if i < bytes.count, bytes[i] == 90 {
            i += 1
        }
        guard i == bytes.count, (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }
        return daysFromCivil(year: y, month: mo, day: d) * 86_400 + h * 3600 + mi * 60 + s - offset
    }

    /// Howard Hinnant's days-from-civil: days since 1970-01-01 of a proleptic Gregorian date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// A calendar date and time of day, in whatever zone the epoch seconds were shifted into.
    struct CivilTime: Equatable {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
    }

    static func civil(fromEpoch seconds: Int) -> CivilTime {
        var days = seconds / 86_400
        var rest = seconds % 86_400
        if rest < 0 { rest += 86_400; days -= 1 }
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return CivilTime(year: year, month: month, day: day, hour: rest / 3600, minute: (rest % 3600) / 60, second: rest % 60)
    }
}

/// JSON text, handled as text so key order and number spelling survive.
public enum JSONText {
    /// The same JSON on one line with no insignificant whitespace. Anything between quotes is left alone.
    public static func compact(_ json: String) -> String {
        var out = ""
        out.reserveCapacity(json.count)
        var inString = false
        var escaped = false
        for ch in json {
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
                out.append(ch)
            } else if ch == " " || ch == "\n" || ch == "\r" || ch == "\t" {
                continue
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

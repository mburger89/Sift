import Foundation
import SiftCore
import Testing

@testable import SiftKit

struct CellFormatTests {
    func column(_ type: String, isEnum: Bool = false) -> ResultColumn {
        ResultColumn(name: "c", typeOID: 0, typeName: type, isEnum: isEnum)
    }
    func format(_ value: SiftValue, _ type: String, isEnum: Bool = false, zone: String = "UTC") -> CellText {
        CellFormat.format(value, column: column(type, isEnum: isEnum), timeZone: TimeZone(identifier: zone)!)
    }

    @Test func nullIsItalicNULLInTheTertiaryStyle() {
        #expect(format(.null, "text") == CellText(text: "NULL", style: .null))
        #expect(format(.null, "int8").alignment == .trailing)
    }

    @Test func nullAndEmptyStringAreDistinct() {
        let null = format(.null, "text")
        let empty = format(.text(""), "text")
        #expect(null != empty)
        #expect(null.style == .null && empty.style == .empty)
        #expect(empty.text == "\"\"", "a faint empty-string marker in a text column")
        // Not text-like: nothing is drawn.
        #expect(format(.text(""), "uuid") == CellText(text: "", style: .empty))
        #expect(format(.text("NULL"), "text").style == .plain, "the text NULL is not NULL")
    }

    @Test func numbersAlignTrailing() {
        #expect(format(.int(42), "int8") == CellText(text: "42", style: .number, alignment: .trailing))
        #expect(format(.double(2.5), "float8").alignment == .trailing)
        #expect(format(.text("1.50"), "numeric") == CellText(text: "1.50", style: .number, alignment: .trailing))
        #expect(CellFormat.alignment(for: column("numeric")) == .trailing)
        #expect(CellFormat.alignment(for: column("text")) == .leading)
    }

    @Test func numericKeepsItsExactText() {
        let exact = "12345678901234567890.0001"
        #expect(format(.text(exact), "numeric").text == exact)
        #expect(format(.text("0.10"), "numeric").text == "0.10", "no trailing zero is lost")
    }

    @Test func boolsAreTrueAndFalse() {
        #expect(format(.bool(true), "bool").text == "true")
        #expect(format(.bool(false), "bool").text == "false")
    }

    @Test func aUuidIsMonospaced() {
        let id = "00000000-0000-0000-0000-00000000000a"
        #expect(format(.text(id), "uuid") == CellText(text: id, style: .mono))
    }

    @Test func timestamptzIsShownInTheGivenTimeZone() {
        let sample = "2026-11-21 10:00:00+00"
        // The zone's abbreviation is the platform's: `PST` where Foundation has the names (Darwin), `GMT-8` where it
        // has only offsets (swift-corelibs on Linux and Windows).
        let winter = format(.text(sample), "timestamptz", zone: "America/Los_Angeles").text
        #expect(["2026-11-21 02:00:00 PST", "2026-11-21 02:00:00 GMT-8"].contains(winter))
        #expect(format(.text(sample), "timestamptz", zone: "UTC").text.hasPrefix("2026-11-21 10:00:00 "))
        // An offset in the text moves the instant, and fractions are dropped.
        #expect(format(.text("2026-11-21 10:00:00.123456+05:30"), "timestamptz", zone: "UTC").text.hasPrefix("2026-11-21 04:30:00 "))
        // Summer time, and a date across midnight.
        let summer = format(.text("2026-07-01 03:00:00+00"), "timestamptz", zone: "America/Los_Angeles").text
        #expect(["2026-06-30 20:00:00 PDT", "2026-06-30 20:00:00 GMT-7"].contains(summer))
        // What is not a timestamp stays as it is.
        #expect(format(.text("infinity"), "timestamptz").text == "infinity")
    }

    @Test func timestampArithmeticIsExact() {
        #expect(CellFormat.epochSeconds(ofTimestamptz: "1970-01-01 00:00:00+00") == 0)
        #expect(CellFormat.epochSeconds(ofTimestamptz: "2000-03-01 00:00:00+00") == 951_868_800)
        #expect(CellFormat.epochSeconds(ofTimestamptz: "2024-02-29 12:00:00-08") == 1_709_236_800)
        #expect(CellFormat.epochSeconds(ofTimestamptz: "1969-12-31 23:59:59+00") == -1)
        let civil = CellFormat.civil(fromEpoch: 1_709_236_800)
        #expect(civil.year == 2024 && civil.month == 2 && civil.day == 29 && civil.hour == 20)
        let before = CellFormat.civil(fromEpoch: -1)
        #expect(before.year == 1969 && before.month == 12 && before.day == 31 && before.second == 59)
    }

    @Test func jsonIsCompactedToOneLine() {
        let text = "{\"a\": [1, 2, {\"b\": null}], \"c\": \"x  y\"}"
        #expect(format(.raw(text), "jsonb") == CellText(text: "{\"a\":[1,2,{\"b\":null}],\"c\":\"x  y\"}"))
        #expect(format(.raw("{\n  \"k\": \"a \\\" b\"\n}"), "json").text == "{\"k\":\"a \\\" b\"}")
        let long = "[" + Array(repeating: "1", count: 400).joined(separator: ",") + "]"
        #expect(format(.raw(long), "jsonb").text.count == CellFormat.characterLimit + 1)
        #expect(format(.raw(long), "jsonb").text.hasSuffix("\u{2026}"))
    }

    @Test func arraysShowThePostgresLiteral() {
        #expect(format(.raw("{1,2,3}"), "int4[]").text == "{1,2,3}")
        #expect(format(.raw("{\"a b\",NULL}"), "text[]").text == "{\"a b\",NULL}")
    }

    @Test func anEnumIsItsLabelOnACapsule() {
        #expect(format(.raw("happy"), "mood", isEnum: true) == CellText(text: "happy", style: .enumLabel))
    }

    @Test func byteaShowsHexAndLength() {
        #expect(format(.bytes([0xde, 0xad, 0xbe, 0xef]), "bytea").text == "\\xdeadbeef (4 bytes)")
        #expect(format(.bytes([1]), "bytea").text == "\\x01 (1 byte)")
        #expect(format(.bytes([]), "bytea").text == "\\x (0 bytes)")
        let long = format(.bytes(Array(repeating: 0xab, count: 40)), "bytea").text
        #expect(long == "\\x" + String(repeating: "ab", count: 16) + "\u{2026} (40 bytes)")
        #expect(format(.bytes([1]), "bytea").style == .mono)
    }

    @Test func longTextIsClippedAndBreaksReadAsSpaces() {
        #expect(format(.text(String(repeating: "x", count: 500)), "text").text.count == CellFormat.characterLimit + 1)
        #expect(format(.text("a\nb\tc"), "text").text == "a b c")
    }

    @Test func rawTextCopiesTheWholeValue() {
        #expect(CellFormat.rawText(.null) == "")
        #expect(CellFormat.rawText(.text(String(repeating: "y", count: 500))).count == 500)
        #expect(CellFormat.rawText(.bytes([0xde, 0xad])) == "\\xdead")
        #expect(CellFormat.rawText(.int(-5)) == "-5")
        #expect(CellFormat.rawText(.raw("{\"a\": 1}")) == "{\"a\": 1}")
    }
}

struct JSONTreeTests {
    @Test func parsesObjectsInOrderAndKeepsNumbersAsWritten() throws {
        let node = try #require(JSONNode.parse("{\"b\": 1.50, \"a\": [true, null, {\"c\": \"x\"}]}"))
        guard case .object(let members) = node else { Issue.record("not an object"); return }
        #expect(members.map(\.key) == ["b", "a"])
        #expect(members[0].value == .number("1.50"))
        #expect(node.summary == "{2}")
        #expect(members[1].value.summary == "[3]")
    }

    @Test func prettyPrintsWithTwoSpaceIndents() throws {
        let node = try #require(JSONNode.parse("{\"a\":[1,{\"b\":null}],\"c\":{}}"))
        #expect(node.pretty() == "{\n  \"a\": [\n    1,\n    {\n      \"b\": null\n    }\n  ],\n  \"c\": {}\n}")
    }

    @Test func rejectsWhatIsNotOneJSONValue() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "nul", "1 2", "{\"a\": }", "\"abc"] {
            #expect(JSONNode.parse(bad) == nil, "\(bad)")
        }
        #expect(JSONNode.parse(" 12 ") == .number("12"))
        #expect(JSONNode.parse("\"a\\\"b\"") == .string("a\\\"b"))
    }

    @Test func aDeeplyNestedDocumentIsRefusedNotCrashed() {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(JSONNode.parse(deep) == nil)
    }
}

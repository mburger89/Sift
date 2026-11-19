import SiftCore
import Testing

@testable import SiftKit

struct ValueFormattingTests {
    @Test func bytesTruncate() {
        #expect(SiftValue.bytes([1, 2, 255]).displayText == "\\x0102ff")
        let long = SiftValue.bytes([UInt8](repeating: 0xAB, count: 40)).displayText
        #expect(long == "\\x" + String(repeating: "ab", count: 32) + "…")
        #expect(SiftValue.bytes([]).displayText == "\\x")
    }

    @Test func doublesUseShortestForm() {
        #expect(SiftValue.double(2.25).displayText == "2.25")
        #expect(SiftValue.double(3.0).displayText == "3")
        #expect(SiftValue.double(0.1).displayText == "0.1")
        #expect(SiftValue.double(-1.5).displayText == "-1.5")
        #expect(SiftValue.double(.nan).displayText == "NaN")
    }

    @Test func longTextTruncatesAt200Characters() {
        let long = String(repeating: "x", count: 300)
        #expect(SiftValue.text(long).displayText == String(repeating: "x", count: 200) + "…")
        #expect(SiftValue.raw(long).displayText.count == 201)
        #expect(SiftValue.text("short").displayText == "short")
    }

    @Test func scalarsReadPlainly() {
        #expect(SiftValue.int(-42).displayText == "-42")
        #expect(SiftValue.bool(true).displayText == "true")
        #expect(SiftValue.null.displayText == "NULL")
    }

    @Test func rowEstimatesReadAsEstimates() {
        #expect(RowEstimate.estimated(3).displayText == "≈3 rows")
        #expect(RowEstimate.estimated(1).displayText == "≈1 row")
        #expect(RowEstimate.unknown.displayText == "rows unknown")
        #expect(RowEstimate.estimated(1_234_567).displayText == "≈1,234,567 rows")
        #expect(RowEstimate.exactText(3) == "3 rows (exact)")
    }
}

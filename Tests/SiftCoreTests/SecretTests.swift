import SiftCore
import Testing

@Suite struct SecretTests {
    let s = Secret("s3cret")

    @Test func descriptionNeverShowsTheValue() {
        #expect(String(describing: s) == "••••••")
        #expect(String(reflecting: s) == "Secret(••••••)")
        #expect(!"\(s)".contains("s3cret"))
        #expect(!String(describing: [s]).contains("s3cret"))
    }

    @Test func mirrorHasNoChildren() {
        #expect(Mirror(reflecting: s).children.isEmpty)
        #expect(!String(reflecting: Wrapper(secret: s)).contains("s3cret"))
    }

    @Test func revealReturnsTheValue() {
        #expect(s.reveal() == "s3cret")
    }

    private struct Wrapper { var secret: Secret }
}

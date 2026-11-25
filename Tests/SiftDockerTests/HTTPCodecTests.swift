import Testing

@testable import SiftDocker

@Suite struct HTTPCodecTests {
    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func requestIsHTTP11WithHostAndClose() {
        let expected =
            "GET /containers/json?all=1 HTTP/1.1\r\nHost: docker\r\nUser-Agent: Sift\r\nAccept: application/json\r\n"
            + "Connection: close\r\n\r\n"
        #expect(HTTPCodec.getRequest(path: "/containers/json?all=1") == Self.bytes(expected))
    }

    @Test func parsesContentLength() throws {
        let response = try HTTPCodec.parse(Self.bytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]trailing"))
        #expect(response.status == 200)
        #expect(response.body == Self.bytes("[]"))
    }

    @Test func parsesChunkedWithExtensionsAndTrailers() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX: y\r\n\r\n"
        #expect(try HTTPCodec.parse(Self.bytes(raw)).body == Self.bytes("hello world"))
    }

    @Test func truncatedChunkIsMalformed() {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"
        #expect(throws: DockerError.malformedResponse("truncated chunk")) { try HTTPCodec.parse(Self.bytes(raw)) }
    }

    @Test func headerNamesAreCaseInsensitive() throws {
        let response = try HTTPCodec.parse(Self.bytes("HTTP/1.1 404 Not Found\r\nCONTENT-length: 1\r\nX-Thing:  v \r\n\r\nx"))
        #expect(response.headers["content-length"] == "1")
        #expect(response.headers["x-thing"] == "v")
        #expect(response.body == Self.bytes("x"))
    }

    @Test func bodyOverTheCapIsRefused() {
        let head = "HTTP/1.1 200 OK\r\nContent-Length: \(16 * 1024 * 1024 + 1)\r\n\r\n"
        #expect(throws: DockerError.malformedResponse("body over the 16 MiB cap")) { try HTTPCodec.parse(Self.bytes(head)) }
        #expect(throws: DockerError.malformedResponse("body over the 16 MiB cap")) {
            try HTTPCodec.parse(Self.bytes("HTTP/1.1 200 OK\r\n\r\n") + [UInt8](repeating: 0x41, count: 16 * 1024 * 1024 + 1))
        }
    }
}

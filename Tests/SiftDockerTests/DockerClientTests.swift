import SiftTestSupport
import Testing

@testable import SiftDocker

@Suite struct DockerClientTests {
    static func fakeClient(_ response: String, chunkSize: Int = 1) -> DockerClient {
        let bytes = Array(response.utf8)
        let chunks = stride(from: 0, to: bytes.count, by: chunkSize).map { Array(bytes[$0..<min($0 + chunkSize, bytes.count)]) }
        return DockerClient(endpoint: .unixSocket(path: "/unused"), connect: { _, _ in FakeByteStream(chunks: chunks) })
    }

    @Test func readsUntilEOFAcrossOneByteReads() throws {
        let client = Self.fakeClient("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]")
        #expect(try client.get("/containers/json").body == Array("[]".utf8))
    }

    @Test func writesTheRequest() throws {
        let stream = FakeByteStream(chunks: [Array("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)])
        let client = DockerClient(endpoint: .unixSocket(path: "/unused"), connect: { _, _ in stream })
        _ = try client.get("/_ping")
        #expect(stream.written == HTTPCodec.getRequest(path: "/_ping"))
    }

    @Test func nonSuccessCarriesTheDockerMessage() {
        let body = #"{"message":"No such container: x"}"#
        let client = Self.fakeClient("HTTP/1.1 404 Not Found\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", chunkSize: 16)
        #expect(throws: DockerError.http(status: 404, message: "No such container: x")) { try client.get("/containers/x/json") }
    }

    @Test func getOverARealSocketOrPipe() throws {
        let daemon = try FakeDockerDaemon(routes: ["/_ping": .init(body: "OK")])
        defer { daemon.stop() }
        let client = DockerClient(endpoint: daemon.endpoint)
        #expect(try client.get("/_ping").body == Array("OK".utf8))
        #expect(daemon.requests == ["GET /_ping"])
    }

    @Test(.timeLimit(.minutes(1))) func aSilentDaemonTimesOut() throws {
        let daemon = try FakeDockerDaemon(routes: ["/_ping": .init(silent: true)])
        defer { daemon.stop() }
        let client = DockerClient(endpoint: daemon.endpoint, timeoutSeconds: 0.5)
        #expect(throws: DockerError.timedOut) { try client.get("/_ping") }
    }

    @Test func chunkedResponsesWorkOverTheWire() throws {
        let daemon = try FakeDockerDaemon(routes: ["/x": .init(body: "hello world", chunked: true)])
        defer { daemon.stop() }
        #expect(try DockerClient(endpoint: daemon.endpoint).get("/x").body == Array("hello world".utf8))
    }
}

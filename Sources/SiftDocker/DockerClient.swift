import Foundation

/// A minimal HTTP/1.1 GET client for the Docker Engine API.
public struct DockerClient: Sendable {
    public typealias Connect = @Sendable (DockerEndpoint, Double) throws -> ByteStream

    public var endpoint: DockerEndpoint
    public var timeoutSeconds: Double
    private let connect: Connect

    public init(endpoint: DockerEndpoint, timeoutSeconds: Double = 3, connect: Connect? = nil) {
        self.endpoint = endpoint
        self.timeoutSeconds = timeoutSeconds
        self.connect = connect ?? Self.liveConnect
    }

    static let liveConnect: Connect = { endpoint, timeout in
        switch endpoint {
        case .unixSocket(let path):
            #if os(Windows)
            throw DockerError.connectFailed("unix sockets are not available on Windows: \(path)")
            #else
            return try UnixSocketStream(path: path, timeoutSeconds: timeout)
            #endif
        case .namedPipe(let path):
            #if os(Windows)
            return try NamedPipeStream(path: path, timeoutSeconds: timeout)
            #else
            throw DockerError.connectFailed("named pipes are only available on Windows: \(path)")
            #endif
        }
    }

    /// Sends `GET path`, reads to end of stream and returns the response. A non-2xx status throws.
    public func get(_ path: String) throws(DockerError) -> HTTPResponse {
        let stream: ByteStream
        do {
            stream = try connect(endpoint, timeoutSeconds)
        } catch let error as DockerError {
            throw error
        } catch {
            throw .connectFailed("\(error)")
        }
        defer { stream.close() }
        try stream.write(HTTPCodec.getRequest(path: path))
        var received: [UInt8] = []
        let cap = HTTPCodec.maxBodyBytes + 64 * 1024
        while true {
            let chunk = try stream.read(maxCount: 64 * 1024)
            if chunk.isEmpty { break }
            received.append(contentsOf: chunk)
            if received.count > cap { throw .malformedResponse("response over the 16 MiB cap") }
        }
        let response = try HTTPCodec.parse(received)
        guard (200..<300).contains(response.status) else {
            throw .http(status: response.status, message: Self.message(in: response))
        }
        return response
    }

    private static func message(in response: HTTPResponse) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(response.body)) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        return String(decoding: response.body.prefix(200), as: UTF8.self)
    }
}

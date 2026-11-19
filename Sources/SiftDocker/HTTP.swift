import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: [UInt8]

    public init(status: Int, headers: [String: String], body: [UInt8]) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum HTTPCodec {
    /// The most body (and the most bytes read off the wire) Sift accepts: 16 MiB.
    public static let maxBodyBytes = 16 * 1024 * 1024

    public static func getRequest(path: String) -> [UInt8] {
        Array(
            ("GET \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: Sift\r\nAccept: application/json\r\nConnection: close\r\n\r\n").utf8
        )
    }

    public static func parse(_ bytes: [UInt8]) throws(DockerError) -> HTTPResponse {
        let separator: [UInt8] = [13, 10, 13, 10]
        guard let headEnd = find(separator, in: bytes, from: 0) else {
            throw .malformedResponse("no end of headers")
        }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw .malformedResponse("bad status line")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw .malformedResponse("bad header line") }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingSpaces()
            headers[name] = value
        }
        let bodyStart = headEnd + separator.count
        let body: [UInt8]
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunked(bytes, from: bodyStart)
        } else if let length = headers["content-length"] {
            guard let count = Int(length), count >= 0 else { throw .malformedResponse("bad content-length") }
            guard count <= maxBodyBytes else { throw .malformedResponse("body over the 16 MiB cap") }
            guard bytes.count - bodyStart >= count else { throw .malformedResponse("truncated body") }
            body = Array(bytes[bodyStart..<(bodyStart + count)])
        } else {
            guard bytes.count - bodyStart <= maxBodyBytes else { throw .malformedResponse("body over the 16 MiB cap") }
            body = Array(bytes[bodyStart...])
        }
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    private static func decodeChunked(_ bytes: [UInt8], from start: Int) throws(DockerError) -> [UInt8] {
        var body: [UInt8] = []
        var position = start
        let crlf: [UInt8] = [13, 10]
        while true {
            guard let lineEnd = find(crlf, in: bytes, from: position) else {
                throw .malformedResponse("truncated chunk header")
            }
            let line = String(decoding: bytes[position..<lineEnd], as: UTF8.self)
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let size = Int(sizeText.trimmingSpaces(), radix: 16), size >= 0 else {
                throw .malformedResponse("bad chunk size")
            }
            position = lineEnd + 2
            if size == 0 { return body }  // trailers, if any, are ignored
            guard body.count + size <= maxBodyBytes else { throw .malformedResponse("body over the 16 MiB cap") }
            guard bytes.count >= position + size + 2 else { throw .malformedResponse("truncated chunk") }
            body.append(contentsOf: bytes[position..<(position + size)])
            guard bytes[position + size] == 13, bytes[position + size + 1] == 10 else {
                throw .malformedResponse("chunk not terminated")
            }
            position += size + 2
        }
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        var i = start
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}

extension StringProtocol {
    fileprivate func trimmingSpaces() -> String {
        var s = Substring(self)
        while s.first == " " || s.first == "\t" { s = s.dropFirst() }
        while s.last == " " || s.last == "\t" { s = s.dropLast() }
        return String(s)
    }
}

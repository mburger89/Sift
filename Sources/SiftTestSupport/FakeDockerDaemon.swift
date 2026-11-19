import Foundation
import SiftDocker

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

/// A tiny Docker daemon for tests: a real unix socket (POSIX) or named pipe (Windows)
/// that answers fixed routes and records every request line.
public final class FakeDockerDaemon: @unchecked Sendable {
    public struct Route: Sendable {
        public var status: Int
        public var body: [UInt8]
        public var chunked: Bool
        /// Read the request, then never answer.
        public var silent: Bool

        public init(status: Int = 200, body: [UInt8] = [], chunked: Bool = false, silent: Bool = false) {
            self.status = status
            self.body = body
            self.chunked = chunked
            self.silent = silent
        }

        public init(status: Int = 200, body: String, chunked: Bool = false) {
            self.init(status: status, body: Array(body.utf8), chunked: chunked)
        }
    }

    public let endpoint: DockerEndpoint
    private let routes: [String: Route]
    private let lock = NSLock()
    private var _requests: [String] = []
    private var stopped = false

    /// "GET /path" for each request, in arrival order.
    public var requests: [String] { lock.withLock { _requests } }

    fileprivate var isStopped: Bool { lock.withLock { stopped } }

    fileprivate func record(_ requestLine: String) {
        let parts = requestLine.split(separator: " ")
        lock.withLock { _requests.append(parts.prefix(2).joined(separator: " ")) }
    }

    fileprivate func response(for requestLine: String) -> Route? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return routes[String(parts[1])]
    }

    fileprivate func encode(_ route: Route?) -> [UInt8] {
        let route = route ?? Route(status: 404, body: #"{"message":"page not found"}"#)
        var head = "HTTP/1.1 \(route.status) Fake\r\nContent-Type: application/json\r\nConnection: close\r\n"
        var out: [UInt8] = []
        if route.chunked {
            head += "Transfer-Encoding: chunked\r\n\r\n"
            out += Array(head.utf8)
            let half = route.body.count / 2
            for part in [Array(route.body[..<half]), Array(route.body[half...])] where !part.isEmpty {
                out += Array(String(part.count, radix: 16).utf8) + [13, 10] + part + [13, 10]
            }
            out += Array("0\r\n\r\n".utf8)
        } else {
            head += "Content-Length: \(route.body.count)\r\n\r\n"
            out += Array(head.utf8) + route.body
        }
        return out
    }

    private static func requestLine(in bytes: [UInt8]) -> String? {
        guard let end = bytes.firstIndex(of: 13) else { return nil }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    #if !os(Windows)

    private let listener: Int32
    private let path: String

    public init(routes: [String: Route]) throws {
        self.routes = routes
        let name = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
        path = "/tmp/sift-\(name).sock"
        endpoint = .unixSocket(path: path)

        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw DockerError.connectFailed("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Foundation.close(fd)
            throw DockerError.connectFailed("bind \(path)")
        }
        listener = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while !isStopped {
            var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { Foundation.close(client) }
        var request: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator: [UInt8] = [13, 10, 13, 10]
        while !request.suffix(4).elementsEqual(terminator) {
            var pfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 2000) > 0 else { return }
            let count = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, 4096, 0) }
            if count <= 0 { return }
            request += buffer[0..<count]
        }
        guard let line = Self.requestLine(in: request) else { return }
        record(line)
        let route = response(for: line)
        if route?.silent == true {
            while !isStopped { usleep(20_000) }
            return
        }
        let bytes = encode(route)
        var offset = 0
        while offset < bytes.count {
            #if canImport(Darwin)
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            let sent = bytes.withUnsafeBytes { send(client, $0.baseAddress! + offset, bytes.count - offset, flags) }
            if sent <= 0 { return }
            offset += sent
        }
    }

    public func stop() {
        let already = lock.withLock { () -> Bool in
            defer { stopped = true }
            return stopped
        }
        guard !already else { return }
        usleep(120_000)  // let the accept loop notice before its descriptor goes away
        Foundation.close(listener)
        unlink(path)
    }

    #else

    private let pipeName: String

    public init(routes: [String: Route]) throws {
        self.routes = routes
        pipeName = #"\\.\pipe\sift-"# + UUID().uuidString.lowercased()
        endpoint = .namedPipe(path: pipeName)
        // Create the first instance now, so a client that connects right away finds the pipe.
        let first = try Self.makeInstance(pipeName)
        Thread.detachNewThread { [self] in acceptLoop(first) }
    }

    private static func makeInstance(_ name: String) throws -> HANDLE {
        let wide = Array(name.utf16) + [0]
        let handle = CreateNamedPipeW(
            wide,
            DWORD(PIPE_ACCESS_DUPLEX),
            DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_READMODE_BYTE) | DWORD(PIPE_WAIT),
            DWORD(PIPE_UNLIMITED_INSTANCES),
            65536, 65536, 0, nil
        )
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw DockerError.connectFailed("CreateNamedPipeW") }
        return handle
    }

    private func acceptLoop(_ firstInstance: HANDLE) {
        var instance: HANDLE? = firstInstance
        while !isStopped {
            guard let current = instance ?? (try? Self.makeInstance(pipeName)) else { return }
            instance = nil
            let connected = ConnectNamedPipe(current, nil).boolValue || GetLastError() == DWORD(ERROR_PIPE_CONNECTED)
            if !connected || isStopped {
                CloseHandle(current)
                continue
            }
            Thread.detachNewThread { [self] in serve(current) }
        }
    }

    private func serve(_ pipe: HANDLE) {
        defer {
            FlushFileBuffers(pipe)
            DisconnectNamedPipe(pipe)
            CloseHandle(pipe)
        }
        var request: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator: [UInt8] = [13, 10, 13, 10]
        while !request.suffix(4).elementsEqual(terminator) {
            var count: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes { ReadFile(pipe, $0.baseAddress, 4096, &count, nil) }
            if !ok.boolValue || count == 0 { return }
            request += buffer[0..<Int(count)]
        }
        guard let line = Self.requestLine(in: request) else { return }
        record(line)
        let route = response(for: line)
        if route?.silent == true {
            while !isStopped { Thread.sleep(forTimeInterval: 0.02) }
            return
        }
        var bytes = encode(route)
        var written: DWORD = 0
        _ = bytes.withUnsafeMutableBytes { WriteFile(pipe, $0.baseAddress, DWORD($0.count), &written, nil) }
    }

    public func stop() {
        let already = lock.withLock { () -> Bool in
            defer { stopped = true }
            return stopped
        }
        guard !already else { return }
        // Wake the accept loop, which is blocked in ConnectNamedPipe, with one throwaway client.
        let wide = Array(pipeName.utf16) + [0]
        let client = CreateFileW(wide, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), 0, nil)
        if client != INVALID_HANDLE_VALUE { CloseHandle(client) }
    }

    #endif
}

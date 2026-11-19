import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

/// A blocking, timeout-bound byte pipe to the daemon.
public protocol ByteStream: AnyObject {
    func write(_ bytes: [UInt8]) throws(DockerError)
    /// Up to `maxCount` bytes; an empty array means end of stream.
    func read(maxCount: Int) throws(DockerError) -> [UInt8]
    func close()
}

#if !os(Windows)

/// A unix-domain stream socket with send and receive timeouts.
public final class UnixSocketStream: ByteStream, @unchecked Sendable {
    private var descriptor: Int32

    public init(path: String, timeoutSeconds: Double) throws(DockerError) {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count + 1 <= capacity else { throw .socketPathTooLong(path) }
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw .connectFailed("socket: \(String(cString: strerror(errno)))") }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        var timeout = timeval(
            tv_sec: Int(timeoutSeconds),
            tv_usec: suseconds_t((timeoutSeconds - Double(Int(timeoutSeconds))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            _ = Foundation.close(fd)
            if code == EAGAIN || code == ETIMEDOUT { throw .timedOut }
            throw .connectFailed(String(cString: strerror(code)))
        }
        descriptor = fd
    }

    public func write(_ bytes: [UInt8]) throws(DockerError) {
        var offset = 0
        while offset < bytes.count {
            #if canImport(Darwin)
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            let sent = bytes.withUnsafeBytes { raw in
                send(descriptor, raw.baseAddress! + offset, bytes.count - offset, flags)
            }
            if sent < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { throw .timedOut }
                throw .connectFailed("write: \(String(cString: strerror(code)))")
            }
            offset += sent
        }
    }

    public func read(maxCount: Int) throws(DockerError) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: maxCount)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, maxCount, 0) }
            if count >= 0 { return Array(buffer[0..<count]) }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK { throw .timedOut }
            throw .connectFailed("read: \(String(cString: strerror(code)))")
        }
    }

    public func close() {
        if descriptor >= 0 {
            _ = Foundation.close(descriptor)
            descriptor = -1
        }
    }

    deinit { close() }
}

#endif

#if os(Windows)

/// A Windows named pipe opened for overlapped I/O, so each read and write can time out.
public final class NamedPipeStream: ByteStream, @unchecked Sendable {
    private var handle: HANDLE?
    private let timeoutMilliseconds: DWORD

    public init(path: String, timeoutSeconds: Double) throws(DockerError) {
        timeoutMilliseconds = DWORD(max(1, timeoutSeconds * 1000))
        let wide = Array(path.utf16) + [0]
        var opened: HANDLE?
        for _ in 0..<2 {
            let candidate = CreateFileW(
                wide,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                0,
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_OVERLAPPED),
                nil
            )
            if candidate != INVALID_HANDLE_VALUE {
                opened = candidate
                break
            }
            let code = GetLastError()
            if code == DWORD(ERROR_PIPE_BUSY) {
                if !WaitNamedPipeW(wide, timeoutMilliseconds) { throw .timedOut }
                continue
            }
            throw .connectFailed("CreateFileW failed (\(code))")
        }
        guard let opened else { throw .timedOut }
        handle = opened
    }

    public func write(_ bytes: [UInt8]) throws(DockerError) {
        guard let handle else { throw .connectFailed("pipe closed") }
        var offset = 0
        while offset < bytes.count {
            var chunk = Array(bytes[offset...])
            let done = try transfer(handle) { overlapped in
                var count: DWORD = 0
                let ok = chunk.withUnsafeMutableBytes {
                    WriteFile(handle, $0.baseAddress, DWORD($0.count), &count, overlapped)
                }
                return ok
            }
            guard let done else { throw .connectFailed("broken pipe") }
            offset += Int(done)
        }
    }

    public func read(maxCount: Int) throws(DockerError) -> [UInt8] {
        guard let handle else { return [] }
        var buffer = [UInt8](repeating: 0, count: maxCount)
        let done = try transfer(handle) { overlapped in
            var count: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes {
                ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, overlapped)
            }
            return ok
        }
        guard let done else { return [] }  // broken pipe: the daemon closed its end
        return Array(buffer[0..<Int(done)])
    }

    /// Starts an overlapped operation and waits for it, up to the timeout.
    private func transfer(
        _ handle: HANDLE,
        _ start: (UnsafeMutablePointer<OVERLAPPED>) -> Bool
    ) throws(DockerError) -> DWORD? {
        var overlapped = OVERLAPPED()
        guard let event = CreateEventW(nil, true, false, nil) else { throw .connectFailed("CreateEventW failed") }
        defer { CloseHandle(event) }
        overlapped.hEvent = event
        var transferred: DWORD = 0
        if !start(&overlapped) {
            let code = GetLastError()
            if code == DWORD(ERROR_BROKEN_PIPE) { return nil }
            guard code == DWORD(ERROR_IO_PENDING) else { throw .connectFailed("pipe i/o failed (\(code))") }
            if WaitForSingleObject(event, timeoutMilliseconds) == DWORD(WAIT_TIMEOUT) {
                CancelIoEx(handle, &overlapped)
                _ = GetOverlappedResult(handle, &overlapped, &transferred, true)
                throw .timedOut
            }
        }
        if !GetOverlappedResult(handle, &overlapped, &transferred, false) {
            let code = GetLastError()
            if code == DWORD(ERROR_BROKEN_PIPE) { return nil }
            throw .connectFailed("pipe i/o failed (\(code))")
        }
        return transferred
    }

    public func close() {
        if let handle {
            CloseHandle(handle)
            self.handle = nil
        }
    }

    deinit { close() }
}

#endif

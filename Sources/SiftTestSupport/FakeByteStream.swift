import Foundation
import SiftDocker

/// A scripted stream: reads hand out the given chunks, then end of stream.
public final class FakeByteStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [[UInt8]]
    private var _written: [UInt8] = []

    public init(chunks: [[UInt8]]) { self.chunks = chunks }

    public var written: [UInt8] { lock.withLock { _written } }

    public func write(_ bytes: [UInt8]) throws(DockerError) { lock.withLock { _written += bytes } }

    public func read(maxCount: Int) throws(DockerError) -> [UInt8] {
        lock.withLock {
            guard !chunks.isEmpty else { return [] }
            var chunk = chunks.removeFirst()
            if chunk.count > maxCount {
                chunks.insert(Array(chunk[maxCount...]), at: 0)
                chunk = Array(chunk[..<maxCount])
            }
            return chunk
        }
    }

    public func close() {}
}

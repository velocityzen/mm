import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#endif

/// The bytes still waiting on `descriptor`, read without blocking: up to the
/// end of the stream, or to the point where a read would wait. The
/// descriptor is left non-blocking.
public func unreadBytes(in descriptor: CInt) -> [UInt8] {
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    var collected: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return collected }
        collected.append(contentsOf: buffer[..<count])
    }
}

/// Marks that something finished, for a test to look at while it may not
/// have.
public final class CompletionFlag: Sendable {
    private let finished = Atomic<Bool>(false)

    public init() {}

    public func finish() {
        self.finished.store(true, ordering: .releasing)
    }

    public var isFinished: Bool {
        self.finished.load(ordering: .acquiring)
    }
}

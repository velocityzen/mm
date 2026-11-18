import NIOCore
import NIOPosix
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

/// A one-thread `NIOThreadPool` whose only thread is held: work submitted to
/// it stays queued, in order, until ``release()``. It stands in for a shared
/// pool so busy that a job waits before it starts.
public final class HeldThreadPool: Sendable {
    public let pool: NIOThreadPool
    private let released = Atomic<Bool>(false)

    init() {
        self.pool = NIOThreadPool(numberOfThreads: 1)
        self.pool.start()
        // The hold is the pool's first job, so everything after it queues.
        _ = self.pool.runIfActive(eventLoop: MultiThreadedEventLoopGroup.singleton.any()) {
            [self] in
            while !self.released.load(ordering: .acquiring) {
                usleep(50)
            }
        }
    }

    /// Lets the queued work run. Idempotent.
    public func release() {
        self.released.store(true, ordering: .releasing)
    }

    /// Whether ``release()`` has run.
    public var isReleased: Bool {
        self.released.load(ordering: .acquiring)
    }
}

/// Runs `body` with a held pool, then releases it and shuts it down once its
/// queued work has run, pass or fail.
public func withHeldThreadPool<T>(
    _ body: (HeldThreadPool) async throws -> T
) async throws -> T {
    let held = HeldThreadPool()
    let outcome: Result<T, any Error>
    do {
        outcome = .success(try await body(held))
    } catch {
        outcome = .failure(error)
    }
    held.release()
    try await held.pool.shutdownGracefully()
    return try outcome.get()
}

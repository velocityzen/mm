import MMExampleAPI
import MMSchema
import Synchronization

/// The follower registry behind `journal.follow`, factored out of the store
/// actor so `AsyncStream.Continuation.onTermination` — which is synchronous —
/// can unregister a follower directly, without spawning a task (the same
/// shape as the library's own client-state hub).
///
/// ## Two cleanup paths, both wired
///
/// - The follow handler unregisters on every normal exit (client STOP, call
///   end) by calling ``unfollow(_:from:)``.
/// - `onTermination` unregisters when the consuming side dies without
///   reaching that code — the handler task cancelled mid-iteration, or the
///   stream dropped — so a dead follower can never linger in the registry.
///
/// ## Locking discipline
///
/// `finish()` is never called while holding the lock: a termination handler
/// runs synchronously on the finishing thread and re-enters the hub via
/// `unfollow`, which would deadlock a held (non-recursive) `Mutex`. Removal
/// happens under the lock first; the continuation is finished after release,
/// and removal is idempotent, so the handler-path unfollow and the
/// termination-path unfollow can race safely — whichever runs second finds
/// the token already gone.
///
/// ## Why `AsyncStream` here is sound
///
/// Each follower gets a bounded `.bufferingNewest` stream. The bound matters
/// but the exact number does not: the *real* backpressure lives one hop
/// downstream, in the credit-gated `sink.send` of the follow handler, which
/// parks the reader when the client stops draining. This buffer only
/// cushions the window between a broadcast and the handler picking the event
/// up — sizing it to the stream credit window keeps a burst of appends from
/// being coalesced away before the handler drains it. A follower slower than
/// that loses the oldest cushioned events, by design ("changes from now on"
/// semantics), never blocks appenders.
final class FollowerHub: Sendable {
    private struct Registry {
        var followers: [EntityName: [UInt64: AsyncStream<ChangeEvent>.Continuation]] = [:]
        var nextToken: UInt64 = 0
    }

    private let registry = Mutex(Registry())

    /// Buffer depth for a follower's delivery stream, matched to the library's
    /// stream credit window (8) — see the type documentation.
    private static let followerBuffer = 8

    /// Registers a follower for `entity`: returns its token (for the
    /// handler-path ``unfollow(_:from:)``) and the element stream the follow
    /// handler drains.
    func follow(_ entity: EntityName) -> (token: UInt64, stream: AsyncStream<ChangeEvent>) {
        let (stream, continuation) = AsyncStream<ChangeEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.followerBuffer)
        )
        let token = self.registry.withLock { registry -> UInt64 in
            let token = registry.nextToken
            registry.nextToken &+= 1
            registry.followers[entity, default: [:]][token] = continuation
            return token
        }
        // The termination-path cleanup. `weak` breaks the retention loop
        // (hub → continuation → handler → hub) for streams that are never
        // finished; a hub that is already gone has no registry to clean.
        continuation.onTermination = { [weak self] _ in
            self?.unfollow(token, from: entity)
        }
        return (token, stream)
    }

    /// Unregisters a follower and finishes its stream. Idempotent — see the
    /// locking discipline in the type documentation.
    func unfollow(_ token: UInt64, from entity: EntityName) {
        let continuation = self.registry.withLock {
            registry -> AsyncStream<ChangeEvent>.Continuation? in
            guard let removed = registry.followers[entity]?.removeValue(forKey: token) else {
                return nil
            }
            if registry.followers[entity]?.isEmpty == true {
                registry.followers[entity] = nil
            }
            return removed
        }
        // Outside the lock: finish() runs onTermination synchronously, which
        // re-enters unfollow; that second entry finds the token gone.
        continuation?.finish()
    }

    /// Fans a change out to every follower of the changed journal. The
    /// continuations are copied out under the lock and yielded outside it;
    /// a follower finished between the copy and its yield ignores the yield.
    func broadcast(_ event: ChangeEvent, to entity: EntityName) {
        let continuations = self.registry.withLock { registry in
            registry.followers[entity].map { Array($0.values) } ?? []
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }
}

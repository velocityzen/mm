import MMSchema
import NIOCore
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

/// A handle to a running ``MMService``: the resource its bracket body
/// receives, alive from the moment every endpoint listens until the drain
/// begins.
///
/// ```swift
/// let service = MMService {
///     Configuration(endpoints: [])
///     ACLProvider(provider)
///     SocketInbox()
///     For(Worker.self) { WorkerHandlers() }
/// }
/// await service { server in
///     // While the server runs:
///     let identity = PeerIdentity(uid: getuid(), gid: getgid(), supplementaryGroups: [], pid: child, label: "worker-1")
///     _ = await server.adopt(descriptor: parentEnd, peer: identity)
///     ...
/// }
/// ```
public struct MMServiceHandle: Sendable {
    /// The bound addresses, one per configured endpoint and in their order —
    /// the port an ephemeral `.tcp(host:port: 0)` endpoint was given, say.
    public let addresses: [SocketAddress]

    /// Where adopted sockets go; `nil` when the service declares no
    /// ``SocketInbox()``.
    let adoptions: SocketAdoptions?

    /// Serves `descriptor`, a connected stream socket the host made itself —
    /// the parent end of a `socketpair(2)` it handed to a child, say — as a
    /// connection from `peer`: the same router, hello exchange, connection
    /// cap and graceful drain as an accepted connection.
    ///
    /// The kernel attests nothing about a socket the host made, so `peer` is
    /// the identity the connection is authorized with; name it with
    /// ``PeerIdentity/label`` to tell adopted peers apart. ACL checks still
    /// go by its uid and gid.
    ///
    /// The server owns `descriptor` from this call on, whatever the outcome:
    /// it closes it with the connection, and a failed adoption closes it
    /// before returning. Never close it yourself.
    ///
    /// - Returns: `.success` once the server has taken the connection (it may
    ///   still close it at once, at the connection cap), or `.failure(.io)`
    ///   when the service declares no ``SocketInbox()`` or is shutting down.
    public func adopt(descriptor: CInt, peer: PeerIdentity) async -> Result<Void, MMServiceError> {
        guard let adoptions else {
            _ = close(descriptor)
            return .failure(.io(description: "the service declares no SocketInbox()"))
        }
        return await adoptions.adopt(descriptor: descriptor, peer: peer)
    }
}

/// The queue between ``MMServiceHandle/adopt(descriptor:peer:)`` and the
/// server's adoption loop. One per run: created serving, finished when the
/// accept loops stop, after which every adoption fails.
final class SocketAdoptions: Sendable {
    /// One pending adoption: the descriptor, its identity, and the adopter
    /// waiting to learn whether the server took the connection.
    struct Adoption: Sendable {
        let descriptor: CInt
        let peer: PeerIdentity
        let reply: CheckedContinuation<Result<Void, MMServiceError>, Never>
    }

    private enum State {
        /// Adoptions queue until the loop takes them.
        case serving(queue: [Adoption], waiter: CheckedContinuation<Adoption?, Never>?)
        /// The server stopped; adoptions fail at once.
        case finished
    }

    private let state = Mutex(State.serving(queue: [], waiter: nil))

    func adopt(descriptor: CInt, peer: PeerIdentity) async -> Result<Void, MMServiceError> {
        await withCheckedContinuation { reply in
            let adoption = Adoption(descriptor: descriptor, peer: peer, reply: reply)
            let handoff = self.state.withLock { state -> CheckedContinuation<Adoption?, Never>?? in
                switch state {
                    case .finished:
                        return .none
                    case .serving(let queue, let waiter?):
                        // The loop only waits on an empty queue.
                        state = .serving(queue: queue, waiter: nil)
                        return .some(waiter)
                    case .serving(var queue, nil):
                        queue.append(adoption)
                        state = .serving(queue: queue, waiter: nil)
                        return .some(nil)
                }
            }
            switch handoff {
                case .none:
                    Self.reject(adoption, "the server is not running")
                case .some(let waiter?):
                    waiter.resume(returning: adoption)
                case .some(nil):
                    break
            }
        }
    }

    /// Fails an adoption the server never took: closes the descriptor the
    /// server owns, then tells the adopter.
    static func reject(_ adoption: Adoption, _ reason: String) {
        _ = close(adoption.descriptor)
        adoption.reply.resume(returning: .failure(.io(description: reason)))
    }

    // MARK: - Server side

    /// The next adoption, or `nil` once ``finish()`` ran or the calling task
    /// is cancelled.
    func next() async -> Adoption? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                let ready = self.state.withLock { state -> Adoption?? in
                    guard case .serving(var queue, let existing) = state else {
                        return .some(nil)
                    }
                    precondition(existing == nil, "SocketAdoptions: two loops waiting")
                    if !queue.isEmpty {
                        let first = queue.removeFirst()
                        state = .serving(queue: queue, waiter: nil)
                        return .some(first)
                    }
                    // Checked under the lock: a cancellation that lands after
                    // this finds the stored waiter in the handler below.
                    if Task.isCancelled {
                        return .some(nil)
                    }
                    state = .serving(queue: queue, waiter: waiter)
                    return .none
                }
                if case .some(let adoption) = ready {
                    waiter.resume(returning: adoption)
                }
            }
        } onCancel: {
            let waiter = self.state.withLock { state -> CheckedContinuation<Adoption?, Never>? in
                guard case .serving(let queue, let waiter?) = state else { return nil }
                state = .serving(queue: queue, waiter: nil)
                return waiter
            }
            waiter?.resume(returning: nil)
        }
    }

    /// Stops serving for good: a waiting ``next()`` returns `nil`, and every
    /// adoption still queued, or made later, fails.
    func finish() {
        let (queue, waiter) = self.state.withLock {
            state -> ([Adoption], CheckedContinuation<Adoption?, Never>?) in
            guard case .serving(let queue, let waiter) = state else { return ([], nil) }
            state = .finished
            return (queue, waiter)
        }
        waiter?.resume(returning: nil)
        for adoption in queue {
            Self.reject(adoption, "the server stopped before taking the connection")
        }
    }
}

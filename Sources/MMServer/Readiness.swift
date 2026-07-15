import NIOConcurrencyHelpers
import NIOCore
import ServiceLifecycle

/// A one-shot, multi-waiter readiness signal — the startup-ordering primitive
/// swift-service-lifecycle deliberately leaves out of its core.
///
/// `ServiceGroup` starts every service concurrently and only orders shutdown
/// (reverse array order). Dependencies between *startups* therefore compose on
/// top: a service that must not start before another is ready waits on one of
/// these, and the provider signals it at its own ready moment. Together with
/// reverse-order shutdown this yields full dependency semantics — B starts
/// after A is ready, B stops before A:
///
/// ```swift
/// let rpcReady = ServiceReadiness()
///
/// let group = ServiceGroup(configuration: .init(
///     services: [
///         .init(service: MMService {
///             Configuration(endpoint: .unix(path: sock))
///             ACLProvider(provider)
///             Ready(rpcReady)                    // signals at bind+listen
///             For(Journal.self) { JournalHandlers(store: store) }
///         }),
///         .init(service: GatedService(after: rpcReady) {
///             AnnounceService(path: sock)        // starts only once bound
///         }),
///     ],
///     gracefulShutdownSignals: [.sigterm],
///     logger: logger
/// ))
/// ```
///
/// ## Single-resume audit
///
/// Waiter continuations live only in `State.waiters` and every transition
/// that produces one removes it in the same locked mutation: `signalReady`
/// (drains all), the cancellation handler (removes its own). Cancellation
/// racing registration is covered by the `cancelledBeforeRegistration`
/// tombstones, checked under the same lock before parking. The lock is never
/// held across a suspension point; continuations resume outside it.
public final class ServiceReadiness: Sendable {
    private struct State {
        var ready = false
        var nextID: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        /// IDs whose cancellation handler ran before the waiter registered.
        var cancelledBeforeRegistration: Set<UInt64> = []
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    /// Whether the signal has fired. A snapshot — prefer
    /// ``waitUntilReady()`` for coordination.
    public var isReady: Bool {
        self.state.withLockedValue { $0.ready }
    }

    /// Marks the resource ready and releases every current and future waiter.
    /// Idempotent; the first call wins.
    public func signalReady() {
        let waiters = self.state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            guard !state.ready else { return [] }
            state.ready = true
            let waiters = Array(state.waiters.values)
            state.waiters = [:]
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends until ``signalReady()`` has been called. Returns immediately
    /// when already ready. Cancellation-aware: a cancelled waiter throws
    /// `CancellationError` instead of parking forever.
    public func waitUntilReady() async throws {
        let id = self.state.withLockedValue { state -> UInt64 in
            state.nextID &+= 1
            return state.nextID
        }
        let parked: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enum Immediate {
                    case ready
                    case cancelled
                    case registered
                }
                let immediate = self.state.withLockedValue { state -> Immediate in
                    if state.cancelledBeforeRegistration.remove(id) != nil {
                        return .cancelled
                    }
                    if state.ready {
                        return .ready
                    }
                    state.waiters[id] = continuation
                    return .registered
                }
                switch immediate {
                case .ready, .cancelled:
                    continuation.resume()
                case .registered:
                    break  // signalReady() or onCancel resumes it.
                }
            }
            return true
        } onCancel: {
            let waiter = self.state.withLockedValue {
                state -> CheckedContinuation<Void, Never>? in
                if let parked = state.waiters.removeValue(forKey: id) {
                    return parked
                }
                state.cancelledBeforeRegistration.insert(id)
                return nil
            }
            waiter?.resume()
        }
        _ = parked
        try Task.checkCancellation()
    }
}

/// Wraps any `Service` so its `run()` begins only after the given readiness
/// signals have all fired — the start-side half of dependency ordering (the
/// stop side is `ServiceGroup`'s reverse-order shutdown, which already stops
/// dependents first).
///
/// While gated, the wrapper stays a well-behaved group member: graceful
/// shutdown releases the wait and returns cleanly (the wrapped service never
/// starts — there is nothing to drain), and task cancellation propagates as
/// usual. The wrapped service's own shutdown behavior is untouched once
/// running.
public struct GatedService<Wrapped: Service>: Service {
    private let readiness: [ServiceReadiness]
    private let wrapped: Wrapped

    public init(after readiness: ServiceReadiness..., run wrapped: Wrapped) {
        self.readiness = readiness
        self.wrapped = wrapped
    }

    public init(after readiness: [ServiceReadiness], run wrapped: Wrapped) {
        self.readiness = readiness
        self.wrapped = wrapped
    }

    /// Builder-flavored form: `GatedService(after: rpcReady) { AnnounceService() }`.
    public init(after readiness: ServiceReadiness..., run wrapped: () -> Wrapped) {
        self.readiness = readiness
        self.wrapped = wrapped()
    }

    public func run() async throws {
        do {
            // cancelWhenGracefulShutdown cancels the WAIT (a child task) on
            // shutdown; our own task stays uncancelled, which is how the two
            // exits are told apart below.
            try await cancelWhenGracefulShutdown {
                for signal in self.readiness {
                    try await signal.waitUntilReady()
                }
            }
        } catch is CancellationError {
            if Task.isCancelled {
                throw CancellationError()  // real cancellation: propagate
            }
            return  // graceful shutdown while gated: clean exit, nothing ran
        }
        try await self.wrapped.run()
    }
}

/// Builder element: signals the given readiness once the server's endpoint is
/// bound and listening — the declarative form of wiring ``OnBind(_:)`` to a
/// ``ServiceReadiness``. May appear multiple times (one per dependent) and
/// composes with an explicit `OnBind`.
public func Ready(_ readiness: ServiceReadiness) -> ServerPart {
    ServerPart(kind: .ready(readiness))
}

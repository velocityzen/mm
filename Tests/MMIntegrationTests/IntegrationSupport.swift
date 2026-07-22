import Logging
import MMClient
import MMSchema
import MMServer
import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ServiceLifecycle

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Deterministic signalling (no sleeps)
// Deadlines, temp sockets, the ServiceGroup and client run-loop choreography,
// and the echo/envelope wire fixtures come from MMTestSupport.

/// A one-shot, multi-waiter signal carrying a value. Fire-side is synchronous
/// (callable from `onBind` and handler closures); wait-side suspends on a
/// continuation — never polls, never sleeps — and **observes task
/// cancellation**: a cancelled waiter throws `CancellationError` instead of
/// parking forever. That property is load-bearing for the harness's "never
/// hangs" guarantee: if a gated test fails before opening its gate, the
/// 60-second harness deadline cancels the server task tree, and the handler
/// parked on the gate must unblock for the drain to finish. A bare
/// continuation would defeat every deadline in the file.
final class Signal<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var nextID: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Value?, Never>] = [:]
        /// IDs whose cancellation handler ran before the waiter registered
        /// its continuation (cancellation can race registration).
        var cancelledBeforeRegistration: Set<UInt64> = []
    }

    private let state = NIOLockedValueBox(State())

    /// Outcome of the registration race inside `wait()`. Hoisted to class scope
    /// because local types cannot be declared in closures in a generic context.
    private enum Immediate {
        case fired(Value)
        case cancelled
        case registered
    }

    func fire(_ value: Value) {
        let waiters = self.state.withLockedValue { state -> [CheckedContinuation<Value?, Never>] in
            guard state.value == nil else { return [] }  // one-shot: first fire wins
            state.value = value
            let waiters = Array(state.waiters.values)
            state.waiters = [:]
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    func wait() async throws -> Value {
        let id = self.state.withLockedValue { state -> UInt64 in
            state.nextID &+= 1
            return state.nextID
        }
        let value: Value? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                let immediate = self.state.withLockedValue { state -> Immediate in
                    if state.cancelledBeforeRegistration.remove(id) != nil {
                        return .cancelled
                    }
                    if let value = state.value {
                        return .fired(value)
                    }
                    state.waiters[id] = continuation
                    return .registered
                }
                switch immediate {
                    case .fired(let value):
                        continuation.resume(returning: value)
                    case .cancelled:
                        continuation.resume(returning: nil)
                    case .registered:
                        break  // fire(_:) or onCancel resumes it.
                }
            }
        } onCancel: {
            let continuation = self.state.withLockedValue {
                state -> CheckedContinuation<Value?, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) {
                    return waiter
                }
                state.cancelledBeforeRegistration.insert(id)
                return nil
            }
            continuation?.resume(returning: nil)
        }
        guard let value else { throw CancellationError() }
        return value
    }
}

// MARK: - Dead socket files

/// Creates a *dead* socket file: bound once by a socket that is closed without
/// unlinking, exactly what a crashed server leaves behind.
func createDeadSocketFile(path: String) throws {
    #if canImport(Glibc)
    // Glibc imports SOCK_STREAM as the __socket_type enum, not CInt.
    let socketType = CInt(bitPattern: SOCK_STREAM.rawValue)
    #else
    let socketType = SOCK_STREAM
    #endif
    let descriptor = socket(AF_UNIX, socketType, 0)
    guard descriptor >= 0 else {
        throw MMServiceError.io(description: "socket failed, errno \(errno)")
    }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            bind(descriptor, rebound, length)
        }
    }
    guard bound == 0 else {
        throw MMServiceError.io(description: "bind failed, errno \(errno)")
    }
}

/// `stat(2)` the socket path; nil when the path does not exist.
func statMode(path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode
}

// MARK: - Wire fixtures (request/response types and methods)
// EchoRequest/EchoResponse come from MMTestSupport (shared with MMServerTests).

struct TargetRequest: Codable, Hashable, Sendable {
    var entity: EntityName

    enum CodingKeys: Int, CodingKey {
        case entity = 0
    }
}

struct VersionResponse: Codable, Hashable, Sendable {
    var version: UInt8

    enum CodingKeys: Int, CodingKey {
        case version = 0
    }
}

struct PingResponse: Codable, Hashable, Sendable {
    var ok: Bool

    enum CodingKeys: Int, CodingKey {
        case ok = 0
    }
}

enum TestMethods {
    static let echo = Method<EchoRequest, EchoResponse>(name: "echo.run", access: .write)
    static let version = Method<TargetRequest, VersionResponse>(name: "meta.version", access: .read)
    static let slow = Method<TargetRequest, EchoResponse>(name: "slow.wait", access: .read)
    /// Parks every handler on ``TestServer/burstGate`` after firing
    /// ``TestServer/burstStarted`` once ``TestServer/burstConcurrency`` handlers
    /// are concurrently in flight — the fixture for the writer-funnel-under-
    /// concurrency and multiplexing proofs.
    static let burst = Method<EchoRequest, EchoResponse>(name: "burst.wait", access: .read)
    static let ping = Method<TargetRequest, PingResponse>(name: "pub.ping", access: .execute)
    static let hidden = Method<TargetRequest, PingResponse>(name: "hidden.run", access: .read)
    /// Always answers with a fixed application error (code >= 64, payload
    /// intact) — the fixture for handler-returned domain failures.
    static let fail = Method<TargetRequest, PingResponse>(name: "fail.run", access: .read)
    /// Registered nowhere on the server: calling it must yield `unknownMethod`.
    static let unregistered = Method<TargetRequest, PingResponse>(
        name: "nope.method", access: .read)
    /// Registered with `Accepts("box", "box.*")`: accepts only `box` and its
    /// descendants, regardless of what the ACL admits. Its own `scoped`
    /// prefix entity has no ACL record, so these two stay out of discovery
    /// listings.
    static let scopedEcho = Method<EchoRequest, EchoResponse>(
        name: "scoped.echo", access: .read)
    /// Registered with `Accepts("box.item")`: accepts exactly that entity —
    /// not `box`, not siblings, not children.
    static let scopedExact = Method<EchoRequest, EchoResponse>(
        name: "scoped.exact", access: .read)
    /// Echoes a payload of all three calendar/clock kinds — the MessagePack
    /// round-trip proof for `.date`/`.datetime`/`.timestamp` wire values.
    /// Under the discovery-invisible `scoped` prefix like its siblings.
    static let when = Method<WhenPayload, WhenPayload>(
        name: "scoped.when", access: .read)

    // MARK: - Streaming fixtures (S3)

    /// follow-style server stream: streams `count` items (values `0..<count`)
    /// then returns a summary. Access `.read` on the target entity (`box`
    /// grants r/w/x to the owning peer). Ungated — for the happy path and the
    /// stall-at-zero-credit anti-head-of-line proof.
    static let follow = ServerStreamMethod<FollowRequest, StreamItem, StreamSummary>(
        name: "box.follow", access: .read
    )
    /// A gated follow: fires `followStarted`, then parks on `followGate`
    /// between items so tests control pacing (hold it mid-stream). Observes
    /// task cancellation cooperatively (fires `followCancelled`). Used for
    /// CANCEL, the concurrency cap, and graceful-shutdown-with-a-live-stream.
    static let followGated = ServerStreamMethod<FollowRequest, StreamItem, StreamSummary>(
        name: "box.followGated", access: .read
    )
    /// A follow that records a client STOP (`.peerStopped`) via `followStopped`,
    /// then ends gracefully with a nil-error terminal. `count` is large so the
    /// client can STOP mid-stream.
    static let followStoppable = ServerStreamMethod<FollowRequest, StreamItem, StreamSummary>(
        name: "box.followStoppable", access: .read
    )
    /// A follow that streams all `count` items, fires `followStarted`, then
    /// parks on `followGate` *before returning its terminal* — so a test can
    /// observe the data direction finished (all items delivered) while the
    /// terminal still lags, then release the gate to get it. The nearest the
    /// S3 server offers to "response END, then a lagging terminal".
    static let followEndPark = ServerStreamMethod<FollowRequest, StreamItem, StreamSummary>(
        name: "box.followEndPark", access: .read
    )
    /// A follow whose handler never sends: it parks on `sink.stopRequested()`
    /// and returns its terminal only when the client STOPs — the fixture for
    /// observing STOP on a quiet source without a wake-up send.
    static let followQuiet = ServerStreamMethod<FollowRequest, StreamItem, StreamSummary>(
        name: "box.followQuiet", access: .read
    )
    /// A follow that streams `count` items in order and then returns a fixed
    /// **application error** terminal (``applicationErrorObject``, code >= 64,
    /// payload intact) — the S4 client fixture for an error terminal arriving
    /// mid-stream: the element sequence finishes, then the terminal is the
    /// mapped `.failure`, and the connection lives on.
    static let followFailing = ServerStreamMethod<FollowRequest, StreamItem, StreamSummary>(
        name: "box.followFail", access: .read
    )

    /// import-style client stream: consumes elements, returns the count
    /// consumed. Access `.write`.
    static let importItems = ClientStreamMethod<ImportRequest, StreamItem, StreamSummary>(
        name: "box.import", access: .write
    )
    /// An import variant that calls `elements.stop()` after `stopAfter`
    /// elements (server-initiated STOP), then keeps consuming to its terminal.
    static let importStopping = ClientStreamMethod<ImportRequest, StreamItem, StreamSummary>(
        name: "box.importStop", access: .write
    )
    /// An import variant that parks on `followGate` **before** its first
    /// `for await` and never consumes an element until released — so a test can
    /// drive a deterministic credit overrun: with no consumption there is no
    /// `produceMore` grant, so a 9th unprompted item is provably an overrun
    /// regardless of scheduling.
    static let importGated = ClientStreamMethod<ImportRequest, StreamItem, StreamSummary>(
        name: "box.importGated", access: .write
    )

    /// bidirectional echo: echoes each inbound element as an outbound item, ends when
    /// the request stream ends, terminal carries the echoed count. Access
    /// `.write`.
    static let pipe = BidirectionalStreamMethod<
        ImportRequest, StreamItem, StreamItem, StreamSummary
    >(
        name: "box.pipe", access: .write
    )
}

// MARK: - Streaming payload types

/// The opening request for a follow-style server stream.
struct FollowRequest: Codable, Hashable, Sendable {
    var entity: EntityName
    /// How many items to stream (values `0..<count`).
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case entity = 0
        case count = 1
    }
}

/// The opening request for an import/pipe client or bidirectional stream.
struct ImportRequest: Codable, Hashable, Sendable {
    var entity: EntityName
    /// For the stopping variant: stop after this many elements (0 = never).
    var stopAfter: Int

    enum CodingKeys: Int, CodingKey {
        case entity = 0
        case stopAfter = 1
    }
}

/// A payload carrying all three calendar/clock kinds (plus an optional), for
/// the wire round-trip proof.
struct WhenPayload: Codable, Hashable, Sendable {
    var day: MMDate
    var slot: MMDateTime
    var created: MMTimestamp
    var remind: MMTimestamp?

    enum CodingKeys: Int, CodingKey {
        case day = 0
        case slot = 1
        case created = 2
        case remind = 3
    }
}

/// One stream element (request or response direction).
struct StreamItem: Codable, Hashable, Sendable {
    var value: Int

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }
}

/// A stream's terminal summary: how many items the handler produced/consumed.
struct StreamSummary: Codable, Hashable, Sendable {
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case count = 0
    }
}

/// The exact `MMError` `fail.run` returns: application code (>= 64) with a
/// MessagePack payload that must reach the caller verbatim.
func applicationErrorObject() -> MMError {
    MMError(
        code: 64, message: "application failure", payload: encodedParams(EchoResponse(value: 13)))
}

func entity(_ raw: String) -> EntityName {
    try! EntityName.parse(raw).get()
}

/// The ACL world every integration server runs with. The test process itself
/// is the unix peer, so fixtures are built around its real uid/gid:
///
/// - `box` (x for owner) / `box.item` (0o700): the grant path.
/// - `box.locked` (owner = us, mode 0o077): the owner *class* matches and its
///   bits deny — first-matching-class-wins proves denial for the very process
///   that owns the entity, even though group/other bits would grant.
/// - `sealed` (0o600, no x) over `sealed.item` (0o777): traversal denial.
/// - `echo` prefix (0o700, ours): `server.schema` shows `echo.run` to us, not to
///   anonymous peers.
/// - `hidden` prefix (owned by a different uid, 0o700): invisible to us.
/// - `pub` prefix and `pub.thing` (foreign-owned, mode 0o001): other-class x,
///   visible/callable by everyone including anonymous TCP peers.
func fixtureACLs() -> [EntityName: EntityACL] {
    let uid = getuid()
    let gid = getgid()
    let foreignUid = uid &+ 1
    let foreignGid = gid &+ 1
    return [
        entity("box"): EntityACL(owner: uid, group: gid, mode: 0o700),
        entity("box.item"): EntityACL(owner: uid, group: gid, mode: 0o700),
        entity("box.locked"): EntityACL(owner: uid, group: gid, mode: 0o077),
        entity("sealed"): EntityACL(owner: uid, group: gid, mode: 0o600),
        entity("sealed.item"): EntityACL(owner: uid, group: gid, mode: 0o777),
        entity("echo"): EntityACL(owner: uid, group: gid, mode: 0o700),
        entity("hidden"): EntityACL(owner: foreignUid, group: foreignGid, mode: 0o700),
        entity("pub"): EntityACL(owner: foreignUid, group: foreignGid, mode: 0o001),
        entity("pub.thing"): EntityACL(owner: foreignUid, group: foreignGid, mode: 0o001),
    ]
}

// MARK: - Server harness

struct TestServer {
    /// How many `burst.wait` handlers must be parked concurrently before
    /// ``burstStarted`` fires. Below the default per-connection in-flight cap
    /// (16), so all of them are admitted and truly concurrent.
    static let burstConcurrency = 8

    var service: MMService
    var bound: Signal<SocketAddress>
    /// Fired by `slow.wait` when its handler starts running.
    var slowStarted: Signal<Void>
    /// Opened by tests to let `slow.wait` complete.
    var slowGate: Signal<Void>
    /// Fired by `burst.wait` when ``burstConcurrency`` handlers have each
    /// parked on ``burstGate``.
    var burstStarted: Signal<Void>
    /// Opened by tests to release every parked `burst.wait` handler at once.
    var burstGate: Signal<Void>

    // MARK: - Streaming signals (S3)

    /// Fired by every `followGated` handler as it begins, carrying the current
    /// count of gated handlers that have started (so a test can wait for the
    /// Nth concurrent open — the cap/anti-HOL rows).
    var followStarted: Signal<Void>
    /// Fired once when `gatedFollowStartedCount` first reaches
    /// ``gatedFollowQuorum`` handlers parked concurrently.
    var followQuorumReached: Signal<Void>
    /// Opened by tests to release every parked `followGated` handler at once
    /// (one-shot broadcast).
    var followGate: Signal<Void>
    /// Fired by `followStoppable` when its handler observes a client STOP as
    /// `.peerStopped`.
    var followStopped: Signal<Void>
    /// Fired by `importStop` right after it has issued its server-initiated STOP
    /// (`elements.stop()` returned) — so a client test can bound the moment the
    /// kind-5 STOP is on the wire and deterministically observe the resulting
    /// `.peerStopped` on its next sends.
    var importStopSent: Signal<Void>
    /// Fired by `followGated` when its handler observes task cancellation.
    var followCancelled: Signal<Void>
    /// How many concurrent gated follows the quorum signal waits for. Set by
    /// the concurrency rows; the default (1) suits the single-stream rows.
    var gatedFollowQuorum: Int
}

func makeTestServer(
    configuration: MMServerConfiguration,
    gatedFollowQuorum: Int = 1
) -> TestServer {
    let bound = Signal<SocketAddress>()
    let slowStarted = Signal<Void>()
    let slowGate = Signal<Void>()
    let burstStarted = Signal<Void>()
    let burstGate = Signal<Void>()
    let burstStartedCount = NIOLockedValueBox(0)
    let followStarted = Signal<Void>()
    let followQuorumReached = Signal<Void>()
    let followGate = Signal<Void>()
    let followStopped = Signal<Void>()
    let importStopSent = Signal<Void>()
    let followCancelled = Signal<Void>()
    let gatedFollowStartedCount = NIOLockedValueBox(0)
    // Quiet by default; flip to .trace when debugging a failing test.
    var debugLogger = Logger(label: "mm.test.server")
    debugLogger.logLevel = .warning
    let service = MMService(
        configuration: configuration,
        aclProvider: InMemoryACLProvider(fixtureACLs()),
        logger: debugLogger,
        onBind: { address in bound.fire(address) }
    ) {
        Handle(TestMethods.echo) { request, _ in
            .success(EchoResponse(value: request.value))
        }
        Handle(TestMethods.scopedEcho, Accepts("box", "box.*")) { request, _ in
            .success(EchoResponse(value: request.value))
        }
        Handle(TestMethods.scopedExact, Accepts("box.item")) { request, _ in
            .success(EchoResponse(value: request.value))
        }
        Handle(TestMethods.when, Accepts("box.item")) { request, _ in
            .success(request)
        }
        Handle(TestMethods.version) { _, context in
            .success(VersionResponse(version: context.protocolVersion))
        }
        Handle(TestMethods.slow) { _, _ in
            slowStarted.fire(())
            // Cancellation (harness deadline / group teardown) unparks the
            // handler; answering afterwards is harmless — the channel is gone.
            try? await slowGate.wait()
            return .success(EchoResponse(value: 99))
        }
        Handle(TestMethods.burst) { request, _ in
            // Exercises the ConnectionWriter funnel under real concurrency:
            // every handler parks so all requests are in flight at once, then
            // the gate releases them to race their responses through the funnel.
            let started = burstStartedCount.withLockedValue { count -> Int in
                count += 1
                return count
            }
            if started == TestServer.burstConcurrency {
                burstStarted.fire(())
            }
            // Cancellation (harness deadline / group teardown) unparks the
            // handler; answering afterwards is harmless — the channel is gone.
            try? await burstGate.wait()
            return .success(EchoResponse(value: request.value))
        }
        Handle(TestMethods.ping) { _, _ in
            .success(PingResponse(ok: true))
        }
        Handle(TestMethods.hidden) { _, _ in
            .success(PingResponse(ok: true))
        }
        Handle(TestMethods.fail) { _, _ in
            .failure(applicationErrorObject())
        }

        // MARK: - Streaming handlers (S3)

        Handle(TestMethods.follow) { request, sink, _ in
            // Ungated: push `count` items in order, then return the summary.
            // A send that reports `.callEnded` (client STOP-to-END, CANCEL,
            // death) stops the loop early; the terminal is discarded then.
            var produced = 0
            for value in 0..<request.count {
                switch await sink.send(StreamItem(value: value)) {
                    case .sent:
                        produced += 1
                    case .peerStopped, .callEnded:
                        return .success(StreamSummary(count: produced))
                }
            }
            return .success(StreamSummary(count: produced))
        }

        Handle(TestMethods.followGated) { request, sink, _ in
            // Signal start (and the quorum edge), then stream `count` items,
            // parking on the shared gate before EACH item so a test can hold
            // the stream mid-flight. Task cancellation (CANCEL / shutdown /
            // deadline) unblocks the gate wait and is reported once.
            let started = gatedFollowStartedCount.withLockedValue { count -> Int in
                count += 1
                return count
            }
            followStarted.fire(())
            if started == gatedFollowQuorum {
                followQuorumReached.fire(())
            }
            var produced = 0
            for value in 0..<request.count {
                // Park until released; a cancelled wait throws and lands us in
                // the cancellation branch below.
                do {
                    try await followGate.wait()
                } catch {
                    followCancelled.fire(())
                    return .success(StreamSummary(count: produced))
                }
                if Task.isCancelled {
                    followCancelled.fire(())
                    return .success(StreamSummary(count: produced))
                }
                switch await sink.send(StreamItem(value: value)) {
                    case .sent:
                        produced += 1
                    case .peerStopped, .callEnded:
                        return .success(StreamSummary(count: produced))
                }
            }
            return .success(StreamSummary(count: produced))
        }

        Handle(TestMethods.followStoppable) { request, sink, _ in
            // Stream until the client STOPs (`.peerStopped`) or the count is
            // exhausted. On STOP: record it and end gracefully.
            var produced = 0
            for value in 0..<request.count {
                switch await sink.send(StreamItem(value: value)) {
                    case .sent:
                        produced += 1
                    case .peerStopped:
                        followStopped.fire(())
                        return .success(StreamSummary(count: produced))
                    case .callEnded:
                        return .success(StreamSummary(count: produced))
                }
            }
            return .success(StreamSummary(count: produced))
        }

        Handle(TestMethods.followQuiet) { _, sink, _ in
            // A relay over a source that never produces: no send ever
            // happens, so the client's STOP can only be observed through
            // `stopRequested()` — the quiet-source pattern the
            // wake-on-next-send outcome cannot serve.
            await sink.stopRequested()
            return .success(StreamSummary(count: 0))
        }

        Handle(TestMethods.followEndPark) { request, sink, _ in
            // Deliver every item (the data direction finishes), then park
            // before returning so the terminal lags until the gate opens.
            var produced = 0
            for value in 0..<request.count {
                switch await sink.send(StreamItem(value: value)) {
                    case .sent:
                        produced += 1
                    case .peerStopped, .callEnded:
                        return .success(StreamSummary(count: produced))
                }
            }
            followStarted.fire(())
            try? await followGate.wait()
            return .success(StreamSummary(count: produced))
        }

        Handle(TestMethods.followFailing) { request, sink, _ in
            // Stream every item in order, then fail the terminal with a fixed
            // application error — the client sees the elements first, then the
            // mapped `.failure`.
            for value in 0..<request.count {
                switch await sink.send(StreamItem(value: value)) {
                    case .sent:
                        continue
                    case .peerStopped, .callEnded:
                        return .failure(applicationErrorObject())
                }
            }
            return .failure(applicationErrorObject())
        }

        Handle(TestMethods.importItems) { _, elements, _ in
            // Consume every request element; the sequence's normal end is the
            // client's END. Answer with the count consumed.
            var consumed = 0
            for await _ in elements { consumed += 1 }
            return .success(StreamSummary(count: consumed))
        }

        Handle(TestMethods.importGated) { _, elements, _ in
            // Park before consuming ANYTHING so no produceMore grant can fire
            // while a test fills (and overruns) the initial window. Cancellation
            // (harness deadline / shutdown) unblocks the gate; consuming
            // afterwards is harmless. After release, drain to the terminal.
            followStarted.fire(())
            try? await followGate.wait()
            var consumed = 0
            for await _ in elements { consumed += 1 }
            return .success(StreamSummary(count: consumed))
        }

        Handle(TestMethods.importStopping) { request, elements, _ in
            // Consume elements; after `stopAfter` of them, ask the client to
            // stop (server-initiated STOP, advisory). Keep consuming whatever
            // is still in flight until the sequence ends, then answer with the
            // total consumed.
            var consumed = 0
            for await _ in elements {
                consumed += 1
                if consumed == request.stopAfter {
                    await elements.stop()
                    // The kind-5 STOP is now on the wire: let a client test bound
                    // the moment so it can deterministically observe .peerStopped.
                    importStopSent.fire(())
                }
            }
            return .success(StreamSummary(count: consumed))
        }

        Handle(TestMethods.pipe) { _, elements, sink, _ in
            // Echo each inbound element as an outbound item; end when the
            // request stream ends. Terminal carries the echoed count.
            var echoed = 0
            for await element in elements {
                switch await sink.send(element) {
                    case .sent:
                        echoed += 1
                    case .peerStopped, .callEnded:
                        break
                }
            }
            return .success(StreamSummary(count: echoed))
        }
    }
    return TestServer(
        service: service,
        bound: bound,
        slowStarted: slowStarted,
        slowGate: slowGate,
        burstStarted: burstStarted,
        burstGate: burstGate,
        followStarted: followStarted,
        followQuorumReached: followQuorumReached,
        followGate: followGate,
        followStopped: followStopped,
        importStopSent: importStopSent,
        followCancelled: followCancelled,
        gatedFollowQuorum: gatedFollowQuorum
    )
}

/// Boots the service in a `ServiceGroup`, waits (bounded) for the bind signal,
/// runs `body`, then triggers graceful shutdown and joins — the shared
/// ``withServiceGroup(_:logger:ready:onBodyError:_:)`` choreography, plus the
/// gate-opening failure hook this fixture needs.
func withRunningServer<T: Sendable>(
    _ server: TestServer,
    _ body: (ServiceGroup) async throws -> T
) async throws -> T {
    let bound = server.bound
    return try await withServiceGroup(
        server.service,
        ready: { _ = try await bound.wait() },
        onBodyError: {
            // A failed body may have left slow.wait, burst.wait, or a gated
            // follow handler parked; open every gate so the drain can never
            // hang on them. (Cancellation from shutdown also unblocks the
            // gated waits — this is belt-and-suspenders for the non-cancellable
            // slow/burst gates.)
            server.slowGate.fire(())
            server.burstGate.fire(())
            server.followGate.fire(())
        },
        body
    )
}

// MARK: - Raw NIO test client

/// A deliberately minimal wire client — raw `ClientBootstrap`, inbound frame
/// decoding only, hand-built frames and envelopes on the way out (so tests
/// can send garbage, oversized claims, and arbitrary hellos). NOT `MMClient`,
/// which does not exist yet.
///
/// Task-confined by design: the NIO inbound iterator must not cross tasks, so
/// this is a plain class used inside one `withWireSession` scope. Reads are
/// bounded not by racing tasks but by a **watchdog** scheduled on the
/// channel's event loop: if the session outlives its deadline the channel is
/// closed, every pending read ends, and ``timedOut`` records that the
/// deadline (not the server) ended the stream.
final class WireSession {
    private var frames: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    private let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private let watchdog: Scheduled<Void>
    private let watchdogFired: NIOLockedValueBox<Bool>

    init(
        channel: any Channel,
        inbound: NIOAsyncChannelInboundStream<ByteBuffer>,
        outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>,
        timeout: TimeAmount = .seconds(15)
    ) {
        self.frames = inbound.makeAsyncIterator()
        self.outbound = outbound
        let fired = NIOLockedValueBox(false)
        self.watchdogFired = fired
        self.watchdog = channel.eventLoop.scheduleTask(in: timeout) {
            fired.withLockedValue { $0 = true }
            channel.close(promise: nil)
        }
    }

    /// True when the watchdog deadline — not the server — closed the channel.
    var timedOut: Bool {
        self.watchdogFired.withLockedValue { $0 }
    }

    func cancelWatchdog() {
        self.watchdog.cancel()
    }

    func nextFrame() async throws -> ByteBuffer? {
        try await self.frames.next()
    }

    func nextEnvelope() async throws -> MMEnvelope? {
        guard let frame = try await self.nextFrame() else { return nil }
        return try MMEnvelope.decode(from: frame).get()
    }

    /// Reads envelopes until the response with `msgid` arrives, failing on
    /// stream end. Lets tests tolerate interleaved stream frames.
    func response(msgid: UInt32) async throws -> (error: MMError?, result: ByteBuffer?) {
        while let envelope = try await self.nextEnvelope() {
            if case .response(msgid, let error, let result) = envelope {
                return (error, result)
            }
        }
        throw DeadlineExceeded()
    }

    // MARK: - Streaming helpers (S3)

    /// Reads the next envelope addressed to `msgid`, skipping frames for other
    /// msgids (e.g. sibling streams). Fails on stream end.
    func nextEnvelope(msgid: UInt32) async throws -> MMEnvelope {
        while let envelope = try await self.nextEnvelope() {
            if envelope.msgid == msgid { return envelope }
        }
        throw DeadlineExceeded()
    }

    /// Reads exactly `count` stream items for `msgid`, in order, returning the
    /// decoded values. Any non-item frame for that msgid before `count` items
    /// arrive is an error (so a premature terminal/END fails the assertion
    /// loudly rather than hanging).
    func expectItems<Element: Decodable>(
        _ type: Element.Type,
        msgid: UInt32,
        count: Int
    ) async throws -> [(seq: UInt32, value: Element)] {
        var out: [(seq: UInt32, value: Element)] = []
        while out.count < count {
            let envelope = try await self.nextEnvelope(msgid: msgid)
            guard case .item(_, let seq, let item) = envelope else {
                throw UnexpectedFrame(envelope: envelope)
            }
            let value = try MMPackDecoder().decode(Element.self, from: item).get()
            out.append((seq, value))
        }
        return out
    }

    /// Reads the next frame for `msgid`, requiring it to be a terminal
    /// response, and returns its error/result. A stream item or other frame in
    /// its place is an error.
    func expectTerminal(msgid: UInt32) async throws -> (error: MMError?, result: ByteBuffer?)
    {
        let envelope = try await self.nextEnvelope(msgid: msgid)
        guard case .response(_, let error, let result) = envelope else {
            throw UnexpectedFrame(envelope: envelope)
        }
        return (error, result)
    }

    func expectServerHello() async throws -> MMHello {
        guard let frame = try await self.nextFrame() else {
            throw MMWireError.truncated
        }
        return try MMHello.decode(from: frame).get()
    }

    func sendHello(
        version: UInt8 = MMWireInfo.protocolVersion,
        fingerprint: UInt64 = 0,
        capabilities: UInt32 = 0
    ) async throws {
        let payload = try MMHello(
            protocolVersion: version,
            schemaFingerprint: fingerprint,
            capabilities: capabilities
        ).encode().get()
        try await self.sendFramed(payload)
    }

    func send(_ envelope: MMEnvelope) async throws {
        try await self.sendFramed(envelope.encoded().get())
    }

    func sendFramed(_ payload: ByteBuffer) async throws {
        var framed = ByteBuffer()
        framed.writeInteger(UInt32(payload.readableBytes), endianness: .little)
        framed.writeImmutableBuffer(payload)
        try await self.outbound.write(framed)
    }

    /// Writes bytes verbatim — no framing, no validation.
    func sendRaw(_ bytes: ByteBuffer) async throws {
        try await self.outbound.write(bytes)
    }
}

/// Thrown by the streaming read helpers when the frame shape is not what the
/// caller pinned (e.g. a terminal where an item was required).
struct UnexpectedFrame: Error {
    let envelope: MMEnvelope
}

extension MMEnvelope {
    /// The msgid this envelope addresses. Lets `WireSession` filter frames by
    /// call without a switch at every call site.
    var msgid: UInt32 {
        switch self {
            case .request(let msgid, _, _, _),
                .response(let msgid, _, _),
                .credit(let msgid, _),
                .item(let msgid, _, _),
                .end(let msgid),
                .stop(let msgid, _),
                .cancel(let msgid):
                return msgid
        }
    }
}

/// Client pipeline: inbound frame decoding only — outbound frames are built
/// by hand in `WireSession` so tests keep raw control of every byte.
@Sendable
private func initializeClientChannel(
    _ channel: any Channel
) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> {
    channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MMFrameDecoder(maxFrameLength: 1 << 20))
        )
        return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
    }
}

private func withWireSession<T: Sendable>(
    over channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
    _ body: (WireSession) async throws -> T
) async throws -> T {
    try await channel.executeThenClose { inbound, outbound in
        let session = WireSession(channel: channel.channel, inbound: inbound, outbound: outbound)
        defer { session.cancelWatchdog() }
        return try await body(session)
    }
}

func withWireSession<T: Sendable>(
    unixPath: String,
    _ body: (WireSession) async throws -> T
) async throws -> T {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .connect(unixDomainSocketPath: unixPath, channelInitializer: initializeClientChannel)
    return try await withWireSession(over: channel, body)
}

func withWireSession<T: Sendable>(
    host: String,
    port: Int,
    _ body: (WireSession) async throws -> T
) async throws -> T {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .connect(host: host, port: port, channelInitializer: initializeClientChannel)
    return try await withWireSession(over: channel, body)
}

/// Asserts the unix endpoint refuses new connections. The listener close is
/// triggered asynchronously by graceful shutdown, so a still-succeeding
/// connect is retried (each attempt closes its accepted connection
/// immediately); the whole probe is deadline-bounded, so a server that never
/// stops accepting fails with `DeadlineExceeded` rather than spinning forever.
func expectConnectRefused(unixPath: String) async throws {
    try await withDeadline(seconds: 10) {
        while true {
            let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
            do {
                channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connect(
                        unixDomainSocketPath: unixPath,
                        channelInitializer: initializeClientChannel
                    )
            } catch {
                return  // Refused: the listener is closed.
            }
            try? await channel.executeThenClose { _, _ in }
        }
    }
}

// MARK: - Real MMClient harness

func quietClientLogger() -> Logger {
    var logger = Logger(label: "mm.test.client")
    logger.logLevel = .warning
    return logger
}

/// Connects a real `MMClientConnection` to the temp-dir socket — see
/// `withConnectedClient(to:configuration:_:)`.
func withConnectedClient<T: Sendable>(
    unixPath: String,
    configuration: MMClientConfiguration = MMClientConfiguration(),
    _ body: @escaping @Sendable (MMClientConnection) async throws -> T
) async throws -> (result: T, runResult: Result<Void, MMClientError>) {
    try await withConnectedClient(
        to: .unix(path: unixPath), configuration: configuration, body)
}

/// Connects a real `MMClientConnection` to `endpoint`, then hands off to the
/// shared ``withClientRunLoop(connection:context:bodySeconds:joinSeconds:_:)``
/// run/close/join choreography — the client-side twin of `withRunningServer`.
func withConnectedClient<T: Sendable>(
    to endpoint: MMEndpoint,
    configuration: MMClientConfiguration = MMClientConfiguration(),
    _ body: @escaping @Sendable (MMClientConnection) async throws -> T
) async throws -> (result: T, runResult: Result<Void, MMClientError>) {
    let connection = try await MMClientConnection.connect(
        to: endpoint,
        configuration: configuration,
        logger: quietClientLogger()
    ).get()
    return try await withClientRunLoop(
        connection: connection,
        context: connection,
        bodySeconds: 20,
        joinSeconds: 30,
        body
    )
}

// MARK: - Envelope helpers
// encodedParams / request come from MMTestSupport.

func decodeResult<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer?) throws -> T {
    guard let buffer else { throw MMWireError.truncated }
    return try MMPackDecoder().decode(T.self, from: buffer).get()
}

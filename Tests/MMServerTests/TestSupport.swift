import Foundation
import MMTestSupport
import Synchronization
import MMSchema
import MMServer
import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore

// MARK: - Entities and peers

/// Parses a known-good entity literal; test fixtures only.
func entity(_ raw: String) -> EntityName {
    try! EntityName.parse(raw).get()
}

/// Fixture peers against ACLs owned by uid 1000, group 500.
enum Peers {
    static let owner = PeerIdentity(uid: 1000, gid: 1000, supplementaryGroups: [], pid: 101)
    static let groupMember = PeerIdentity(uid: 2000, gid: 500, supplementaryGroups: [], pid: 102)
    static let supplementaryMember = PeerIdentity(
        uid: 2001, gid: 999, supplementaryGroups: [77, 500], pid: 103
    )
    static let other = PeerIdentity(uid: 3000, gid: 3000, supplementaryGroups: [], pid: 104)
    static let uidZero = PeerIdentity(uid: 0, gid: 0, supplementaryGroups: [], pid: 105)
}

/// An ACL owned by uid 1000, group 500 with the given mode.
func acl(_ mode: UInt16) -> EntityACL {
    EntityACL(owner: 1000, group: 500, mode: mode)
}

// MARK: - Recording ACL provider

/// Records every `acl(for:)` lookup in order, so tests can prove the
/// ancestors-then-target dispatch order and short-circuiting on denial.
actor RecordingACLProvider: EntityACLProvider {
    private(set) var lookups: [EntityName] = []
    private(set) var invalidated: [EntityName] = []
    private var acls: [EntityName: EntityACL]
    private let failing: Set<EntityName>

    init(_ acls: [EntityName: EntityACL] = [:], failing: Set<EntityName> = []) {
        self.acls = acls
        self.failing = failing
    }

    func acl(for entity: EntityName) async -> Result<EntityACL?, ACLProviderError> {
        self.lookups.append(entity)
        if self.failing.contains(entity) {
            return .failure(ACLProviderError(description: "storage unavailable"))
        }
        return .success(self.acls[entity])
    }

    func invalidate(_ entity: EntityName) async {
        self.invalidated.append(entity)
    }
}

func makeContext(
    peer: PeerIdentity = Peers.other,
    connectionID: UInt64 = 1
) -> MMContext {
    MMContext(peer: peer, protocolVersion: 1, connectionID: connectionID)
}

// MARK: - Request/response fixtures
// EchoRequest/EchoResponse come from MMTestSupport (shared with the
// integration suite).

/// Counts full-decode invocations.
final class InvocationCounter: Sendable {
    private let count = Mutex(0)

    func increment() {
        self.count.withLock { $0 += 1 }
    }

    var value: Int {
        self.count.withLock { $0 }
    }
}

/// Task-local wiring for ``ProbedRequest``: tests bind a counter around a
/// `dispatch` call; the request's `init(from:)` increments it. Task-local (not
/// global) so parallel tests never observe each other's decodes.
enum FullDecodeProbe {
    @TaskLocal static var counter: InvocationCounter?
}

/// A request whose `Decodable` initializer records that a **full** params
/// decode ran. Conforms to `SchemaDescribable` so the schema probe never
/// executes `init(from:)` — only the router's post-authorization decode does.
struct ProbedRequest: Codable, Sendable, SchemaDescribable {
    var entity: EntityName

    enum CodingKeys: Int, CodingKey {
        case entity = 0
    }

    init(entity: EntityName) {
        self.entity = entity
    }

    init(from decoder: any Decoder) throws {
        FullDecodeProbe.counter?.increment()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.entity = try container.decode(EntityName.self, forKey: .entity)
    }

    static var schema: TypeSchema {
        .structure(fields: [.init(key: 0, name: "entity", type: .string)])
    }
}

// MARK: - Envelope helpers
// encodedParams / request come from MMTestSupport.

/// The error code of a response envelope, or `nil` for success responses and
/// non-responses.
func errorCode(of envelope: MMEnvelope?) -> Int? {
    guard case .response(_, let error, _) = envelope else { return nil }
    return error?.code
}

/// The result slice of a *successful* response envelope.
func resultBuffer(of envelope: MMEnvelope?) -> ByteBuffer? {
    guard case .response(_, .none, let result) = envelope else { return nil }
    return result
}

// MARK: - Metrics

/// A capturing ``MetricsFactory`` that records counter increments by label into
/// a shared registry, so a test can assert exactly which stream counters
/// advanced and by how much. Injected into ``MMStreamMetrics`` per test (never
/// bootstrapped globally), so it is isolated from every other suite and safe
/// under parallel test execution.
final class CapturingMetricsFactory: MetricsFactory, Sendable {
    private struct Waiter {
        let id: UInt64
        let label: String
        let target: Int64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct Registry {
        var totals: [String: Int64] = [:]
        var waiters: [Waiter] = []
        var nextWaiterID: UInt64 = 0

        /// Records an increment and hands back the waiters it satisfies, to be
        /// resumed outside the lock.
        mutating func add(_ amount: Int64, to label: String) -> [Waiter] {
            let total = self.totals[label, default: 0] + amount
            self.totals[label] = total
            let satisfied = self.waiters.filter { $0.label == label && total >= $0.target }
            self.waiters.removeAll { $0.label == label && total >= $0.target }
            return satisfied
        }
    }

    private let registry = NIOLockedValueBox(Registry())

    /// The recorded total for `label` (0 if the counter was never incremented).
    func total(_ label: String) -> Int64 {
        self.registry.withLockedValue { $0.totals[label] ?? 0 }
    }

    /// Suspends until `label`'s total reaches `target`: a gate on an increment
    /// the code under test makes, in place of a sleep. Returns at once when the
    /// total is already there, and when the waiting task is cancelled (a
    /// deadline fired), so a regression fails instead of hanging.
    func reached(_ label: String, _ target: Int64) async {
        let id = self.registry.withLockedValue { registry in
            registry.nextWaiterID += 1
            return registry.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = self.registry.withLockedValue { registry in
                    guard (registry.totals[label] ?? 0) < target, !Task.isCancelled else {
                        return false
                    }
                    registry.waiters.append(
                        Waiter(id: id, label: label, target: target, continuation: continuation))
                    return true
                }
                if !parked { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.registry.withLockedValue { registry in
                registry.waiters.firstIndex { $0.id == id }.map { registry.waiters.remove(at: $0) }
            }
            waiter?.continuation.resume()
        }
    }

    private final class Handle: CounterHandler {
        let label: String
        let registry: NIOLockedValueBox<Registry>
        init(label: String, registry: NIOLockedValueBox<Registry>) {
            self.label = label
            self.registry = registry
        }
        func increment(by amount: Int64) {
            let satisfied = self.registry.withLockedValue { $0.add(amount, to: self.label) }
            for waiter in satisfied { waiter.continuation.resume() }
        }
        func reset() { self.registry.withLockedValue { $0.totals[self.label] = 0 } }
    }

    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        Handle(label: label, registry: self.registry)
    }
    func makeFloatingPointCounter(
        label: String, dimensions: [(String, String)]
    ) -> FloatingPointCounterHandler {
        NOOPMetricsHandler.instance
    }
    func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        NOOPMetricsHandler.instance
    }
    func makeRecorder(
        label: String, dimensions: [(String, String)], aggregate: Bool
    ) -> RecorderHandler {
        NOOPMetricsHandler.instance
    }
    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        NOOPMetricsHandler.instance
    }
    func destroyCounter(_ handler: CounterHandler) {}
    func destroyFloatingPointCounter(_ handler: FloatingPointCounterHandler) {}
    func destroyMeter(_ handler: MeterHandler) {}
    func destroyRecorder(_ handler: RecorderHandler) {}
    func destroyTimer(_ handler: TimerHandler) {}
}

/// Stream counters the tests gate on with
/// ``CapturingMetricsFactory/reached(_:_:)`` instead of sleeping.
enum StreamCounter {
    /// Ticks when a response send finds zero credit, just before it parks. The
    /// park re-checks credit, STOP, and end under the sink's lock, so anything
    /// done once this ticks resolves the parked send.
    static let creditStalls = "mm_server_stream_credit_stalls_total"
    /// Ticks when the grant pump takes a batch, just before it writes the
    /// credit frame; the stream's task group joins the pump, so the frame is
    /// recorded by the time the stream finishes.
    static let creditGrantsOut = "mm_server_stream_credit_grants_out_total"
}

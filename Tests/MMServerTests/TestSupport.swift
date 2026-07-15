import Foundation
import Synchronization
import MMSchema
import MMServer
import MMWire
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

struct EchoRequest: Codable, Hashable, Sendable {
    var entity: EntityName
    var value: Int

    enum CodingKeys: Int, CodingKey {
        case entity = 0
        case value = 1
    }
}

struct EchoResponse: Codable, Hashable, Sendable {
    var value: Int

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }
}

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

func encodedParams<T: Encodable>(_ value: T) -> ByteBuffer {
    try! MMPackEncoder().encode(value).get()
}

func request<T: Encodable>(
    msgid: UInt32 = 1, method: String, entity: EntityName = .root, _ body: T
) -> MMEnvelope {
    .request(msgid: msgid, method: method, entity: entity.rawValue, params: encodedParams(body))
}

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

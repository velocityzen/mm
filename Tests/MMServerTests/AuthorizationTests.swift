import MMSchema
import MMServer
import MMTestSupport
import MMWire
import Testing

/// Truth-table authorization through full dispatch: permission classes ×
/// access bits on the target, ancestor traversal, root semantics, anonymous
/// peers, and the no-superuser rule.
@Suite("Authorization")
struct AuthorizationTests {
    /// Dispatches one echo request for `peer` against `acls`, with the route
    /// requiring `access` on the target. Returns the wire error code, or nil
    /// on success.
    private func dispatchCode(
        access: AccessMode,
        acls: [EntityName: EntityACL],
        peer: PeerIdentity,
        target: String
    ) async -> Int? {
        let router = Router(aclProvider: InMemoryACLProvider(acls)) {
            Handle(Method<EchoRequest, EchoResponse>(name: "test.echo", access: access)) {
                request, _ in
                .success(EchoResponse(value: request.value))
            }
        }
        let reply = await router.dispatch(
            envelope: request(
                method: "test.echo", entity: entity(target),
                EchoRequest(entity: entity(target), value: 3)),
            context: makeContext(peer: peer)
        )
        return errorCode(of: reply)
    }

    /// One row of the class × bit truth table on a single-segment target
    /// (no ancestors, so only the target check decides).
    struct Row: Sendable, CustomTestStringConvertible {
        let access: AccessMode
        let mode: UInt16
        let peer: PeerIdentity
        let granted: Bool
        let label: String

        var testDescription: String { self.label }
    }

    private static func rows(bit: AccessMode, bitName: String) -> [Row] {
        let ownerMode = UInt16(bit.rawValue) << 6
        let groupMode = UInt16(bit.rawValue) << 3
        let otherMode = UInt16(bit.rawValue)
        return [
            // Bit granted to the owner class only.
            Row(
                access: bit, mode: ownerMode, peer: Peers.owner, granted: true,
                label: "\(bitName): owner-only grants owner"),
            Row(
                access: bit, mode: ownerMode, peer: Peers.groupMember, granted: false,
                label: "\(bitName): owner-only denies group"),
            Row(
                access: bit, mode: ownerMode, peer: Peers.supplementaryMember, granted: false,
                label: "\(bitName): owner-only denies supplementary"),
            Row(
                access: bit, mode: ownerMode, peer: Peers.other, granted: false,
                label: "\(bitName): owner-only denies other"),
            // Bit granted to the group class only. First-matching-class-wins:
            // the owner is classified owner and gets the (empty) owner bits.
            Row(
                access: bit, mode: groupMode, peer: Peers.owner, granted: false,
                label: "\(bitName): group-only denies owner"),
            Row(
                access: bit, mode: groupMode, peer: Peers.groupMember, granted: true,
                label: "\(bitName): group-only grants primary gid"),
            Row(
                access: bit, mode: groupMode, peer: Peers.supplementaryMember, granted: true,
                label: "\(bitName): group-only grants supplementary gid"),
            Row(
                access: bit, mode: groupMode, peer: Peers.other, granted: false,
                label: "\(bitName): group-only denies other"),
            // Bit granted to the other class only.
            Row(
                access: bit, mode: otherMode, peer: Peers.owner, granted: false,
                label: "\(bitName): other-only denies owner"),
            Row(
                access: bit, mode: otherMode, peer: Peers.groupMember, granted: false,
                label: "\(bitName): other-only denies group"),
            Row(
                access: bit, mode: otherMode, peer: Peers.other, granted: true,
                label: "\(bitName): other-only grants other"),
        ]
    }

    static let truthTable: [Row] =
        rows(bit: .read, bitName: "r")
        + rows(bit: .write, bitName: "w")
        + rows(bit: .execute, bitName: "x")

    @Test("class × bit truth table on the target", arguments: truthTable)
    func targetTruthTable(row: Row) async {
        let code = await self.dispatchCode(
            access: row.access,
            acls: [entity("solo"): acl(row.mode)],
            peer: row.peer,
            target: "solo"
        )
        if row.granted {
            #expect(code == nil)
        } else {
            #expect(code == MMErrorCode.permissionDenied.code)
        }
    }

    @Test("owner denied while other granted (first-matching-class asymmetry)")
    func ownerDeniedOtherGranted() async {
        let acls = [entity("solo"): acl(0o007)]
        let ownerCode = await self.dispatchCode(
            access: .read, acls: acls, peer: Peers.owner, target: "solo"
        )
        let otherCode = await self.dispatchCode(
            access: .read, acls: acls, peer: Peers.other, target: "solo"
        )
        #expect(ownerCode == MMErrorCode.permissionDenied.code)
        #expect(otherCode == nil)
    }

    @Test("missing x on one ancestor denies even when the target grants all")
    func ancestorWithoutExecuteDenies() async {
        let code = await self.dispatchCode(
            access: .read,
            acls: [
                entity("top"): acl(0o666),  // rw, no x anywhere
                entity("top.leaf"): acl(0o777),
            ],
            peer: Peers.owner,
            target: "top.leaf"
        )
        #expect(code == MMErrorCode.permissionDenied.code)
    }

    @Test("root target is denied by default — no ACL exists that could gate it")
    func rootTargetDeniedByDefault() async {
        // Routes built with the default `acceptsRoot: false`: an empty target
        // must never reach the handler, whatever the provider holds.
        let code = await self.dispatchCode(
            access: .read, acls: [:], peer: Peers.other, target: ""
        )
        #expect(code == MMErrorCode.permissionDenied.code)
    }

    @Test("acceptsRoot opts a route into root targets (no traversal, no target ACL)")
    func rootTargetOptIn() async {
        // Empty provider: any ACL consultation would deny, proving the
        // opted-in root dispatch consults none.
        let router = Router(aclProvider: InMemoryACLProvider()) {
            Handle(
                Method<EchoRequest, EchoResponse>(name: "tree.walk", access: .read),
                acceptsRoot: true
            ) { request, _ in
                .success(EchoResponse(value: request.value))
            }
        }
        let reply = await router.dispatch(
            envelope: request(
                method: "tree.walk", entity: .root, EchoRequest(entity: .root, value: 3)),
            context: makeContext(peer: Peers.other)
        )
        #expect(errorCode(of: reply) == nil)
    }

    @Test("root request to a non-opted-in route is denied and never reaches the handler")
    func rootRequestDeniedByDefault() async {
        let counter = InvocationCounter()
        let router = Router(aclProvider: InMemoryACLProvider()) {
            Handle(Method<EchoRequest, EchoResponse>(name: "tree.note", access: .write)) {
                request, _ in
                counter.increment()
                return .success(EchoResponse(value: request.value))
            }
        }
        let reply = await router.dispatch(
            envelope: request(
                method: "tree.note", entity: .root, EchoRequest(entity: .root, value: 1)),
            context: makeContext(peer: Peers.other)
        )
        #expect(errorCode(of: reply) == MMErrorCode.permissionDenied.code)
        #expect(counter.value == 0)
    }

    @Test("anonymous peer matches only the other class")
    func anonymousPeer() async {
        let denied = await self.dispatchCode(
            access: .read,
            acls: [entity("solo"): acl(0o770)],
            peer: .anonymous,
            target: "solo"
        )
        let granted = await self.dispatchCode(
            access: .read,
            acls: [entity("solo"): acl(0o004)],
            peer: .anonymous,
            target: "solo"
        )
        #expect(denied == MMErrorCode.permissionDenied.code)
        #expect(granted == nil)
    }

    @Test("uid 0 is not special")
    func uidZeroNotSpecial() async {
        let code = await self.dispatchCode(
            access: .read,
            acls: [entity("solo"): acl(0o770)],  // owner 1000, group 500
            peer: Peers.uidZero,
            target: "solo"
        )
        #expect(code == MMErrorCode.permissionDenied.code)
    }
}

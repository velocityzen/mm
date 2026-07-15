import Foundation
import Testing

@testable import MMSchema

@Suite("AccessMode")
struct AccessModeTests {
    @Test("POSIX bit values")
    func bitValues() {
        #expect(AccessMode.execute.rawValue == 1)
        #expect(AccessMode.write.rawValue == 2)
        #expect(AccessMode.read.rawValue == 4)
        #expect(AccessMode.all.rawValue == 7)
        #expect(AccessMode([.read, .execute]).rawValue == 5)
    }

    @Test("Codable round trip preserves unknown high bits")
    func codableRoundTrip() throws {
        let mode = AccessMode(rawValue: 0b1010_0101)
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(AccessMode.self, from: data)
        #expect(decoded == mode)
    }
}

@Suite("EntityACL")
struct EntityACLTests {
    static let acl = EntityACL(owner: 1000, group: 100, mode: 0o750)

    static func peer(
        uid: uid_t,
        gid: gid_t,
        groups: [gid_t] = [],
        pid: pid_t = 42
    ) -> PeerIdentity {
        PeerIdentity(uid: uid, gid: gid, supplementaryGroups: groups, pid: pid)
    }

    @Test("class selection: uid match wins first")
    func classSelectionOwner() {
        // Owner class even when the gid also matches: first-matching-class-wins.
        #expect(Self.acl.permissionClass(for: Self.peer(uid: 1000, gid: 100)) == .owner)
        #expect(Self.acl.permissionClass(for: Self.peer(uid: 1000, gid: 9)) == .owner)
    }

    @Test("class selection: primary gid, supplementary groups, other")
    func classSelectionGroupAndOther() {
        #expect(Self.acl.permissionClass(for: Self.peer(uid: 2000, gid: 100)) == .group)
        #expect(
            Self.acl.permissionClass(for: Self.peer(uid: 2000, gid: 9, groups: [7, 100, 12]))
                == .group)
        #expect(
            Self.acl.permissionClass(for: Self.peer(uid: 2000, gid: 9, groups: [7, 12])) == .other)
    }

    @Test("bits per class for 0o750")
    func bitsPerClass() {
        #expect(Self.acl.bits(for: .owner) == [.read, .write, .execute])
        #expect(Self.acl.bits(for: .group) == [.read, .execute])
        #expect(Self.acl.bits(for: .other) == [])
    }

    @Test("truth table across all three classes, mode 0o750")
    func truthTable() {
        let owner = Self.peer(uid: 1000, gid: 100)
        let groupMember = Self.peer(uid: 2000, gid: 100)
        let supplementaryMember = Self.peer(uid: 2000, gid: 9, groups: [100])
        let other = Self.peer(uid: 2000, gid: 9)

        #expect(Self.acl.permitted(for: owner, .read))
        #expect(Self.acl.permitted(for: owner, .write))
        #expect(Self.acl.permitted(for: owner, .execute))
        #expect(Self.acl.permitted(for: owner, [.read, .write, .execute]))

        #expect(Self.acl.permitted(for: groupMember, .read))
        #expect(!Self.acl.permitted(for: groupMember, .write))
        #expect(Self.acl.permitted(for: groupMember, .execute))
        #expect(!Self.acl.permitted(for: groupMember, [.read, .write]))

        #expect(Self.acl.permitted(for: supplementaryMember, [.read, .execute]))
        #expect(!Self.acl.permitted(for: supplementaryMember, .write))

        #expect(!Self.acl.permitted(for: other, .read))
        #expect(!Self.acl.permitted(for: other, .write))
        #expect(!Self.acl.permitted(for: other, .execute))
        // The empty request is vacuously permitted for everyone.
        #expect(Self.acl.permitted(for: other, []))
    }

    @Test("owner denied while other granted: first-matching-class-wins, mode 0o007")
    func ownerDeniedOtherGrantedAsymmetry() {
        let acl = EntityACL(owner: 1000, group: 100, mode: 0o007)
        let owner = Self.peer(uid: 1000, gid: 100)
        let stranger = Self.peer(uid: 2000, gid: 9)

        // The peer IS the owner, so the owner bits (000) decide — pure denial,
        // even though the other bits would grant everything.
        #expect(!acl.permitted(for: owner, .read))
        #expect(!acl.permitted(for: owner, .write))
        #expect(!acl.permitted(for: owner, .execute))

        #expect(acl.permitted(for: stranger, [.read, .write, .execute]))

        // Same asymmetry one class down: group members hit the group bits.
        let groupOnly = EntityACL(owner: 1000, group: 100, mode: 0o707)
        let groupMember = Self.peer(uid: 2000, gid: 100)
        #expect(!groupOnly.permitted(for: groupMember, .read))
        #expect(groupOnly.permitted(for: stranger, .read))
    }

    @Test("uid 0 gets nothing for free")
    func rootUidNotSpecial() {
        let acl = EntityACL(owner: 1000, group: 100, mode: 0o770)
        let rootPeer = Self.peer(uid: 0, gid: 0)
        #expect(acl.permissionClass(for: rootPeer) == .other)
        #expect(!acl.permitted(for: rootPeer, .read))
        #expect(!acl.permitted(for: rootPeer, .write))
        #expect(!acl.permitted(for: rootPeer, .execute))
    }

    @Test("anonymous identity maps to the other class")
    func anonymousMapsToOther() {
        #expect(Self.acl.permissionClass(for: .anonymous) == .other)
        #expect(!Self.acl.permitted(for: .anonymous, .read))

        let open = EntityACL(owner: 1000, group: 100, mode: 0o754)
        #expect(open.permitted(for: .anonymous, .read))
        #expect(!open.permitted(for: .anonymous, .write))
    }

    @Test("anonymous constants")
    func anonymousConstants() {
        #expect(PeerIdentity.anonymous.uid == uid_t.max)
        #expect(PeerIdentity.anonymous.gid == gid_t.max)
        #expect(PeerIdentity.anonymous.supplementaryGroups.isEmpty)
        #expect(PeerIdentity.anonymous.pid == 0)
    }

    @Test("default creation mode is 0o750")
    func defaultCreationMode() {
        #expect(EntityACL.defaultCreationMode == 0o750)
    }

    @Test("Codable round trip")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.acl)
        let decoded = try JSONDecoder().decode(EntityACL.self, from: data)
        #expect(decoded == Self.acl)
    }
}

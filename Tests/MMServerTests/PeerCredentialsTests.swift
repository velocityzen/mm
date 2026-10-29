import MMSchema
import MMTestSupport
import Testing

@testable import MMServer

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("Peer credential parsing")
struct PeerCredentialsTests {
    // MARK: - xucred-shaped mapping (pure, runs on every platform)

    @Test("first group is the primary (effective) gid, the rest are supplementary")
    func groupMapping() {
        let identity = PeerCredentials.identity(uid: 501, groups: [20, 12, 61, 79], pid: 4242)
        #expect(identity.uid == 501)
        #expect(identity.gid == 20)
        #expect(identity.supplementaryGroups == [12, 61, 79])
        #expect(identity.pid == 4242)
    }

    @Test("a single group means primary only, no supplementary groups")
    func singleGroup() {
        let identity = PeerCredentials.identity(uid: 0, groups: [0], pid: 1)
        #expect(identity.gid == 0)
        #expect(identity.supplementaryGroups.isEmpty)
    }

    @Test("an empty group list maps the primary gid to gid_t.max (other-class only)")
    func emptyGroupsFailClosed() {
        let identity = PeerCredentials.identity(uid: 501, groups: [], pid: 7)
        #expect(identity.gid == gid_t.max)
        #expect(identity.supplementaryGroups.isEmpty)
    }

    #if canImport(Darwin)
    @Test("synthetic xucred maps ngroups-bounded groups out of the fixed tuple")
    func xucredMapping() {
        var credentials = xucred()
        credentials.cr_version = 0
        credentials.cr_uid = 501
        credentials.cr_ngroups = 3
        credentials.cr_groups.0 = 20
        credentials.cr_groups.1 = 12
        credentials.cr_groups.2 = 61
        credentials.cr_groups.3 = 99  // beyond cr_ngroups — must be ignored
        let identity = PeerCredentials.identity(fromXucred: credentials, pid: 555)
        #expect(identity.uid == 501)
        #expect(identity.gid == 20)
        #expect(identity.supplementaryGroups == [12, 61])
        #expect(identity.pid == 555)
    }

    @Test("negative or oversized cr_ngroups is clamped, never read out of bounds")
    func xucredClamping() {
        var credentials = xucred()
        credentials.cr_uid = 501
        credentials.cr_ngroups = -1
        let negative = PeerCredentials.identity(fromXucred: credentials, pid: 1)
        #expect(negative.gid == gid_t.max)
        #expect(negative.supplementaryGroups.isEmpty)

        credentials.cr_ngroups = 99  // kernel max is 16; must clamp to the tuple
        credentials.cr_groups.0 = 20
        let oversized = PeerCredentials.identity(fromXucred: credentials, pid: 1)
        #expect(oversized.gid == 20)
        #expect(oversized.supplementaryGroups.count == 15)
    }
    #endif

    // MARK: - SO_PEERGROUPS slots (pure, runs on every platform)

    @Test("the zero tail of the peer-groups buffer is padding")
    func peerGroupsPaddingTrimmed() {
        #expect(
            PeerCredentials.supplementaryGroups(fromPeerGroups: [4, 24, 27, 1000, 0, 0, 0])
                == [4, 24, 27, 1000]
        )
    }

    @Test("a leading gid 0 followed by other groups is kept")
    func peerGroupsLeadingRootGroupKept() {
        #expect(
            PeerCredentials.supplementaryGroups(fromPeerGroups: [0, 4, 24, 0, 0]) == [0, 4, 24]
        )
    }

    @Test("an all-zero buffer yields no groups, failing closed on a sole gid 0")
    func peerGroupsAllZero() {
        #expect(PeerCredentials.supplementaryGroups(fromPeerGroups: [0, 0, 0]) == [])
        #expect(PeerCredentials.supplementaryGroups(fromPeerGroups: []) == [])
    }

    @Test("a full buffer has no padding to trim")
    func peerGroupsFullBuffer() {
        let full = (1...256).map { gid_t($0) }
        #expect(PeerCredentials.supplementaryGroups(fromPeerGroups: full) == full)
    }
}

import Foundation  // Tests only: mkstemp template under NSTemporaryDirectory().
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

    // MARK: - /proc/<pid>/status Groups: line (pure, runs on every platform)

    @Test("parses a canned Groups line with tab and trailing space")
    func procStatusGroupsLine() {
        let status = """
            Name:\tmm-daemon
            Umask:\t0022
            State:\tS (sleeping)
            Pid:\t4242
            Uid:\t1000\t1000\t1000\t1000
            Gid:\t1000\t1000\t1000\t1000
            Groups:\t4 24 27 30 46 1000 \r
            VmPeak:\t  168124 kB
            """
        let groups = PeerCredentials.supplementaryGroups(fromProcStatus: status[...])
        #expect(groups == [4, 24, 27, 30, 46, 1000])
    }

    @Test("empty Groups line yields no groups")
    func emptyGroupsLine() {
        let status = "Pid:\t1\nGroups:\t \nSeccomp:\t0\n"
        #expect(PeerCredentials.supplementaryGroups(fromProcStatus: status[...]) == [])
    }

    @Test("missing Groups line fails closed to no groups")
    func missingGroupsLine() {
        let status = "Name:\tinit\nPid:\t1\n"
        #expect(PeerCredentials.supplementaryGroups(fromProcStatus: status[...]) == [])
    }

    @Test("garbage tokens are skipped, valid ids kept")
    func garbageTokensSkipped() {
        let status = "Groups:\t12 abc -5 4294967295 99999999999999999999 61\n"
        #expect(
            PeerCredentials.supplementaryGroups(fromProcStatus: status[...])
                == [12, gid_t.max, 61]
        )
    }

    @Test("only the first Groups line is honored")
    func firstGroupsLineWins() {
        let status = "Groups:\t1 2\nGroups:\t3 4\n"
        #expect(PeerCredentials.supplementaryGroups(fromProcStatus: status[...]) == [1, 2])
    }

    // MARK: - readToEnd boundaries (pure POSIX, runs on every platform)

    /// A `Groups:` line can legitimately exceed 64 KiB (`NGROUPS_MAX` is 65536
    /// on Linux). The read must reach EOF — a truncated read that cuts a gid
    /// token mid-digits would fabricate a *different, valid* gid and grant
    /// group access the peer does not hold — and must fail closed (nil, never
    /// a partial buffer) when EOF is not reached within the cap.
    @Test("readToEnd reads past 64 KiB to EOF, and fails closed over the cap")
    func readToEndBoundaries() throws {
        var content = "Name:\tmm\nGroups:\t"
        for gid in 100_000..<110_000 {
            content += "\(gid) "
        }
        content += "\n"
        let contentBytes = Array(content.utf8)
        #expect(contentBytes.count > 64 * 1024)

        var template = Array((NSTemporaryDirectory() + "mm-status-XXXXXX").utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        #expect(descriptor >= 0)
        defer {
            close(descriptor)
            template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        }
        var written = 0
        while written < contentBytes.count {
            let count = contentBytes.withUnsafeBytes { raw in
                write(descriptor, raw.baseAddress! + written, raw.count - written)
            }
            #expect(count > 0)
            written += count
        }

        // Whole file within the cap: byte-exact, and every gid parses.
        #expect(lseek(descriptor, 0, SEEK_SET) == 0)
        let bytes = try #require(
            PeerCredentials.readToEnd(descriptor: descriptor, hardCap: 4 * 1024 * 1024)
        )
        #expect(bytes == contentBytes)
        let text = String(decoding: bytes, as: UTF8.self)
        let groups = PeerCredentials.supplementaryGroups(fromProcStatus: text[...])
        #expect(groups.count == 10_000)
        #expect(groups.first == 100_000)
        #expect(groups.last == 109_999)

        // EOF not reached within the cap: nil, never a truncated prefix that
        // would parse "412345" as gid 4123.
        #expect(lseek(descriptor, 0, SEEK_SET) == 0)
        #expect(PeerCredentials.readToEnd(descriptor: descriptor, hardCap: 64 * 1024) == nil)
    }
}

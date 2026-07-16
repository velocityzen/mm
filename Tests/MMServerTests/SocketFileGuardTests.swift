import Foundation  // Tests only: mkdtemp template under NSTemporaryDirectory().
import Logging
import Testing

@testable import MMServer

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Runs `body` with a fresh temp path (no file created), cleaning up the
/// directory afterwards.
private func withTempPath(_ body: (String) throws -> Void) throws {
    var template = Array((NSTemporaryDirectory() + "mm-guard-XXXXXX").utf8CString)
    let directory = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard mkdtemp(buffer.baseAddress!) != nil else { return nil }
        return String(cString: buffer.baseAddress!)
    }
    let unwrapped = try #require(directory)
    defer {
        unlink(unwrapped + "/s")
        rmdir(unwrapped)
    }
    try body(unwrapped + "/s")
}

/// The identity-guarded shutdown unlink: a draining server must remove only
/// the socket file *it* bound, never a successor's replacement at the same
/// path.
@Suite("Socket file removal guard")
struct SocketFileGuardTests {
    private func createFile(path: String) throws {
        let descriptor = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        #expect(descriptor >= 0)
        close(descriptor)
    }

    @Test("a replaced path (same name, new inode) is left alone; the owned one is removed")
    func replacedFileSurvivesOwnedFileRemoved() throws {
        try withTempPath { path in
            let logger = Logger(label: "mm.test")

            try self.createFile(path: path)
            let original = try #require(MMService.socketFileIdentity(path: path))

            // Hold the original file open across the replacement: ext4 reuses
            // a freed inode number immediately, so without this the
            // replacement can collide with `original` on device+inode AND on
            // ctime (created within the same kernel clock tick) — a same-tick
            // collision no production drain window can produce, but a
            // back-to-back unlink/create here does. The open descriptor pins
            // the inode, guaranteeing the replacement gets a fresh one.
            let held = open(path, O_RDONLY)
            #expect(held >= 0)
            defer { close(held) }

            // Simulate the successor: the path is unlinked and re-bound while
            // the original instance is still draining.
            #expect(unlink(path) == 0)
            try self.createFile(path: path)
            let replacement = try #require(MMService.socketFileIdentity(path: path))
            #expect(original != replacement)

            // The old instance's shutdown unlink must not touch the new file…
            MMService.removeSocketFile(path: path, owned: original, logger: logger)
            #expect(MMService.socketFileIdentity(path: path) == replacement)

            // …while the rightful owner removes it.
            MMService.removeSocketFile(path: path, owned: replacement, logger: logger)
            #expect(MMService.socketFileIdentity(path: path) == nil)
        }
    }

    @Test("a missing file and an unknown identity are both quiet no-op/unlink paths")
    func missingFileAndUnknownIdentity() throws {
        try withTempPath { path in
            let logger = Logger(label: "mm.test")
            // Path absent: nothing to do, no crash, regardless of identity.
            MMService.removeSocketFile(
                path: path,
                owned: MMService.SocketFileIdentity(
                    device: 1, inode: 1, changeTimeSeconds: 0, changeTimeNanoseconds: 0),
                logger: logger
            )
            #expect(MMService.socketFileIdentity(path: path) == nil)

            // Unknown identity (capture failed at bind): unconditional unlink,
            // the pre-guard behavior.
            try self.createFile(path: path)
            MMService.removeSocketFile(path: path, owned: nil, logger: logger)
            #expect(MMService.socketFileIdentity(path: path) == nil)
        }
    }
}

/// Startup descriptor hygiene: every unix socket the service creates (the
/// liveness probe and the bound listener) must carry `FD_CLOEXEC`, or the
/// descriptor leaks into child processes the host forks — an inherited
/// listener keeps the socket connectable after the daemon dies and defeats
/// the restart-time stale-socket probe. NIO's adoption path never sets it.
@Suite("Unix socket close-on-exec")
struct SocketCloexecTests {
    @Test("a raw unix stream socket is created with FD_CLOEXEC")
    func rawSocketIsCloseOnExec() throws {
        let descriptor = try MMService.makeUnixStreamSocket()
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFD, 0)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC == FD_CLOEXEC)
    }

    @Test("the bound listening descriptor keeps FD_CLOEXEC through bind and chmod")
    func boundListenerIsCloseOnExec() throws {
        try withTempPath { path in
            let descriptor = try MMService.makeBoundUnixSocket(path: path, mode: 0o600)
            defer { close(descriptor) }
            let flags = fcntl(descriptor, F_GETFD, 0)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC == FD_CLOEXEC)
        }
    }
}

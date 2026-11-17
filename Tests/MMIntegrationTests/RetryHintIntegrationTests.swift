#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#endif
import MMClient
import MMTestSupport
import MMWire
import NIOCore
import NIOPosix
import Testing

/// A failed connect names its cause from the errno the kernel gave, and the
/// cause's retry hint says whether connecting again can help.
@Suite("Retry hints of failed connects")
struct RetryHintIntegrationTests {
    /// Connects to `endpoint` and returns the bracket's failure.
    private func connectFailure(to endpoint: MMEndpoint) async throws -> MMClientError {
        let client = MMClient(endpoint: endpoint)
        let outcome = await client { _ in .success(()) }
        guard case .failure(let error) = outcome else {
            throw ConnectSucceeded()
        }
        return error
    }

    private struct ConnectSucceeded: Error {}

    @Test("a socket file nothing listens on is refused, and hints a later retry")
    func refusedSocketHintsLater() async throws {
        try await withTempSocketPath { path in
            try createDeadSocketFile(path: path)
            let error = try await connectFailure(to: .unix(path: path))
            guard case .transport(.refused, _) = error else {
                Issue.record("expected transport(refused), got \(error)")
                return
            }
            #expect(error.retryHint == .later)
        }
    }

    @Test("a missing socket file is socketMissing, and hints a later retry")
    func missingSocketHintsLater() async throws {
        try await withTempSocketPath { path in
            let error = try await connectFailure(to: .unix(path: path))
            guard case .transport(.socketMissing, _) = error else {
                Issue.record("expected transport(socketMissing), got \(error)")
                return
            }
            #expect(error.retryHint == .later)
        }
    }

    /// Root passes every permission check, so the case needs another user
    /// (the Linux container runs the suite as root).
    @Test(
        "a socket this user may not write is permissionDenied, and hints never",
        .enabled(if: geteuid() != 0, "root passes every permission check")
    )
    func permissionDeniedHintsNever() async throws {
        try await withTempSocketPath { path in
            try createDeadSocketFile(path: path)
            #expect(chmod(path, 0) == 0)
            let error = try await connectFailure(to: .unix(path: path))
            guard case .transport(.permissionDenied, _) = error else {
                Issue.record("expected transport(permissionDenied), got \(error)")
                return
            }
            #expect(error.retryHint == .never)
        }
    }

    @Test("a socket path longer than the platform allows is invalidAddress, and hints never")
    func overlongPathHintsNever() async throws {
        let path = "/tmp/" + String(repeating: "s", count: 200)
        let error = try await connectFailure(to: .unix(path: path))
        guard case .transport(.invalidAddress, _) = error else {
            Issue.record("expected transport(invalidAddress), got \(error)")
            return
        }
        #expect(error.retryHint == .never)
    }

    @Test("a TCP port nothing listens on is refused, through every address tried")
    func refusedPortHintsLater() async throws {
        // Bind an ephemeral port, then close it: nothing listens there now.
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(listener.localAddress?.port)
        try await listener.close()
        let error = try await connectFailure(to: .tcp(host: "127.0.0.1", port: port))
        guard case .transport(.refused, _) = error else {
            Issue.record("expected transport(refused), got \(error)")
            return
        }
        #expect(error.retryHint == .later)
    }
}

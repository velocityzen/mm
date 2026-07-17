import ArgumentParser
import MMClient
import MMSchema

/// Owns the connect → run → body → close lifecycle for one command
/// invocation, so generated commands contain only their call and rendering.
public enum MMCLIRunner {
    /// Connects to the endpoint the options describe, runs `body` against the
    /// live connection, and closes cleanly.
    ///
    /// The connection's inbound loop (`run()`) is a structured child for the
    /// whole of `body` — never a free-floating task. `body` errors (typically
    /// the `ExitCode` thrown by ``MMCLIFailure/unwrap(_:method:entity:)``)
    /// propagate after the connection is closed and the loop has drained. A
    /// connect failure renders a one-line hint to stderr and throws
    /// `ExitCode(69)` (EX_UNAVAILABLE).
    ///
    /// ## Automatic schema verification
    ///
    /// Verification is never manual; three layers, cheapest first:
    /// 1. An operator `--expect-fingerprint` pin is an identity gate —
    ///    mismatch refuses the invocation outright (exit 76).
    /// 2. An installed ``MMCLIServerContract`` completeness claim whose
    ///    folded fingerprint matches the hello proves every declared
    ///    namespace for free — no discovery round-trip.
    /// 3. Otherwise, when the command passes its `verifying:` contract
    ///    (every generated command does), the contract's namespace is
    ///    confirmed with one scoped discovery diff before dispatch: drift
    ///    prints the difference and exits 76. A *denied* discovery skips
    ///    with a note — verification is best-effort protection, and a peer
    ///    may hold call rights without read on the namespace entity.
    ///
    /// `--no-verify` skips layer 3 for one invocation.
    public static func invoke<T: Sendable>(
        _ options: MMCLIOptions,
        verifying contract: SchemaDeclaration? = nil,
        claim: MMCLIServerContract? = nil,
        _ body: @Sendable @escaping (MMClientConnection) async throws -> T
    ) async throws -> T {
        let endpoint = options.endpoint
        let connection: MMClientConnection
        switch await MMClientConnection.connect(
            to: endpoint,
            configuration: options.clientConfiguration
        ) {
            case .failure(let error):
                MMCLIOutput.note(
                    "connect failed: \(error) — is the daemon running at \(endpoint.cliDescription)?"
                )
                throw ExitCode(69)
            case .success(let connected):
                connection = connected
        }
        // An explicit operator pin is enforced, unlike the library's soft
        // fingerprint verdict: `--expect-fingerprint` plus a mismatch refuses
        // the invocation before a single call is dispatched. The library
        // itself never disconnects on mismatch — but a deployment pin the
        // operator spelled out is allowed to be hard (EX_PROTOCOL).
        if connection.helloInfo.fingerprintMatched == false {
            let served = String(connection.helloInfo.serverFingerprint, radix: 16)
            await connection.close()
            MMCLIOutput.note(
                "server schema fingerprint 0x\(served) does not match --expect-fingerprint")
            throw ExitCode(76)
        }
        // Layer 2: a matching completeness claim proves every declared
        // contract straight from the hello; anything else falls through to
        // the per-namespace diff.
        var provenByClaim = false
        if let installed = claim ?? MMCLIServerContract.current() {
            if connection.helloInfo.serverFingerprint == installed.expectedFingerprint {
                provenByClaim = true
            } else {
                let served = String(connection.helloInfo.serverFingerprint, radix: 16)
                MMCLIOutput.note(
                    "server composition differs from this build (0x\(served), expected \(installed.fingerprintHex)) — verifying the namespace in use"
                )
            }
        }
        let verifying = (provenByClaim || options.noVerify) ? nil : contract
        return try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { _ = await connection.run() }
            // Capture the body's outcome so close-and-drain happens on both
            // paths; the error (if any) propagates only after the connection
            // is down.
            let outcome: Result<T, any Error>
            do {
                if let verifying {
                    try await Self.verify(verifying, on: connection)
                }
                outcome = .success(try await body(connection))
            } catch {
                outcome = .failure(error)
            }
            await connection.close()
            try await tasks.waitForAll()
            return try outcome.get()
        }
    }

    /// Layer 3: the scoped discovery diff for one contract (see `invoke`).
    private static func verify(
        _ contract: SchemaDeclaration, on connection: MMClientConnection
    ) async throws {
        switch await connection.verifyContracts([contract]) {
            case .success(let differences):
                guard let difference = differences.first else { return }
                MMCLIOutput.note("\(contract.namespace): contract drift — \(difference)")
                throw ExitCode(76)
            case .failure(.denied):
                // A peer may hold call rights without read on the namespace
                // entity; verification never blocks what authorization allows.
                MMCLIOutput.note(
                    "schema verification skipped: discovery denied for \(contract.namespace)")
            case .failure(let error):
                throw MMCLIFailure.exit(
                    for: error, method: "rpc.schema", entity: contract.namespace)
        }
    }
}

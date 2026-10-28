import ArgumentParser
import FP
import FPBracket
import MMClient
import MMSchema

/// Owns the connection bracket for one command invocation, so generated
/// commands contain only their call and rendering.
public enum MMCLIRunner {
    /// Opens the connection the options describe, runs `body` against it, and
    /// closes it when `body` returns.
    ///
    /// The connection is an `MMClient` bracket: acquire connects and starts
    /// the inbound loop, dispose closes and joins it, so nothing outlives the
    /// invocation. `body` errors (typically the
    /// `ExitCode` thrown by ``MMCLIFailure/unwrap(_:method:entity:)``)
    /// propagate after the connection is closed and the loop has drained.
    /// Once `body` has run, its verdict is the command's: a connection that
    /// dies under it surfaces through its calls. A connect failure renders a
    /// one-line hint to stderr and throws `ExitCode(69)` (EX_UNAVAILABLE).
    ///
    /// ## Automatic schema verification
    ///
    /// Verification is never manual; two layers, cheapest first:
    /// 1. An installed ``MMCLIServerContract`` completeness claim whose
    ///    folded fingerprint matches the hello proves every declared
    ///    namespace for free — no discovery round-trip.
    /// 2. Otherwise, when the command passes its `verifying:` contract
    ///    (every generated command does), the contract's namespace is
    ///    confirmed with one scoped discovery diff before dispatch: drift
    ///    prints the difference and exits 76. A *denied* discovery skips
    ///    with a note — verification is best-effort protection, and a peer
    ///    may hold call rights without read on the namespace entity.
    ///
    /// `--no-verify` skips layer 2 for one invocation.
    public static func invoke<T: Sendable>(
        _ options: MMCLIOptions,
        verifying contract: SchemaDeclaration? = nil,
        claim: MMCLIServerContract? = nil,
        _ body: @Sendable @escaping (MMClientConnection) async throws -> T
    ) async throws -> T {
        let endpoint = options.endpoint
        let client = MMClient(endpoint: endpoint, configuration: options.clientConfiguration)
        // Set inside the bracket body, so `nil` afterwards means acquire
        // failed and the command never ran.
        var commandOutcome: Result<T, any Error>?
        let connectionOutcome = await client { connection in
            commandOutcome = await Result.fromAsync {
                try await Self.run(
                    body,
                    on: connection,
                    verifying: options.noVerify ? nil : contract,
                    claim: claim
                )
            }
            return .success(())
        }
        switch (commandOutcome, connectionOutcome) {
            case (let command?, _):
                return try command.get()
            case (nil, .failure(let error)):
                MMCLIOutput.note(
                    "connect failed: \(error) — is the daemon running at \(endpoint.cliDescription)?"
                )
                throw ExitCode(69)
            case (nil, .success):
                preconditionFailure("a bracket that released successfully ran its body")
        }
    }

    /// The command inside the bracket: verification, then `body`.
    private static func run<T: Sendable>(
        _ body: @Sendable (MMClientConnection) async throws -> T,
        on connection: MMClientConnection,
        verifying contract: SchemaDeclaration?,
        claim: MMCLIServerContract?
    ) async throws -> T {
        // Layer 1: a matching completeness claim proves every declared
        // contract straight from the hello; anything else falls through to
        // the per-namespace diff.
        var provenByClaim = false
        if let installed = claim ?? MMCLIServerContract.current() {
            if connection.server.fingerprint == installed.expectedFingerprint {
                provenByClaim = true
            } else {
                let served = fingerprintHexString(connection.server.fingerprint)
                MMCLIOutput.note(
                    "server composition differs from this build (\(served), expected \(installed.fingerprintHex)) — verifying the namespace in use"
                )
            }
        }
        if let contract, !provenByClaim {
            try await Self.verify(contract, on: connection)
        }
        return try await body(connection)
    }

    /// Layer 2: the scoped discovery diff for one contract (see `invoke`).
    private static func verify(
        _ contract: SchemaDeclaration, on connection: MMClientConnection
    ) async throws {
        // Shared `Types(...)` declarations come from the installed claim, when
        // there is one — the generated command only knows its own namespace.
        switch await connection.verifyContracts(
            [contract], sharing: MMCLIServerContract.current()?.sharedTypes ?? []
        ) {
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
                    for: error, method: "server.schema", entity: contract.namespace)
        }
    }
}

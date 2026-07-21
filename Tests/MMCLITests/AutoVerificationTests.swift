import MMSchema
import MMTestSupport
import Testing

@testable import MMCLI
@testable import MMClient

/// A contract the ledger server does not serve — one phantom method.
private let phantomContract = Schema("ledger") {
    Call("phantom") {
        Access { .read }
    }
}

/// A shared types-only container the ledger server registers via
/// `sharedTypes:` — the fixture for folding `Types(...)` into completeness
/// claims (a server registering shared containers folds their definitions
/// into its hello fingerprint).
private enum LedgerSharedTypes: TypeNamespace {
    static var types: [TypeDefinition] {
        [
            TypeDefinition(
                name: "shared.Badge",
                schema: .structure(fields: [.init(key: 0, name: "label", type: .string)])
            )
        ]
    }
}

/// The declaration twin of ``LedgerSharedTypes`` — what a client passes as
/// `sharedTypes:`.
private let ledgerSharedDeclaration = Types("shared") {
    Type("Badge") {
        Field("label", .string)
    }
}

/// The library-side automatic verification: `schema` in the client
/// configuration, verdict awaited via `verify()` — the embedding client's
/// twin of the CLI's claim + scoped-diff flow, against the same live ledger
/// server.
@Suite("Automatic schema verification (library client)")
struct AutoVerificationTests {
    private func verdict(
        options: MMCLIOptions,
        expectation: MMClientSchema?
    ) async throws -> Result<MMSchemaVerification, MMSchemaVerificationError> {
        let connection = try await MMClientConnection.connect(
            to: options.endpoint,
            configuration: MMClientConfiguration(schema: expectation)
        ).get()
        let (verdict, _) = try await withClientRunLoop(
            connection: connection, context: connection
        ) { connection in
            await connection.verify()
        }
        return verdict
    }

    @Test("a complete expectation is ok from the hello alone")
    func completeOK() async throws {
        try await withLedgerServer { options in
            let verdict = try await self.verdict(
                options: options, expectation: .complete([Ledger.contract]))
            guard case .success(.ok) = verdict else {
                Issue.record("expected .success(.ok), got \(verdict)")
                return
            }
        }
    }

    @Test("a complete claim over a Types(...) server hello-matches when sharedTypes are folded")
    func completeWithSharedTypes() async throws {
        try await withLedgerServer(sharedTypes: [LedgerSharedTypes.self]) { options in
            let verdict = try await self.verdict(
                options: options,
                expectation: .complete(
                    [Ledger.contract], sharedTypes: [ledgerSharedDeclaration]))
            guard case .success(.ok) = verdict else {
                Issue.record("expected .success(.ok), got \(verdict)")
                return
            }
        }
    }

    @Test("omitting sharedTypes from the claim degrades to the scoped diff, never a false verdict")
    func completeWithoutSharedTypesDegrades() async throws {
        try await withLedgerServer(sharedTypes: [LedgerSharedTypes.self]) { options in
            // The hello cannot match — the server folds shared.Badge — but
            // the ledger namespace is served compatibly, so the fallback
            // scoped diff is clean: .partial, never .ok and never a false
            // .difference.
            let verdict = try await self.verdict(
                options: options, expectation: .complete([Ledger.contract]))
            guard case .success(.partial) = verdict else {
                Issue.record("expected .success(.partial), got \(verdict)")
                return
            }
        }
    }

    @Test("a partial slice auto-verifies with one scoped diff; the hello carries no expectation")
    func partialSliceVerifies() async throws {
        try await withLedgerServer { options in
            let connection = try await MMClientConnection.connect(
                to: options.endpoint,
                configuration: MMClientConfiguration(
                    schema: .partial([Ledger.contract]))
            ).get()
            // A slice can never vouch for the whole composition: no hello
            // verdict, the scoped diff decides.
            #expect(connection.server.fingerprintMatched == nil)
            let (verdict, _) = try await withClientRunLoop(
                connection: connection, context: connection
            ) { connection in
                await connection.verify()
            }
            guard case .success(.partial) = verdict else {
                Issue.record("expected .success(.partial), got \(verdict)")
                return
            }
        }
    }

    @Test("a drifted slice reports the differences")
    func driftedSlice() async throws {
        try await withLedgerServer { options in
            let verdict = try await self.verdict(
                options: options, expectation: .partial([phantomContract]))
            guard case .success(.difference(let differences)) = verdict else {
                Issue.record("expected .success(.difference), got \(verdict)")
                return
            }
            #expect(!differences.isEmpty)
        }
    }

    @Test("a stale complete expectation falls back to the scoped diff")
    func staleCompleteFallsBack() async throws {
        try await withLedgerServer { options in
            // Folded for ledger + phantom, but the server serves only ledger:
            // the hello mismatches, the diff runs, and the phantom namespace
            // is what drifted.
            let verdict = try await self.verdict(
                options: options,
                expectation: .complete([Ledger.contract, phantomContract]))
            guard case .success(.difference(let differences)) = verdict else {
                Issue.record("expected .success(.difference), got \(verdict)")
                return
            }
            #expect(differences.count == 1)
        }
    }

    @Test("denied discovery is an error — never blocks what authorization allows")
    func deniedDiscovery() async throws {
        // -wx on ledger: calls stay authorized, the read discovery needs is
        // denied.
        try await withLedgerServer(ledgerMode: 0o300) { options in
            let verdict = try await self.verdict(
                options: options, expectation: .partial([Ledger.contract]))
            guard case .failure(.denied) = verdict else {
                Issue.record("expected .failure(.denied), got \(verdict)")
                return
            }
        }
    }

    @Test("no expectation is .failure(.noExpectation)")
    func noExpectation() async throws {
        try await withLedgerServer { options in
            let verdict = try await self.verdict(options: options, expectation: nil)
            guard case .failure(.noExpectation) = verdict else {
                Issue.record("expected .failure(.noExpectation), got \(verdict)")
                return
            }
        }
    }
}

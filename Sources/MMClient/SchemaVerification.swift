import MMSchema
import NIOConcurrencyHelpers

/// What this build knows about the server's schema — always contracts, never
/// a fingerprint an operator types. Set it on
/// ``MMClientConfiguration/schema`` and the connection verifies
/// itself: see ``MMClientConnection/verify()``.
public struct MMClientSchema: Sendable {
    /// The contracts this client was compiled against.
    public let contracts: [SchemaDeclaration]

    /// The folded whole-server hello expectation (contracts plus the
    /// builtins every server adds), or nil when `contracts` is only a slice
    /// of what the server serves — a slice can never vouch for the whole
    /// composition, so it carries no hello expectation.
    let serverFingerprint: UInt64?

    init(contracts: [SchemaDeclaration], serverFingerprint: UInt64?) {
        self.contracts = contracts
        self.serverFingerprint = serverFingerprint
    }

    /// This client knows the server's *complete* composition (it was built
    /// from the same set of contracts the server compiled). The expected
    /// hello fingerprint is folded here, at build time — a matching hello
    /// proves every namespace with zero discovery round-trips.
    public static func complete(_ contracts: [SchemaDeclaration]) -> Self {
        switch SchemaFingerprint.expected(serving: contracts) {
            case .success(let fingerprint):
                return MMClientSchema(
                    contracts: contracts,
                    serverFingerprint: fingerprint
                )

            case .failure(let error):
                // A contract that cannot fold is a build-time programmer
                // error (declarations validate at construction), same as
                // MMCLIServerContract.complete.
                preconditionFailure("MMClientSchema: schema probe failed: \(error)")
        }
    }

    /// This client uses a *slice* of the server. The hello fingerprint
    /// cannot vouch for a slice, so verification is one scoped discovery
    /// diff per contract, run automatically after connect.
    public static func partial(_ contracts: [SchemaDeclaration]) -> Self {
        MMClientSchema(contracts: contracts, serverFingerprint: nil)
    }
}

/// The verdict of automatic schema verification, awaited via
/// ``MMClientConnection/verify()``. Always informational — a difference
/// never closes the connection (the library's fixed soft-verdict rule);
/// acting on it belongs to the application.
public enum MMSchemaVerification: Sendable {
    /// The complete expectation's folded fingerprint matched the hello: the
    /// entire composition is proven without a discovery round-trip.
    case ok
    /// The scoped discovery diff ran clean for every declared contract, but
    /// the contracts vouch only for themselves: a partial slice by
    /// declaration, or a complete expectation whose hello mismatched (the
    /// composition changed somewhere else on the server).
    case partial
    /// At least one declared namespace differs; the differences say how.
    case difference([SchemaDifference])
}

/// Why automatic verification produced no verdict.
public enum MMSchemaVerificationError: Error, Sendable {
    /// ``MMClientConfiguration/schema`` was nil — nothing declared,
    /// nothing to verify.
    case noExpectation
    /// The scoped discovery was denied — a peer may hold call rights without
    /// read on the namespace entity, so authorized calls still proceed.
    case denied
    /// The discovery call failed (typically: the connection died first).
    case failed(MMCallError)
}

/// The replay-once verdict cell: resolves exactly once per connection, every
/// awaiter (early or late) observes the same value. Same discipline as a
/// stream's terminal cache.
final class SchemaVerificationCell: Sendable {
    typealias Verdict = Result<MMSchemaVerification, MMSchemaVerificationError>

    private enum State {
        case pending([CheckedContinuation<Verdict, Never>])
        case resolved(Verdict)
    }

    private let state = NIOLockedValueBox(State.pending([]))

    /// Resolves with a verification verdict. First resolution wins.
    func success(_ verification: MMSchemaVerification) {
        self.resolve(.success(verification))
    }

    /// Resolves with a no-verdict reason. First resolution wins.
    func failure(_ error: MMSchemaVerificationError) {
        self.resolve(.failure(error))
    }

    /// First resolution wins; later calls are no-ops (e.g. connection death
    /// after a verdict already landed).
    private func resolve(_ verdict: Verdict) {
        let awaiters = self.state.withLockedValue {
            state -> [CheckedContinuation<Verdict, Never>] in
            guard case .pending(let pending) = state else { return [] }
            state = .resolved(verdict)
            return pending
        }
        for awaiter in awaiters {
            awaiter.resume(returning: verdict)
        }
    }

    func value() async -> Verdict {
        await withCheckedContinuation { continuation in
            let cached = self.state.withLockedValue { state -> Verdict? in
                switch state {
                    case .resolved(let verdict):
                        return verdict
                    case .pending(var pending):
                        pending.append(continuation)
                        state = .pending(pending)
                        return nil
                }
            }

            if let cached {
                continuation.resume(returning: cached)
            }
        }
    }
}

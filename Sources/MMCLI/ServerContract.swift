import MMSchema

/// A companion CLI's build-time claim that the listed contracts are its
/// server's **entire** surface. Declare it once — ``Contract(_:)`` in the
/// ``MMCLI(isolation:_:)`` block — and
/// every invocation verifies the whole composition for free: the expected
/// hello fingerprint is folded from the contracts (builtins included), so a
/// matching hello proves every namespace — including the one being called —
/// with zero extra round-trips.
///
/// ```swift
/// await MMCLI {
///     Contract(.complete([journalContract]))
/// } run: {
///     await MM.main()
/// }
/// ```
///
/// Without a claim (or when the hello does not match one), generated commands
/// still verify automatically — each confirms its own namespace with a scoped
/// discovery diff before dispatching. The claim is an optimization and a
/// composition statement, never a requirement; nothing about verification is
/// manual either way.
public struct MMCLIServerContract: Sendable {
    public let contracts: [SchemaDeclaration]
    /// The shared `Types(...)` declarations the companion server registers —
    /// folded into ``expectedFingerprint`` and merged into scoped diffs (a
    /// shared definition a contract references is local, never drift).
    public let sharedTypes: [TypeNamespaceDeclaration]
    /// The folded whole-server hello fingerprint the claim expects.
    public let expectedFingerprint: UInt64

    /// Asserts completeness: these contracts (plus the builtins, plus any
    /// shared `Types(...)` declarations) are everything the companion server
    /// serves. A server registering shared containers can never hello-match
    /// a claim that omits them.
    public static func complete(
        _ contracts: [SchemaDeclaration],
        sharedTypes: [TypeNamespaceDeclaration] = []
    ) -> MMCLIServerContract {
        switch SchemaFingerprint.expected(serving: contracts, sharedTypes: sharedTypes) {
            case .success(let fingerprint):
                return MMCLIServerContract(
                    contracts: contracts,
                    sharedTypes: sharedTypes,
                    expectedFingerprint: fingerprint
                )
            case .failure(let error):
                preconditionFailure("MMCLIServerContract: schema probe failed: \(error)")
        }
    }

    /// The expected hello fingerprint, `0x`-prefixed — for release notes and
    /// deploy scripts, no connection required.
    public var fingerprintHex: String {
        fingerprintHexString(self.expectedFingerprint)
    }

    /// The bound claim, if the tool's `main()` provided one — sugar over
    /// ``MMCLIDefaults/current``.
    static func current() -> MMCLIServerContract? {
        MMCLIDefaults.current.serverContract
    }
}

/// The one spelling of a fingerprint for human eyes: `0x` + lowercase hex.
func fingerprintHexString(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16)
}

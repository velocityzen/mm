import MMSchema
import Synchronization

/// A companion CLI's build-time claim that the listed contracts are its
/// server's **entire** surface. Install it once at startup and every
/// invocation verifies the whole composition for free: the expected hello
/// fingerprint is folded from the contracts (builtins included), so a
/// matching hello proves every namespace — including the one being called —
/// with zero extra round-trips.
///
/// ```swift
/// @main
/// struct MM: AsyncParsableCommand {
///     static func main() async {
///         MMCLIServerContract.install(.complete([journalContract]))
///         // ... ArgumentParser custom-main pattern ...
///     }
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
    /// The folded whole-server hello fingerprint the claim expects.
    public let expectedFingerprint: UInt64

    /// Asserts completeness: these contracts (plus the builtins) are
    /// everything the companion server serves.
    public static func complete(_ contracts: [SchemaDeclaration]) -> MMCLIServerContract {
        switch SchemaFingerprint.expected(serving: contracts) {
            case .success(let fingerprint):
                return MMCLIServerContract(contracts: contracts, expectedFingerprint: fingerprint)
            case .failure(let error):
                preconditionFailure("MMCLIServerContract: schema probe failed: \(error)")
        }
    }

    /// The expected hello fingerprint, `0x`-prefixed — for release notes and
    /// deploy scripts, no connection required.
    public var fingerprintHex: String {
        fingerprintHexString(self.expectedFingerprint)
    }

    /// Installs the claim process-wide. Call once from `main()` before
    /// parsing; ``MMCLIRunner`` reads it on every invocation.
    public static func install(_ claim: MMCLIServerContract) {
        Self.installed.withLock { $0 = claim }
    }

    static func current() -> MMCLIServerContract? {
        Self.installed.withLock { $0 }
    }

    private static let installed = Mutex<MMCLIServerContract?>(nil)
}

/// The one spelling of a fingerprint for human eyes: `0x` + lowercase hex.
func fingerprintHexString(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16)
}

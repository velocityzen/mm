import ArgumentParser
import MMClient
import MMSchema

/// The generic discovery command: asks the connected server what it actually
/// serves (`server.schema`, filtered by this peer's traversal rights) and prints
/// the full `SchemaResponse` — fingerprint, method signatures, and named-type
/// definitions. `SchemaResponse` is `Codable` with named-`stringValue`
/// integer `CodingKeys`, so `JSONEncoder` prints named keys.
///
/// The hello's negotiated version and fingerprint verdict go to stderr as a
/// note, keeping stdout pure schema for scripts.
public struct MMCLIDiscover: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Fetches the schema a server actually serves."
    )

    @OptionGroup public var connection: MMCLIOptions

    @Argument(help: "Entity scope to discover under (dotted path; omit for the whole tree)")
    public var scope: String = ""

    public init() {}

    public func run() async throws {
        // Locals only inside the call closure: it is @Sendable, and
        // referencing a property would capture non-Sendable self.
        let scopeArgument = scope
        let target = try MMCLIFailure.entity(scopeArgument)  // "" parses to .root
        let format = connection.output
        let response = try await MMCLIRunner.invoke(connection) { client in
            let hello = client.server
            // The verdict comes from the build-time completeness claim when
            // one is installed — verification is never manual.
            let verdict: String
            if let claim = MMCLIServerContract.current() {
                verdict =
                    hello.fingerprint == claim.expectedFingerprint
                    ? " — matches this build's contracts"
                    : " — differs from this build's contracts (\(claim.fingerprintHex) expected)"
            } else {
                verdict = ""
            }
            MMCLIOutput.note(
                "hello: protocol v\(hello.protocolVersion), server fingerprint \(fingerprintHexString(hello.fingerprint))\(verdict)"
            )
            return try MMCLIFailure.unwrap(
                await client.discoverSchema(scope: target),
                method: "server.schema",
                entity: scopeArgument
            )
        }
        MMCLIOutput.emit(response, format: format)
    }
}

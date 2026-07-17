import ArgumentParser
import MMClient
import MMSchema

/// The namespace-scoped compatibility check behind the generated `verify`
/// subcommand: discovers the schema the server serves for the contract's
/// namespace and diffs it against the compiled declaration.
///
/// This is the build-time-derived check — the right one for a CLI compiled
/// from one namespace's contract. The hello fingerprint covers the server's
/// *whole* method set (every namespace plus the builtins), so it can never be
/// computed from one namespace at build time; pinning that whole-server value
/// is what `--expect-fingerprint` is for.
///
/// Like `diff`: "in sync" goes to stderr and the command exits 0; any
/// difference prints its buckets and exits 1.
public enum MMCLIVerify {
    public static func run(contract: SchemaDeclaration, options: MMCLIOptions) async throws {
        let verdict = try await MMCLIRunner.invoke(options) {
            client -> (inSync: Bool, description: String) in
            let scope = try MMCLIFailure.entity(contract.namespace)
            let response = try MMCLIFailure.unwrap(
                await client.discoverSchema(scope: scope),
                method: "rpc.schema", entity: contract.namespace)
            let difference = SchemaDifference(local: contract, remote: response)
            return (difference.isEmpty, "\(difference)")
        }
        MMCLIOutput.note(verdict.description)
        if !verdict.inSync {
            throw ExitCode(1)
        }
    }
}

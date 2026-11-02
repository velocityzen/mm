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
/// computed from one namespace at build time; proving that whole-server value
/// is what an installed ``MMCLIServerContract`` completeness claim is for.
///
/// Like `diff`: "in sync" goes to stderr and the command exits 0; any
/// difference prints its buckets and exits 1.
public enum MMCLIVerify {
    public static func run(contract: SchemaDeclaration, options: MMCLIOptions) async throws {
        try await MMCLIRunner.invoke(
            options,
            method: "server.schema",
            entity: contract.namespace
        ) { client in
            let differences = try MMCLIFailure.unwrap(
                await client.verifyContracts(
                    [contract],
                    sharing: MMCLIServerContract.current()?.sharedTypes ?? []
                ),
                method: "server.schema", entity: contract.namespace)
            guard let difference = differences.first else {
                MMCLIOutput.note("in sync")
                return
            }
            MMCLIOutput.note("\(difference)")
            throw ExitCode(1)
        }
    }
}

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
/// Like `diff`, it reports to stderr. "in sync" exits 0. A difference
/// prints its breaking part with a line for each break, then its compatible
/// part, and exits 1 when anything breaks, 0 when everything that changed
/// is compatible.
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
            if difference.isBreaking {
                MMCLIOutput.note("breaking: \(difference.breaking)")
                for reason in difference.breakingReasons {
                    MMCLIOutput.note("  \(reason)")
                }
            }
            if !difference.compatible.isEmpty {
                MMCLIOutput.note("compatible: \(difference.compatible)")
            }
            if difference.isBreaking { throw ExitCode(1) }
        }
    }
}

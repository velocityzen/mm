extension SchemaFingerprint {
    /// The hello fingerprint a server presents when it serves **exactly**
    /// these declared contracts — the builtins every server auto-registers
    /// included. The client-side twin of the router's boot-time fold, for
    /// tools (like generated CLIs) that know their companion server's
    /// complete composition and want the expected hello value at build time.
    ///
    /// Only meaningful as a completeness claim: folding one namespace of a
    /// three-namespace server produces a value that will simply never match.
    /// A tool that uses *part* of a server confirms its slice against
    /// discovery instead (`SchemaDifference`), scoped to its namespaces.
    /// (`compute` sorts canonically, so fold order never affects the value;
    /// the builtins seed the fold because every server serves them.)
    public static func expected(
        serving contracts: [SchemaDeclaration]
    ) -> Result<UInt64, SchemaError> {
        Builtins.all
            .reduce(Result<[MethodSignature], SchemaError>.success([])) { collected, builtin in
                collected.flatMap { signatures in
                    builtin.signature().map { signatures + [$0] }
                }
            }
            .map { builtins in
                contracts.reduce(
                    into: (signatures: builtins, types: [TypeDefinition]())
                ) { folded, contract in
                    folded.signatures.append(contentsOf: contract.signatures)
                    folded.types.append(contentsOf: contract.types)
                }
            }
            .map { folded in compute(folded.signatures, types: folded.types) }
    }
}

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
    public static func expected(
        serving contracts: [SchemaDeclaration]
    ) -> Result<UInt64, SchemaError> {
        var signatures: [MethodSignature] = []
        var types: [TypeDefinition] = []
        for contract in contracts {
            signatures.append(contentsOf: contract.signatures)
            types.append(contentsOf: contract.types)
        }
        for builtin in Builtins.all {
            switch builtin.signature() {
                case .success(let signature):
                    signatures.append(signature)
                case .failure(let error):
                    return .failure(error)
            }
        }
        return .success(compute(signatures, types: types))
    }
}

import MMSchema

extension MMClientConnection {
    /// Confirms declared contracts against the schema this server actually
    /// serves: one namespace-scoped discovery call per contract, each diffed
    /// description-stripped. Returns the non-empty differences — an empty
    /// array means every declared namespace is served compatibly.
    ///
    /// This is the check for a client that uses *part* of a server: the hello
    /// fingerprint covers the server's whole method set and cannot vouch for
    /// a slice, but a scoped diff can. Run it after the inbound loop is
    /// started (discovery rides the normal call path).
    ///
    /// `sharing` carries the server's shared `Types(...)` declarations: a
    /// shared definition a contract references is served by scoped discovery
    /// (reachability), so without the local twin it would falsely diff as a
    /// server-only type.
    public nonisolated func verifyContracts(
        _ contracts: [SchemaDeclaration],
        sharing sharedTypes: [TypeNamespaceDeclaration] = []
    ) async -> Result<[SchemaDifference], MMCallError> {
        var differences: [SchemaDifference] = []
        for contract in contracts {
            let scope: EntityName
            switch EntityName.parse(contract.namespace) {
                case .success(let parsed):
                    scope = parsed
                case .failure(let error):
                    // Unreachable: Schema(...) preconditions its namespace to
                    // be a valid non-root entity path at declaration time.
                    preconditionFailure(
                        "verifyContracts: contract namespace '\(contract.namespace)' is not an entity path: \(error)"
                    )
            }
            switch await self.discoverSchema(scope: scope) {
                case .failure(let error):
                    return .failure(error)
                case .success(let response):
                    let difference = SchemaDifference(
                        local: contract.signatures,
                        localTypes: contract.types(sharing: sharedTypes),
                        remote: response
                    )
                    if !difference.isEmpty {
                        differences.append(difference)
                    }
            }
        }
        return .success(differences)
    }
}

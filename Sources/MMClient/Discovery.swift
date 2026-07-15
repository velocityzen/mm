import MMSchema

extension MMClientConnection {
    /// Discovers the server's schema: the method signatures this peer can
    /// reach, plus the server's *unfiltered* schema fingerprint.
    ///
    /// This is a plain call to the builtin `rpc.schema` method
    /// (`Builtins.schema`) scoped to `EntityName.root`, riding the normal
    /// call path — msgid, in-flight cap, cancellation, and error mapping all
    /// apply. The response's `methods` list is filtered server-side by this
    /// peer's traversal rights (you discover what you can reach, nothing
    /// more), while `fingerprint` covers the server's *complete* method set,
    /// so it is directly comparable with ``HelloInfo/serverFingerprint``.
    ///
    /// ## Degrading deliberately on a fingerprint mismatch
    ///
    /// A fingerprint mismatch in the hello is never a disconnect — it is the
    /// trigger for discovery, so the application can decide what still works:
    ///
    /// ```swift
    /// if connection.helloInfo.fingerprintMatched == false {
    ///     switch await connection.discoverSchema() {
    ///     case .failure(let error):
    ///         // Discovery itself failed (transport, denial): treat as fatal
    ///         // or retry per application policy.
    ///         return .failure(.schemaUnavailable(error))
    ///     case .success(let remote):
    ///         let diff = SchemaDifference(local: MyAPI.localSignatures, remote: remote)
    ///         guard diff.missingMethods.isEmpty && diff.signatureChanged.isEmpty else {
    ///             // The methods this build depends on are gone or reshaped:
    ///             // disable the dependent features, keep the rest running.
    ///             return .success(.degraded(disabled: diff.missingMethods.map(\.name)))
    ///         }
    ///         // Only additions/permission changes: proceed at full function.
    ///         return .success(.full)
    ///     }
    /// }
    /// ```
    public nonisolated func discoverSchema(
        scope: EntityName = .root
    ) async -> Result<SchemaResponse, MMCallError> {
        await self.call(Builtins.schema, on: scope, SchemaRequest())
    }
}

/// The difference between the method signatures a client was compiled against
/// and the signatures a server actually serves — the decision input for
/// degrading deliberately after a schema-fingerprint mismatch (see
/// ``MMClientConnection/discoverSchema(scope:)``).
///
/// All four buckets are sorted by method name, so assertions and logs are
/// deterministic.
///
/// > Note: `rpc.schema` responses are filtered by the requesting peer's
/// > traversal rights. A method in ``missingMethods`` is therefore "absent
/// > *or invisible to this peer*" — from the client's point of view the two
/// > are equivalent (it cannot call the method either way), but the fix may
/// > be an ACL change rather than a deploy.
public struct SchemaDifference: Sendable, Hashable, CustomStringConvertible {
    /// A method present on both sides under one name, with the local and
    /// remote signatures side by side.
    public struct Change: Sendable, Hashable {
        public var local: MethodSignature
        public var remote: MethodSignature

        public init(local: MethodSignature, remote: MethodSignature) {
            self.local = local
            self.remote = remote
        }
    }

    /// A named type defined on both sides, with the local and remote
    /// definitions side by side.
    public struct TypeChange: Sendable, Hashable {
        public var local: TypeDefinition
        public var remote: TypeDefinition

        public init(local: TypeDefinition, remote: TypeDefinition) {
            self.local = local
            self.remote = remote
        }
    }

    /// Local methods the server does not serve (by name). Calls to these will
    /// fail with `MMCallError.unknownMethod` (or `.denied`, if the method
    /// exists but is invisible to this peer).
    public var missingMethods: [MethodSignature]
    /// Same name on both sides, different `AccessMode` — the verb now needs
    /// a different permission class on its target entity.
    public var accessChanged: [Change]
    /// Same name on both sides, different request, response, **or stream**
    /// `TypeSchema` (request stream / response stream) — payloads may no
    /// longer round-trip; new fields must be optional per the wire-evolution
    /// contract, so a signature change here means the contract moved underneath
    /// this build. A method that gained or lost a stream direction lands here
    /// too (one side's stream schema is `nil`). Descriptions never count.
    public var signatureChanged: [Change]
    /// Methods the server serves that this client has no descriptor for —
    /// harmless to this build, informative for upgrade planning.
    public var remoteOnly: [MethodSignature]
    /// Local named types the server does not define. Every method referencing
    /// one has an unresolvable schema server-side, so treat like
    /// ``missingMethods`` for the affected features.
    public var missingTypes: [TypeDefinition]
    /// Same qualified name on both sides, different shape (descriptions never
    /// count) — payloads carrying the type may no longer round-trip, exactly
    /// like ``signatureChanged``. Names are nominal: a *renamed* type shows up
    /// as missing + server-only instead, and every method referencing it lands
    /// in ``signatureChanged``.
    public var typeChanged: [TypeChange]
    /// Types the server defines that this build has no declaration for —
    /// harmless, informative for upgrade planning (often paired with
    /// ``remoteOnly`` methods).
    public var remoteOnlyTypes: [TypeDefinition]

    /// No differences at all.
    public var isEmpty: Bool {
        self.missingMethods.isEmpty && self.accessChanged.isEmpty
            && self.signatureChanged.isEmpty && self.remoteOnly.isEmpty
            && self.missingTypes.isEmpty && self.typeChanged.isEmpty
            && self.remoteOnlyTypes.isEmpty
    }

    /// A log-ready rendering: `"in sync"` when empty, otherwise the non-empty
    /// buckets with their method names —
    /// `missing: journal.append; access changed: box.get; server only: extra.new`
    /// — so call sites log the value directly instead of iterating buckets:
    ///
    /// ```swift
    /// logger.info("schema difference", metadata: ["diff": "\(difference)"])
    /// ```
    public var description: String {
        guard !self.isEmpty else { return "in sync" }
        var buckets: [String] = []
        if !self.missingMethods.isEmpty {
            buckets.append("missing: \(self.missingMethods.map(\.name).joined(separator: ", "))")
        }
        if !self.accessChanged.isEmpty {
            buckets.append(
                "access changed: \(self.accessChanged.map(\.local.name).joined(separator: ", "))")
        }
        if !self.signatureChanged.isEmpty {
            buckets.append(
                "signature changed: \(self.signatureChanged.map(\.local.name).joined(separator: ", "))"
            )
        }
        if !self.remoteOnly.isEmpty {
            buckets.append("server only: \(self.remoteOnly.map(\.name).joined(separator: ", "))")
        }
        if !self.missingTypes.isEmpty {
            buckets.append(
                "missing types: \(self.missingTypes.map(\.name).joined(separator: ", "))")
        }
        if !self.typeChanged.isEmpty {
            buckets.append(
                "types changed: \(self.typeChanged.map(\.local.name).joined(separator: ", "))")
        }
        if !self.remoteOnlyTypes.isEmpty {
            buckets.append(
                "server-only types: \(self.remoteOnlyTypes.map(\.name).joined(separator: ", "))")
        }
        return buckets.joined(separator: "; ")
    }

    /// Diffs a declared contract — signatures *and* named types — against a
    /// discovery response. The natural form when the contract is a
    /// `#schema`/`Schema` declaration.
    public init(local: SchemaDeclaration, remote: SchemaResponse) {
        self.init(local: local.signatures, localTypes: local.types, remote: remote)
    }

    /// Diffs the locally compiled signatures (and optionally the local type
    /// declarations) against a discovery response. Methods pair up by wire
    /// name; a method can appear in both ``accessChanged`` and
    /// ``signatureChanged`` when both moved. All comparisons are
    /// description-stripped — doc edits are never drift.
    public init(
        local: [MethodSignature],
        localTypes: [TypeDefinition] = [],
        remote: SchemaResponse
    ) {
        let remoteByName = Dictionary(
            remote.methods.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localNames = Set(local.map(\.name))
        var missing: [MethodSignature] = []
        var access: [Change] = []
        var signature: [Change] = []
        for localMethod in local.sorted(by: { $0.name < $1.name }) {
            guard let remoteMethod = remoteByName[localMethod.name] else {
                missing.append(localMethod)
                continue
            }
            if localMethod.access != remoteMethod.access {
                access.append(Change(local: localMethod, remote: remoteMethod))
            }
            let localStripped = localMethod.strippingDescriptions
            let remoteStripped = remoteMethod.strippingDescriptions
            if localStripped.request != remoteStripped.request
                || localStripped.response != remoteStripped.response
                || localStripped.requestStream != remoteStripped.requestStream
                || localStripped.responseStream != remoteStripped.responseStream
            {
                signature.append(Change(local: localMethod, remote: remoteMethod))
            }
        }
        self.missingMethods = missing
        self.accessChanged = access
        self.signatureChanged = signature
        self.remoteOnly =
            remote.methods
            .filter { !localNames.contains($0.name) }
            .sorted(by: { $0.name < $1.name })

        let remoteTypesByName = Dictionary(
            remote.types.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localTypeNames = Set(localTypes.map(\.name))
        var missingTypes: [TypeDefinition] = []
        var typeChanged: [TypeChange] = []
        for localType in localTypes.sorted(by: { $0.name < $1.name }) {
            guard let remoteType = remoteTypesByName[localType.name] else {
                missingTypes.append(localType)
                continue
            }
            if localType.strippingDescriptions.schema != remoteType.strippingDescriptions.schema {
                typeChanged.append(TypeChange(local: localType, remote: remoteType))
            }
        }
        self.missingTypes = missingTypes
        self.typeChanged = typeChanged
        self.remoteOnlyTypes =
            remote.types
            .filter { !localTypeNames.contains($0.name) }
            .sorted(by: { $0.name < $1.name })
    }
}

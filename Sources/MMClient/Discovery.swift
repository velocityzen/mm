import MMSchema

extension MMClientConnection {
    /// Discovers the server's schema: the method signatures this peer can
    /// reach, plus the server's *unfiltered* schema fingerprint.
    ///
    /// This is a plain call to the builtin `server.schema` method
    /// (`Builtins.schema`) scoped to `EntityName.root`, riding the normal
    /// call path — msgid, in-flight cap, cancellation, and error mapping all
    /// apply. The response's `methods` list is filtered server-side by this
    /// peer's traversal rights (you discover what you can reach, nothing
    /// more), while `fingerprint` covers the server's *complete* method set,
    /// so it is directly comparable with ``ServerInfo/fingerprint``.
    ///
    /// ## Degrading deliberately on a fingerprint mismatch
    ///
    /// A fingerprint mismatch in the hello is never a disconnect — it is the
    /// trigger for discovery. Set ``MMClientConfiguration/schema``
    /// and the connection runs this flow itself (await the verdict via
    /// ``MMClientConnection/verify()``); reach for the manual
    /// form below only when the application wants its own policy over the
    /// raw difference:
    ///
    /// ```swift
    /// if connection.server.fingerprintMatched == false {
    ///     switch await connection.discoverSchema() {
    ///     case .failure(let error):
    ///         // Discovery itself failed (transport, denial): treat as fatal
    ///         // or retry per application policy.
    ///         return .failure(.schemaUnavailable(error))
    ///     case .success(let remote):
    ///         let diff = SchemaDifference(local: MyAPI.contract, remote: remote)
    ///         guard !diff.isBreaking else {
    ///             // The methods this build depends on are gone or reshaped:
    ///             // disable the dependent features, keep the rest running.
    ///             let broken = diff.breaking
    ///             return .success(
    ///                 .degraded(disabled: (broken.missingMethods + broken.signatureChanged.map(\.local)).map(\.name)))
    ///         }
    ///         // Only compatible changes: proceed at full function.
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
/// All seven buckets are sorted by name, so assertions and logs are
/// deterministic.
///
/// Each change is judged too, and the difference splits into its
/// ``breaking`` part and its ``compatible`` part. A missing method or type
/// and a changed access break. A server-only method or type is compatible.
/// A changed signature or type is judged by what reads it: the server reads
/// requests and request-stream elements, the client reads responses,
/// response-stream elements and declared errors (see
/// ``MethodSignature/compatibility(client:clientTypes:server:serverTypes:)``
/// and ``TypeSchema/compatibility(reader:readerTypes:writer:writerTypes:)``).
/// So an added optional field, an added enumeration or union case, and a
/// field renamed with its key and type kept are compatible, and a changed
/// field type, a field the reader requires and the writer does not write,
/// a renamed case and a stream only one side declares break.
///
/// > Note: `server.schema` responses are filtered by the requesting peer's
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
        /// How this build's calls fare with the served method, access
        /// included: see
        /// ``MethodSignature/compatibility(client:clientTypes:server:serverTypes:)``.
        public var compatibility: SchemaCompatibility

        public init(
            local: MethodSignature,
            remote: MethodSignature,
            compatibility: SchemaCompatibility
        ) {
            self.local = local
            self.remote = remote
            self.compatibility = compatibility
        }
    }

    /// A named type defined on both sides, with the local and remote
    /// definitions side by side.
    public struct TypeChange: Sendable, Hashable {
        public var local: TypeDefinition
        public var remote: TypeDefinition
        /// Whether values of the type still read where this build's methods
        /// use it: the server reading the client's in requests and request
        /// streams, the client reading the server's in responses, response
        /// streams and errors, both ways for a type no method uses.
        public var compatibility: SchemaCompatibility

        public init(
            local: TypeDefinition,
            remote: TypeDefinition,
            compatibility: SchemaCompatibility
        ) {
            self.local = local
            self.remote = remote
            self.compatibility = compatibility
        }
    }

    /// Local methods the server does not serve (by name). Calls to these will
    /// fail with `MMCallError.unknownMethod` (or `.denied`, if the method
    /// exists but is invisible to this peer).
    public var missingMethods: [MethodSignature]
    /// Same name on both sides, different `AccessMode` — the verb now needs
    /// a different permission class on its target entity.
    public var accessChanged: [Change]
    /// Same name on both sides, different request, response, **stream**
    /// (request stream / response stream) **or declared errors** `TypeSchema`.
    /// A method that gained or lost a stream direction, or its declared
    /// errors, lands here too (one side's schema is `nil`). Descriptions
    /// never count. Each change's ``Change/compatibility`` says whether the
    /// payloads still read: an added optional field does, a changed field
    /// type does not.
    public var signatureChanged: [Change]
    /// Methods the server serves that this client has no descriptor for —
    /// harmless to this build, informative for upgrade planning.
    public var remoteOnly: [MethodSignature]
    /// Local named types the server does not define. Every method referencing
    /// one has an unresolvable schema server-side, so treat like
    /// ``missingMethods`` for the affected features.
    public var missingTypes: [TypeDefinition]
    /// Same qualified name on both sides, different shape or constraints
    /// (descriptions never count), judged like ``signatureChanged`` by
    /// ``TypeChange/compatibility``. Names are nominal: a *renamed* type
    /// shows up as missing + server-only instead, and every method
    /// referencing it lands in ``signatureChanged``.
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

    /// Whether anything in the difference breaks this build: a missing
    /// method or type, a changed access, or a signature or type change
    /// judged breaking.
    public var isBreaking: Bool {
        !self.breaking.isEmpty
    }

    /// The part of the difference that breaks this build: the missing
    /// methods and types, the changed access, and the signature and type
    /// changes judged breaking. Empty when everything that changed is
    /// compatible.
    public var breaking: SchemaDifference {
        SchemaDifference(
            missingMethods: self.missingMethods,
            accessChanged: self.accessChanged,
            signatureChanged: self.signatureChanged.filter(\.compatibility.isBreaking),
            remoteOnly: [],
            missingTypes: self.missingTypes,
            typeChanged: self.typeChanged.filter(\.compatibility.isBreaking),
            remoteOnlyTypes: []
        )
    }

    /// The part that does not break this build: the server-only methods
    /// and types, and the signature and type changes judged compatible.
    public var compatible: SchemaDifference {
        SchemaDifference(
            missingMethods: [],
            accessChanged: [],
            signatureChanged: self.signatureChanged.filter { !$0.compatibility.isBreaking },
            remoteOnly: self.remoteOnly,
            missingTypes: [],
            typeChanged: self.typeChanged.filter { !$0.compatibility.isBreaking },
            remoteOnlyTypes: self.remoteOnlyTypes
        )
    }

    /// Why each judged change breaks, one line each: the method's name and
    /// the break, `journal.get response.total: read as int, written as
    /// string`, or the type's break, `journal.Kind: renamed or replaced
    /// cases: reads "debit", writes "withdrawal"`. A method in both
    /// ``accessChanged`` and ``signatureChanged`` is listed once.
    public var breakingReasons: [String] {
        var reasons: [String] = []
        var listed: Set<String> = []
        for change in self.accessChanged + self.signatureChanged
        where listed.insert(change.local.name).inserted {
            reasons += change.compatibility.breaks.map { "\(change.local.name) \($0)" }
        }
        for change in self.typeChanged {
            reasons += change.compatibility.breaks.map(\.description)
        }
        return reasons
    }

    private init(
        missingMethods: [MethodSignature],
        accessChanged: [Change],
        signatureChanged: [Change],
        remoteOnly: [MethodSignature],
        missingTypes: [TypeDefinition],
        typeChanged: [TypeChange],
        remoteOnlyTypes: [TypeDefinition]
    ) {
        self.missingMethods = missingMethods
        self.accessChanged = accessChanged
        self.signatureChanged = signatureChanged
        self.remoteOnly = remoteOnly
        self.missingTypes = missingTypes
        self.typeChanged = typeChanged
        self.remoteOnlyTypes = remoteOnlyTypes
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
    /// description-stripped — doc edits are never drift. References in the
    /// local signatures resolve through `localTypes`, so pass the types the
    /// signatures name: a type only one side defines breaks a change that
    /// reaches it.
    public init(
        local: [MethodSignature],
        localTypes: [TypeDefinition] = [],
        remote: SchemaResponse
    ) {
        let localResolver = TypeResolver(localTypes)
        let remoteResolver = TypeResolver(remote.types)
        var access: [Change] = []
        var signature: [Change] = []
        let methods = Self.diffByName(
            local: local, remote: remote.methods, name: \.name
        ) { localMethod, remoteMethod in
            let localStripped = localMethod.strippingDescriptions
            let remoteStripped = remoteMethod.strippingDescriptions
            let accessMoved = localMethod.access != remoteMethod.access
            let signatureMoved =
                localStripped.request != remoteStripped.request
                || localStripped.response != remoteStripped.response
                || localStripped.requestStream != remoteStripped.requestStream
                || localStripped.responseStream != remoteStripped.responseStream
                || localStripped.errors != remoteStripped.errors
            guard accessMoved || signatureMoved else { return }
            let change = Change(
                local: localMethod,
                remote: remoteMethod,
                compatibility: MethodSignature.compatibility(
                    client: localMethod,
                    clientTypes: localResolver,
                    server: remoteMethod,
                    serverTypes: remoteResolver
                )
            )
            if accessMoved { access.append(change) }
            if signatureMoved { signature.append(change) }
        }
        self.missingMethods = methods.missing
        self.accessChanged = access
        self.signatureChanged = signature
        self.remoteOnly = methods.remoteOnly

        // The server reads the types this build's requests reach; the client
        // reads the ones its responses and errors reach.
        let serverRead = Self.reachableTypes(
            from: local.flatMap { [$0.request] + [$0.requestStream].compactMap { $0 } },
            through: localResolver
        )
        let clientRead = Self.reachableTypes(
            from: local.flatMap {
                [$0.response] + [$0.responseStream, $0.errors].compactMap { $0 }
            },
            through: localResolver
        )
        var typeChanged: [TypeChange] = []
        let types = Self.diffByName(
            local: localTypes, remote: remote.types, name: \.name
        ) { localType, remoteType in
            guard localType.strippingDescriptions != remoteType.strippingDescriptions else {
                return
            }
            let unused =
                !serverRead.contains(localType.name) && !clientRead.contains(localType.name)
            var breaks: [SchemaBreak] = []
            if unused || serverRead.contains(localType.name) {
                breaks +=
                    TypeDefinition.compatibility(
                        reader: remoteType,
                        readerTypes: remoteResolver,
                        writer: localType,
                        writerTypes: localResolver
                    ).breaks
            }
            if unused || clientRead.contains(localType.name) {
                for found in TypeDefinition.compatibility(
                    reader: localType,
                    readerTypes: localResolver,
                    writer: remoteType,
                    writerTypes: remoteResolver
                ).breaks where !breaks.contains(found) {
                    breaks.append(found)
                }
            }
            typeChanged.append(
                TypeChange(
                    local: localType,
                    remote: remoteType,
                    compatibility: SchemaCompatibility(breaks: breaks)
                )
            )
        }
        self.missingTypes = types.missing
        self.typeChanged = typeChanged
        self.remoteOnlyTypes = types.remoteOnly
    }

    /// Every type `schemas` name, and every type those name in turn.
    private static func reachableTypes(
        from schemas: [TypeSchema],
        through types: TypeResolver
    ) -> Set<String> {
        var reached: Set<String> = []
        var pending = schemas
        while let schema = pending.popLast() {
            var names: Set<String> = []
            schema.collectReferencedTypeNames(into: &names)
            for name in names where reached.insert(name).inserted {
                if let definition = types.definition(named: name) {
                    pending.append(definition.schema)
                }
            }
        }
        return reached
    }

    /// The one by-name diff pass, run for methods and for named types:
    /// name-sorted locals bucket into missing or a matched-pair visit;
    /// remote-only entries are name-sorted survivors.
    private static func diffByName<Element>(
        local: [Element],
        remote: [Element],
        name: (Element) -> String,
        matched: (Element, Element) -> Void
    ) -> (missing: [Element], remoteOnly: [Element]) {
        let remoteByName = Dictionary(
            remote.map { (name($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localNames = Set(local.map(name))
        var missing: [Element] = []
        for localElement in local.sorted(by: { name($0) < name($1) }) {
            guard let remoteElement = remoteByName[name(localElement)] else {
                missing.append(localElement)
                continue
            }
            matched(localElement, remoteElement)
        }
        let remoteOnly =
            remote
            .filter { !localNames.contains(name($0)) }
            .sorted(by: { name($0) < name($1) })
        return (missing, remoteOnly)
    }
}

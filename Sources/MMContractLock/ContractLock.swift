import MMClient
import MMSchema

/// A committed record of a wire contract, for a test that fails on a
/// breaking change.
///
/// A lock holds what a server built from the contract serves: its methods
/// and the named types they reach, with descriptions and deprecations
/// removed, since documentation is never part of the contract. Its file form
/// is JSON (``text``), so a change to the contract shows in review as a
/// change to the lock.
///
/// A peer built against the lock may still be running when the contract
/// changes, so ``difference(to:)`` judges the current contract the way
/// verification would judge it for that peer: the lock as the client, the
/// current contract as the server. ``check(_:sharedTypes:lockFile:relativeTo:)``
/// runs that judgment against a lock file from a test:
///
/// ```swift
/// @Test func journalKeepsItsContract() {
///     let check = ContractLock.check([journalContract], lockFile: "Locks/journal.json")
///     #expect(check.passed, "\(check)")
/// }
/// ```
public struct ContractLock: Sendable, Hashable {
    /// The locked methods: descriptions and deprecations removed, in name
    /// order.
    public let methods: [MethodSignature]
    /// The named types the lock holds: descriptions and deprecations
    /// removed, in name order.
    public let types: [TypeDefinition]

    /// Locks exactly `methods` and `types`, descriptions and deprecations
    /// removed, and each target in its normalized form, since stripping
    /// rebuilds a signature. Use it for signatures that do not come from a
    /// ``SchemaDeclaration``; ``init(_:sharedTypes:)`` locks a contract.
    public init(methods: [MethodSignature], types: [TypeDefinition] = []) {
        self.methods = Self.ordered(
            methods.map(\.strippingDescriptions),
            name: \.name,
            form: { LockText.form(of: LockedMethod($0)) }
        )
        self.types = Self.ordered(
            types.map(\.strippingDescriptions),
            name: \.name,
            form: { LockText.form(of: LockedType($0)) }
        )
    }

    /// Locks what a server serving `contracts` serves: every method they
    /// declare, and the named types those methods reach, through the
    /// contracts' own types and then `sharedTypes`. A declared type no
    /// method reaches is never served, so it is not locked.
    public init(
        _ contracts: [SchemaDeclaration],
        sharedTypes: [TypeNamespaceDeclaration] = []
    ) {
        let methods = contracts.flatMap(\.signatures)
        self.init(
            methods: methods,
            types: Self.reached(
                from: methods,
                among: contracts.flatMap(\.types) + sharedTypes.flatMap(\.types)
            )
        )
    }

    /// The schema fingerprint of the locked methods and types.
    public var fingerprint: UInt64 {
        SchemaFingerprint.compute(self.methods, types: self.types)
    }

    /// How a peer built against this lock fares with a server built from
    /// `current`: the lock is the client and `current` the server, as in
    /// ``SchemaDifference/init(local:localTypes:remote:)``. A method or type
    /// the lock has and `current` lacks breaks, and so does a change the
    /// lock's side cannot read; a method or type only `current` has, and a
    /// change the lock's side reads, are compatible.
    public func difference(to current: ContractLock) -> SchemaDifference {
        SchemaDifference(
            local: self.methods,
            localTypes: self.types,
            remote: SchemaResponse(
                fingerprint: current.fingerprint,
                methods: current.methods,
                types: current.types
            )
        )
    }

    /// The definitions `methods` reach, directly or through other
    /// definitions, each name once, the first definition of a name standing
    /// for it.
    static func reached(
        from methods: [MethodSignature],
        among definitions: [TypeDefinition]
    ) -> [TypeDefinition] {
        let definitionsByName = Dictionary(
            definitions.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var names: Set<String> = []
        for method in methods { method.collectReferencedTypeNames(into: &names) }
        var pending = Array(names)
        var reached: [TypeDefinition] = []
        var visited: Set<String> = []
        while let name = pending.popLast() {
            guard visited.insert(name).inserted, let definition = definitionsByName[name] else {
                continue
            }
            reached.append(definition)
            var referenced: Set<String> = []
            definition.schema.collectReferencedTypeNames(into: &referenced)
            pending += referenced
        }
        return reached
    }

    /// `elements` in name order, elements of one name in the order of their
    /// file form, so the lock's text never depends on declaration order.
    static func ordered<Element>(
        _ elements: [Element],
        name: (Element) -> String,
        form: (Element) -> String
    ) -> [Element] {
        elements
            .map { (name: name($0), form: form($0), element: $0) }
            .sorted {
                $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
                    || ($0.name.utf8.elementsEqual($1.name.utf8)
                        && $0.form.utf8.lexicographicallyPrecedes($1.form.utf8))
            }
            .map(\.element)
    }
}

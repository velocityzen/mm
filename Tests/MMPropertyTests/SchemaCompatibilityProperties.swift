// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMCLI
    import MMSchema
    import MMWire
    import Testing

    /// One step from a schema position into a position it holds: an
    /// optional's wrapped schema, an array's element, a map's key or value,
    /// a structure's field, or a union's case.
    enum SchemaStep: Hashable, Sendable {
        case wrapped, element, key, value
        case field(Int)
        case unionCase(Int)
    }

    /// A position in a schema or in one of its named types, with the path
    /// the compatibility judge names it by.
    struct SchemaSite: Sendable {
        /// The named type the position is in, by index, or nil for the root.
        var definition: Int?
        var steps: [SchemaStep]
        var path: String
        /// Whether the position is in a union case's fields, or under one.
        var inUnionCase = false
        /// Whether the position is a union case's own fields.
        var isUnionCase = false
    }

    /// A field of a structure or a union case.
    struct FieldSite: Sendable {
        /// The fields the field is one of.
        var list: SchemaSite
        var index: Int
        var field: TypeSchema.Field
        var path: String

        /// The position of the field's type.
        var type: SchemaSite {
            SchemaSite(
                definition: self.list.definition,
                steps: self.list.steps + [.field(self.index)],
                path: self.path,
                inUnionCase: self.list.inUnionCase
            )
        }
    }

    /// A schema and the named types its references resolve through: one
    /// side of a comparison.
    struct SchemaSide: Sendable {
        var schema: TypeSchema
        var definitions: [TypeDefinition]

        var resolver: TypeResolver { TypeResolver(self.definitions) }

        /// The index of the definition a reference to `name` resolves to:
        /// the first of that name.
        func definitionIndex(named name: String) -> Int? {
            self.definitions.firstIndex { $0.name == name }
        }
    }

    /// The positions the judge meets walking from the root, a named type's
    /// at its first meeting, in the order the judge meets them.
    struct ReachableSites {
        /// Structures and union cases: where a field can go.
        var fieldLists: [SchemaSite] = []
        var fields: [FieldSite] = []
        var enumerations: [SchemaSite] = []
        var unions: [SchemaSite] = []
        /// Every position a schema stands at below the root: a field's
        /// type, an array's element, a map's key and value.
        var positions: [TypePosition] = []
        /// Whether a named type is met inside itself.
        var recursive = false
        var references = 0

        /// The positions from the root, which the judge names `root`: empty
        /// for a schema, a call's part for a call.
        init(_ side: SchemaSide, root: String = "") {
            var visited: Set<String> = []
            self.walk(
                side.schema,
                side: side,
                at: SchemaSite(definition: nil, steps: [], path: root),
                open: [],
                visited: &visited
            )
        }

        private mutating func walk(
            _ schema: TypeSchema,
            side: SchemaSide,
            at site: SchemaSite,
            open: [String],
            visited: inout Set<String>
        ) {
            func into(_ step: SchemaStep, _ suffix: String) -> SchemaSite {
                SchemaSite(
                    definition: site.definition,
                    steps: site.steps + [step],
                    path: site.path + suffix,
                    inUnionCase: site.inUnionCase
                )
            }
            switch schema {
                case .optional(let wrapped):
                    self.walk(
                        wrapped,
                        side: side,
                        at: into(.wrapped, ""),
                        open: open,
                        visited: &visited
                    )
                case .array(let element):
                    let elementSite = into(.element, "[]")
                    self.positions.append(
                        TypePosition(site: elementSite, schema: element, role: .element)
                    )
                    self.walk(element, side: side, at: elementSite, open: open, visited: &visited)
                case .map(let key, let value):
                    let keySite = into(.key, "[key]")
                    let valueSite = into(.value, "[value]")
                    self.positions.append(TypePosition(site: keySite, schema: key, role: .key))
                    self.positions.append(
                        TypePosition(site: valueSite, schema: value, role: .value)
                    )
                    self.walk(key, side: side, at: keySite, open: open, visited: &visited)
                    self.walk(value, side: side, at: valueSite, open: open, visited: &visited)
                case .structure(let fields):
                    self.list(fields, side: side, at: site, open: open, visited: &visited)
                case .enumeration:
                    self.enumerations.append(site)
                case .union(let cases):
                    self.unions.append(site)
                    for (index, unionCase) in cases.enumerated() {
                        var caseSite = into(.unionCase(index), "(\(unionCase.name))")
                        caseSite.inUnionCase = true
                        caseSite.isUnionCase = true
                        self.list(
                            unionCase.fields,
                            side: side,
                            at: caseSite,
                            open: open,
                            visited: &visited
                        )
                    }
                case .reference(let name):
                    self.references += 1
                    if open.contains(name) {
                        self.recursive = true
                        return
                    }
                    guard let index = side.definitionIndex(named: name),
                        visited.insert(name).inserted
                    else { return }
                    self.walk(
                        side.definitions[index].schema,
                        side: side,
                        at: SchemaSite(
                            definition: index,
                            steps: [],
                            path: site.path,
                            inUnionCase: site.inUnionCase
                        ),
                        open: open + [name],
                        visited: &visited
                    )
                default:
                    break
            }
        }

        private mutating func list(
            _ fields: [TypeSchema.Field],
            side: SchemaSide,
            at site: SchemaSite,
            open: [String],
            visited: inout Set<String>
        ) {
            self.fieldLists.append(site)
            for (index, field) in fields.enumerated() {
                let found = FieldSite(
                    list: site,
                    index: index,
                    field: field,
                    path: site.path.isEmpty ? field.name : "\(site.path).\(field.name)"
                )
                self.fields.append(found)
                self.positions.append(
                    TypePosition(site: found.type, schema: field.type, role: .field)
                )
                self.walk(field.type, side: side, at: found.type, open: open, visited: &visited)
            }
        }
    }

    /// A position a schema stands at, with what stands there.
    struct TypePosition: Sendable {
        enum Role: String, Sendable, CaseIterable {
            case field = "a field"
            case element = "an array's element"
            case key = "a map's key"
            case value = "a map's value"
        }

        var site: SchemaSite
        var schema: TypeSchema
        var role: Role
    }

    /// A change to one position: the schema there, or the fields there.
    enum SchemaRewrite {
        case node((TypeSchema) -> TypeSchema)
        case fields(([TypeSchema.Field]) -> [TypeSchema.Field])
    }

    extension SchemaSide {
        /// The fields at `site`: a structure's, or a union case's.
        func fields(at site: SchemaSite) -> [TypeSchema.Field] {
            switch self.found(at: site) {
                case .fields(let fields)?: fields
                case .schema(.structure(let fields))?: fields
                default: []
            }
        }

        /// The schema at `site`, or nil when a union case's fields are there.
        func schema(at site: SchemaSite) -> TypeSchema? {
            if case .schema(let schema)? = self.found(at: site) { return schema }
            return nil
        }

        private enum Found {
            case schema(TypeSchema)
            case fields([TypeSchema.Field])
        }

        private func found(at site: SchemaSite) -> Found? {
            var found = Found.schema(
                site.definition.map { self.definitions[$0].schema } ?? self.schema
            )
            for step in site.steps {
                switch (step, found) {
                    case (.wrapped, .schema(.optional(let wrapped))): found = .schema(wrapped)
                    case (.element, .schema(.array(let element))): found = .schema(element)
                    case (.key, .schema(.map(let key, _))): found = .schema(key)
                    case (.value, .schema(.map(_, let value))): found = .schema(value)
                    case (.field(let index), .schema(.structure(let fields))):
                        found = .schema(fields[index].type)
                    case (.field(let index), .fields(let fields)):
                        found = .schema(fields[index].type)
                    case (.unionCase(let index), .schema(.union(let cases))):
                        found = .fields(cases[index].fields)
                    default: return nil
                }
            }
            return found
        }

        /// This side with the position at `site` rewritten.
        func rewriting(_ site: SchemaSite, _ rewrite: SchemaRewrite) -> SchemaSide {
            var side = self
            if let index = site.definition {
                side.definitions[index].schema = Self.rewrite(
                    side.definitions[index].schema,
                    site.steps[...],
                    rewrite
                )
            } else {
                side.schema = Self.rewrite(side.schema, site.steps[...], rewrite)
            }
            return side
        }

        private static func rewrite(
            _ schema: TypeSchema,
            _ steps: ArraySlice<SchemaStep>,
            _ rewrite: SchemaRewrite
        ) -> TypeSchema {
            guard let step = steps.first else {
                switch (rewrite, schema) {
                    case (.node(let change), _): return change(schema)
                    case (.fields(let change), .structure(let fields)):
                        return .structure(fields: change(fields))
                    case (.fields, _): return schema
                }
            }
            let rest = steps.dropFirst()
            switch (step, schema) {
                case (.wrapped, .optional(let wrapped)):
                    return .optional(Self.rewrite(wrapped, rest, rewrite))
                case (.element, .array(let element)):
                    return .array(Self.rewrite(element, rest, rewrite))
                case (.key, .map(let key, let value)):
                    return .map(key: Self.rewrite(key, rest, rewrite), value: value)
                case (.value, .map(let key, let value)):
                    return .map(key: key, value: Self.rewrite(value, rest, rewrite))
                case (.field, .structure(let fields)):
                    return .structure(fields: Self.rewriteFields(fields, steps, rewrite))
                case (.unionCase(let index), .union(var cases)):
                    cases[index].fields = Self.rewriteFields(cases[index].fields, rest, rewrite)
                    return .union(cases: cases)
                default:
                    return schema
            }
        }

        private static func rewriteFields(
            _ fields: [TypeSchema.Field],
            _ steps: ArraySlice<SchemaStep>,
            _ rewrite: SchemaRewrite
        ) -> [TypeSchema.Field] {
            guard let step = steps.first else {
                if case .fields(let change) = rewrite { return change(fields) }
                return fields
            }
            guard case .field(let index) = step else { return fields }
            var fields = fields
            fields[index].type = Self.rewrite(fields[index].type, steps.dropFirst(), rewrite)
            return fields
        }

        /// The kind `schema` holds once references are followed and
        /// optionals unwrapped, in words.
        func coreKind(of schema: TypeSchema) -> String {
            var current = schema
            var followed = 0
            while true {
                switch current {
                    case .optional(let wrapped): current = wrapped
                    case .reference(let name):
                        guard let index = self.definitionIndex(named: name) else {
                            return "undefined"
                        }
                        // More references than names: one of them loops.
                        guard followed <= self.definitions.count else { return "a loop" }
                        followed += 1
                        current = self.definitions[index].schema
                    default: return kindName(current)
                }
            }
        }
    }

    /// A kind in words.
    func kindName(_ schema: TypeSchema) -> String {
        switch schema {
            case .bool: "bool"
            case .int: "int"
            case .uint: "uint"
            case .float: "float"
            case .double: "double"
            case .string: "string"
            case .bytes: "bytes"
            case .date: "date"
            case .datetime: "datetime"
            case .timestamp: "timestamp"
            case .duration: "duration"
            case .uuid: "uuid"
            case .optional: "optional"
            case .array: "array"
            case .map: "map"
            case .structure: "structure"
            case .enumeration: "enumeration"
            case .union: "union"
            case .reference: "reference"
            case .unknown: "unknown"
        }
    }

    enum CompatibilityGenerators {
        static let leaves: [TypeSchema] = [
            .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime, .timestamp,
            .duration, .uuid,
        ]

        /// Schemas to give a field: every leaf, a composite of each kind,
        /// and a reference to each of the side's named types.
        static func fieldTypes(for side: SchemaSide, unknownSlots: Bool) -> [TypeSchema] {
            Self.leaves + (unknownSlots ? [.unknown] : []) + [
                .array(.int), .map(key: .string, value: .bool), .structure(fields: []),
                .structure(fields: [TypeSchema.Field(key: 0, name: "inner", type: .string)]),
                .enumeration(cases: [TypeSchema.EnumCase(name: "only")]),
                .union(cases: [TypeSchema.UnionCase(name: "only")]),
            ] + Array(Set(side.definitions.map(\.name))).sorted().map { .reference($0) }
        }

        /// A name none of `taken` is, from the generators' pool, and with
        /// `numerals` false never one that reads as an integer.
        static func freshName(
            _ tc: TestCase,
            avoiding taken: [String],
            numerals: Bool = true
        ) throws -> String {
            var name = try tc.draw(SchemaValueGenerators.names)
            while taken.contains(name) || (!numerals && !Self.travelsByKey(name)) { name += "'" }
            return name
        }

        /// Whether a keyed field named `name` travels by its key through
        /// the dynamic coders, as every field of generated code does: a
        /// name that reads as an integer travels as a string key instead
        /// (the faithful-int-key rule), and generated code, whose names
        /// are Swift identifiers, never has one.
        static func travelsByKey(_ name: String) -> Bool {
            Int(name) == nil
        }

        /// A field with an identity none of `fields` has: the next integer
        /// key when they have keys, or a new name when they have none, or
        /// either for no fields.
        static func freshField(
            _ tc: TestCase,
            among fields: [TypeSchema.Field],
            type: TypeSchema,
            numerals: Bool = true
        ) throws -> TypeSchema.Field {
            let keys = fields.compactMap(\.key)
            let keyed = fields.isEmpty ? try tc.draw(.bool()) : !keys.isEmpty
            let key: Int? =
                keyed
                ? (keys.max().map { $0 == .max ? keys.min()! - 1 : $0 + 1 } ?? 0)
                : nil
            return TypeSchema.Field(
                key: key,
                name: try Self.freshName(tc, avoiding: fields.map(\.name), numerals: numerals),
                type: type
            )
        }

        /// A fitting writer under a drawn policy, its root a structure, as
        /// a request's and a response's are.
        ///
        /// Leaning on a composite kind makes it one the schema may hold,
        /// below a root deep enough to hold it, for a property whose
        /// positions of interest an unleaning policy reaches in only a few
        /// percent of its cases.
        static func structureFitting(
            _ tc: TestCase,
            unknownSlots: Bool,
            leaning lean: CompositeKind? = nil
        ) throws -> FittingValue {
            var policy = try tc.draw(SchemaValueGenerators.policies(unknownSlots: unknownSlots))
            policy.structureRoot = true
            if let focus = try tc.draw(
                Gen<SchemaValueFocus?>.element(of: [nil, nil, .references, .maps, .arrays])
            ) {
                policy.focus(on: focus)
            }
            if let lean {
                if !policy.composites.contains(lean) { policy.composites.append(lean) }
                policy.schemaDepth = max(policy.schemaDepth, 2)
            }
            return try tc.draw(SchemaValueGenerators.fitting(policy))
        }
    }

    /// How the soundness property changes the reader, one position at a
    /// time. A name an edit gives a field is never a numeral, as no
    /// generated field's is: the dynamic coders send a keyed field with a
    /// numeral name by that name, so a reader's new field named like it
    /// would find it.
    enum ReaderEdit: String, CaseIterable, Sendable {
        case addOptionalField = "an optional field added"
        case addRequiredField = "a required field added"
        case removeField = "a field removed"
        case renameField = "a field renamed"
        case rekeyField = "a field given another key"
        case changeFieldType = "a field's type changed"
        case makeFieldOptional = "a field made optional"
        case makeFieldRequired = "an optional field made required"
        case addEnumerationCase = "an enumeration case added"
        case removeEnumerationCase = "an enumeration case removed"
        case renameEnumerationCase = "an enumeration case renamed"
        case addUnionCase = "a union case added"
        case removeUnionCase = "a union case removed"
        case renameUnionCase = "a union case renamed"

        /// What an edit changes: fields, or an enumeration's or a union's
        /// cases.
        enum Family: Sendable {
            case fields, enumerations, unions

            /// The composite kind a schema leans on for the family.
            var composite: CompositeKind? {
                switch self {
                    case .fields: nil
                    case .enumerations: .enumeration
                    case .unions: .union
                }
            }
        }

        var family: Family {
            switch self {
                case .addEnumerationCase, .removeEnumerationCase, .renameEnumerationCase:
                    .enumerations
                case .addUnionCase, .removeUnionCase, .renameUnionCase: .unions
                default: .fields
            }
        }

        /// Whether `sites` hold a position the edit applies to.
        func applies(to sites: ReachableSites) -> Bool {
            switch self {
                case .addOptionalField, .addRequiredField: !sites.fieldLists.isEmpty
                case .removeField, .changeFieldType, .makeFieldOptional:
                    !sites.fields.isEmpty
                case .renameField: !Self.sentAsDeclared(sites.fields).isEmpty
                case .rekeyField: Self.sentAsDeclared(sites.fields).contains { $0.field.key != nil }
                case .makeFieldRequired:
                    sites.fields.contains {
                        if case .optional = $0.field.type { true } else { false }
                    }
                case .addEnumerationCase, .removeEnumerationCase, .renameEnumerationCase:
                    !sites.enumerations.isEmpty
                case .addUnionCase, .removeUnionCase, .renameUnionCase: !sites.unions.isEmpty
            }
        }

        /// The fields a rename or a new key keeps to the soundness oracle's
        /// domain: the dynamic coders send each as generated code does, a
        /// keyed one by its key.
        static func sentAsDeclared(_ fields: [FieldSite]) -> [FieldSite] {
            fields.filter {
                $0.field.key == nil || CompatibilityGenerators.travelsByKey($0.field.name)
            }
        }

        /// The edit applied to `side` at a drawn position.
        func applied(_ tc: TestCase, to side: SchemaSide, sites: ReachableSites) throws
            -> SchemaSide
        {
            let types = CompatibilityGenerators.fieldTypes(for: side, unknownSlots: false)
            switch self {
                case .addOptionalField, .addRequiredField:
                    let list = try tc.draw(.element(of: sites.fieldLists))
                    let type = try tc.draw(.element(of: types))
                    let field = try CompatibilityGenerators.freshField(
                        tc,
                        among: side.fields(at: list),
                        type: self == .addOptionalField ? .optional(type) : type,
                        numerals: false
                    )
                    return side.rewriting(list, .fields { $0 + [field] })
                case .removeField:
                    let target = try tc.draw(.element(of: sites.fields))
                    return side.rewriting(
                        target.list,
                        .fields {
                            $0.enumerated().filter { $0.offset != target.index }.map(\.element)
                        }
                    )
                case .renameField:
                    let target = try tc.draw(.element(of: Self.sentAsDeclared(sites.fields)))
                    // A field's name is one no other field of its list has.
                    let name = try CompatibilityGenerators.freshName(
                        tc,
                        avoiding: side.fields(at: target.list).map(\.name),
                        numerals: false
                    )
                    return side.rewriting(
                        target.list,
                        .fields { fields in
                            var fields = fields
                            fields[target.index].name = name
                            return fields
                        }
                    )
                case .rekeyField:
                    let target = try tc.draw(
                        .element(
                            of: Self.sentAsDeclared(sites.fields).filter { $0.field.key != nil }
                        )
                    )
                    return side.rewriting(
                        target.list,
                        .fields { fields in
                            var fields = fields
                            let keys = fields.compactMap(\.key)
                            fields[target.index].key =
                                keys.max()! == .max ? keys.min()! - 1 : keys.max()! + 1
                            return fields
                        }
                    )
                case .changeFieldType:
                    let target = try tc.draw(.element(of: sites.fields))
                    let type = try tc.draw(.element(of: types))
                    return side.rewriting(target.type, .node { _ in type })
                case .makeFieldOptional:
                    let target = try tc.draw(.element(of: sites.fields))
                    return side.rewriting(target.type, .node { .optional($0) })
                case .makeFieldRequired:
                    let target = try tc.draw(
                        .element(
                            of: sites.fields.filter {
                                if case .optional = $0.field.type { true } else { false }
                            }
                        )
                    )
                    return side.rewriting(
                        target.type,
                        .node { if case .optional(let wrapped) = $0 { wrapped } else { $0 } }
                    )
                case .addEnumerationCase, .removeEnumerationCase, .renameEnumerationCase:
                    let site = try tc.draw(.element(of: sites.enumerations))
                    let position = try tc.draw(.int(in: 0...7))
                    let fresh = try CompatibilityGenerators.freshName(tc, avoiding: [])
                    let edit = self
                    return side.rewriting(
                        site,
                        .node { node in
                            guard case .enumeration(var cases) = node else { return node }
                            var name = fresh
                            while cases.contains(where: { $0.name == name }) { name += "'" }
                            switch edit {
                                case .addEnumerationCase:
                                    cases.insert(
                                        TypeSchema.EnumCase(name: name),
                                        at: position % (cases.count + 1)
                                    )
                                case .removeEnumerationCase where !cases.isEmpty:
                                    cases.remove(at: position % cases.count)
                                case .renameEnumerationCase where !cases.isEmpty:
                                    cases[position % cases.count].name = name
                                default:
                                    break
                            }
                            return .enumeration(cases: cases)
                        }
                    )
                case .addUnionCase, .removeUnionCase, .renameUnionCase:
                    let site = try tc.draw(.element(of: sites.unions))
                    let position = try tc.draw(.int(in: 0...7))
                    let fresh = try CompatibilityGenerators.freshName(tc, avoiding: [])
                    let fields =
                        try tc.draw(.bool())
                        ? [TypeSchema.Field(key: 0, name: "since", type: .optional(.timestamp))]
                        : []
                    let edit = self
                    return side.rewriting(
                        site,
                        .node { node in
                            guard case .union(var cases) = node else { return node }
                            var name = fresh
                            while cases.contains(where: { $0.name == name }) { name += "'" }
                            switch edit {
                                case .addUnionCase:
                                    cases.insert(
                                        TypeSchema.UnionCase(name: name, fields: fields),
                                        at: position % (cases.count + 1)
                                    )
                                case .removeUnionCase where !cases.isEmpty:
                                    cases.remove(at: position % cases.count)
                                case .renameUnionCase where !cases.isEmpty:
                                    cases[position % cases.count].name = name
                                default:
                                    break
                            }
                            return .union(cases: cases)
                        }
                    )
            }
        }
    }

    /// Which field lists the added-field property leans on.
    enum FieldListLean: Sendable {
        case any, unionCase, fieldlessUnionCase
    }

    /// A part of a call that carries a schema, named as a break's path
    /// names it.
    enum CallPart: String, CaseIterable, Sendable {
        case request
        case response
        case requestStream = "request stream"
        case responseStream = "response stream"

        /// Whether the server reads the part: the request and its stream.
        var readByServer: Bool { self == .request || self == .requestStream }

        /// A call with `schema` in this part and empty structures in the
        /// others it has.
        func signature(_ schema: TypeSchema) -> MethodSignature {
            let empty = TypeSchema.structure(fields: [])
            return MethodSignature(
                name: "call",
                access: .read,
                request: self == .request ? schema : empty,
                response: self == .response ? schema : empty,
                requestStream: self == .requestStream ? schema : nil,
                responseStream: self == .responseStream ? schema : nil
            )
        }
    }

    @Suite("Schema compatibility properties", .hegel, .offTheCooperativePool)
    struct SchemaCompatibilityProperties {
        /// Every schema reads itself, and every named type reads itself:
        /// schemas of every kind, with references, chains, named types met
        /// inside themselves, unknown slots, constraints on fields and on
        /// named scalars, a type neither side defines, and one defined as
        /// itself.
        ///
        /// Mutation check: two unknown slots, two unresolved references of
        /// one name, or two equal pattern lists judged apart, or a recursive
        /// type compared without its cycle cut (which never returns), fails
        /// here.
        @Test
        func everySchemaReadsItself() throws {
            try property(
                reaching: ["a field", "a named type"],
                reachingAfter: [
                    "a named type met inside itself": 1_000, "a union": 1_000,
                    "an enumeration": 1_000, "a constraint": 1_000, "an unknown slot": 1_000,
                    "a type neither side defines": 1_000, "a type defined as itself": 1_000,
                ]
            ) { tc in
                let unknownSlots = try #draw(Gen<Bool>.bool(probability: 0.4), from: tc)
                let fitting = try CompatibilityGenerators.structureFitting(
                    tc,
                    unknownSlots: unknownSlots
                )
                var decorator = ConstraintDecorator(
                    definitions: fitting.definitions,
                    constraintRate: try #draw(Gen<Double>.element(of: [0, 0.3, 0.8]), from: tc),
                    ruleRate: 0.6,
                    aliasRate: try #draw(Gen<Double>.element(of: [0, 0.3]), from: tc)
                )
                let schema = try decorator.decorate(tc, fitting.schema)
                try decorator.decorateDefinitions(tc)
                var side = SchemaSide(schema: schema, definitions: decorator.definitions)
                let sites = ReachableSites(side)
                if let field = sites.fields.first,
                    try #draw(Gen<Bool>.bool(probability: 0.2), from: tc)
                {
                    try tc.event("a type neither side defines")
                    side = side.rewriting(field.type, .node { _ in .reference("missing.Type") })
                }
                if let field = sites.fields.last,
                    try #draw(Gen<Bool>.bool(probability: 0.2), from: tc)
                {
                    try tc.event("a type defined as itself")
                    side.definitions.append(
                        TypeDefinition(name: "loop.Type", schema: .reference("loop.Type"))
                    )
                    side = side.rewriting(
                        field.type,
                        .node { _ in .optional(.reference("loop.Type")) }
                    )
                }
                if !sites.fields.isEmpty { try tc.event("a field") }
                if sites.references > 0 { try tc.event("a named type") }
                if sites.recursive { try tc.event("a named type met inside itself") }
                if !sites.unions.isEmpty { try tc.event("a union") }
                if !sites.enumerations.isEmpty { try tc.event("an enumeration") }
                if sites.fields.contains(where: { $0.field.constraints != nil })
                    || side.definitions.contains(where: { $0.constraints != nil })
                {
                    try tc.event("a constraint")
                }
                if sites.fields.contains(where: { side.coreKind(of: $0.field.type) == "unknown" }) {
                    try tc.event("an unknown slot")
                }
                tc.note("\(side.schema)\n\(side.definitions)")

                let resolver = side.resolver
                let verdict = TypeSchema.compatibility(
                    reader: side.schema,
                    readerTypes: resolver,
                    writer: side.schema,
                    writerTypes: resolver
                )
                #expect(verdict == .compatible, "a schema does not read itself: \(verdict)")
                for definition in side.definitions {
                    let own = TypeDefinition.compatibility(
                        reader: definition,
                        readerTypes: resolver,
                        writer: definition,
                        writerTypes: resolver
                    )
                    #expect(own == .compatible, "\(definition.name) does not read itself: \(own)")
                }
            }
        }

        /// An optional field added to one side reads, whichever side and
        /// wherever: at the root, in a named type, in a structure nested
        /// in another, or in a union case, the first field of a case
        /// included, since a writer's case with no fields leaves its fields
        /// map out and a reader reads a missing map as one of no fields.
        ///
        /// Mutation check: a field only the reader has judged required
        /// whatever its type, a field only the writer has judged at all, or
        /// a reader's case with fields judged unable to read a fieldless
        /// writer case, fails here.
        @Test
        func anAddedOptionalFieldReads() throws {
            try property(
                reaching: [
                    "added to the reader", "added to the writer", "keyed", "keyed by name",
                ],
                reachingAfter: [
                    "in a named type": 1_000, "in a union case": 1_000, "nested": 1_000,
                    "added to the reader's fieldless union case": 1_000,
                ]
            ) { tc in
                let unknownSlots = try #draw(Gen<Bool>.bool(probability: 0.3), from: tc)
                // A union case is a few percent of the lists, a fieldless
                // one fewer; lean on them in some cases.
                let lean = try #draw(
                    Gen<FieldListLean>.element(of: [.any, .any, .unionCase, .fieldlessUnionCase]),
                    from: tc
                )
                let fitting = try CompatibilityGenerators.structureFitting(
                    tc,
                    unknownSlots: unknownSlots,
                    leaning: lean == .any ? nil : .union
                )
                let side = SchemaSide(schema: fitting.schema, definitions: fitting.definitions)
                let sites = ReachableSites(side)
                let leaned = sites.fieldLists.filter { list in
                    switch lean {
                        case .any: true
                        case .unionCase: list.isUnionCase
                        case .fieldlessUnionCase: list.isUnionCase && side.fields(at: list).isEmpty
                    }
                }
                let list = try #draw(
                    Gen<SchemaSite>.element(of: leaned.isEmpty ? sites.fieldLists : leaned),
                    from: tc
                )
                let type = try #draw(
                    Gen<TypeSchema>.element(
                        of: CompatibilityGenerators.fieldTypes(
                            for: side,
                            unknownSlots: unknownSlots
                        )
                    ),
                    from: tc
                )
                let toReader = try #draw(Gen<Bool>.bool(), from: tc)
                let before = side.fields(at: list)
                let added = try CompatibilityGenerators.freshField(
                    tc,
                    among: before,
                    type: .optional(type)
                )
                let edited = side.rewriting(list, .fields { $0 + [added] })
                try tc.event(toReader ? "added to the reader" : "added to the writer")
                try tc.event(added.key == nil ? "keyed by name" : "keyed")
                if list.definition != nil { try tc.event("in a named type") }
                if list.inUnionCase { try tc.event("in a union case") }
                if list.steps.count > (list.isUnionCase ? 1 : 0) { try tc.event("nested") }
                tc.note("added \(added) at \(list.path.isEmpty ? "the root" : list.path)")

                let (reader, writer) = toReader ? (edited, side) : (side, edited)
                let verdict = TypeSchema.compatibility(
                    reader: reader.schema,
                    readerTypes: reader.resolver,
                    writer: writer.schema,
                    writerTypes: writer.resolver
                )
                if toReader, list.isUnionCase, before.isEmpty {
                    try tc.event("added to the reader's fieldless union case")
                }
                #expect(verdict == .compatible, "an added optional field breaks: \(verdict)")
            }
        }

        /// A position whose schema takes another kind breaks, in either
        /// side, and the break names the position's path: a field's type,
        /// an array's element, a map's key or value, at the root, in a
        /// named type or in a union case.
        ///
        /// Mutation check: two leaves of different kinds judged alike, a
        /// map's key or an array's element left unjudged, a reference
        /// followed on one side only, or a named type judged at a position
        /// other than its first, fails here.
        @Test
        func aChangedFieldTypeBreaks() throws {
            try property(
                reaching: ["changed in the reader", "changed in the writer", "a field"],
                reachingAfter: [
                    "an array's element": 1_000, "a map's key": 1_000, "a map's value": 1_000,
                    "in a named type": 1_000, "in a union case": 1_000, "an optional": 1_000,
                    "a named type's kind": 1_000,
                ]
            ) { tc in
                let unknownSlots = try #draw(Gen<Bool>.bool(probability: 0.3), from: tc)
                let fitting = try CompatibilityGenerators.structureFitting(
                    tc,
                    unknownSlots: unknownSlots
                )
                let side = SchemaSide(schema: fitting.schema, definitions: fitting.definitions)
                let sites = ReachableSites(side)
                // Fields are most of the positions; draw the role first so
                // elements, keys and values come up too.
                let roles = TypePosition.Role.allCases.filter { role in
                    sites.positions.contains { $0.role == role }
                }
                let role = try #draw(Gen<TypePosition.Role>.element(of: roles), from: tc)
                let target = try #draw(
                    Gen<TypePosition>.element(of: sites.positions.filter { $0.role == role }),
                    from: tc
                )
                let old = side.coreKind(of: target.schema)
                let replacements = CompatibilityGenerators.fieldTypes(
                    for: side,
                    unknownSlots: unknownSlots
                )
                .filter { side.coreKind(of: $0) != old }
                var replacement = try #draw(Gen<TypeSchema>.element(of: replacements), from: tc)
                if try #draw(Gen<Bool>.bool(probability: 0.3), from: tc) {
                    replacement = .optional(replacement)
                }
                let toReader = try #draw(Gen<Bool>.bool(), from: tc)
                try tc.event(toReader ? "changed in the reader" : "changed in the writer")
                try tc.event(role.rawValue)
                if target.site.definition != nil { try tc.event("in a named type") }
                if target.site.inUnionCase { try tc.event("in a union case") }
                if case .optional = target.schema { try tc.event("an optional") }
                if case .reference = target.schema { try tc.event("a named type's kind") }
                if old == "unknown" { try tc.event("from an unknown kind") }
                if side.coreKind(of: replacement) == "unknown" {
                    try tc.event("to an unknown kind")
                }
                tc.note("\(target.site.path): \(target.schema) became \(replacement)")

                let edited = side.rewriting(target.site, .node { _ in replacement })
                let (reader, writer) = toReader ? (edited, side) : (side, edited)
                let verdict = TypeSchema.compatibility(
                    reader: reader.schema,
                    readerTypes: reader.resolver,
                    writer: writer.schema,
                    writerTypes: writer.resolver
                )
                #expect(
                    verdict.breaks.contains { $0.path == target.site.path },
                    "\(role.rawValue) changed from \(old) without a break at \(target.site.path): \(verdict)"
                )
            }
        }

        /// An enumeration or union case renamed on either side breaks at
        /// the type's path: each side then has a case the other lacks, so
        /// the rename reads as a replacement.
        ///
        /// Mutation check: cases compared only one way, so a case the
        /// reader adds is never seen, or a union's cases left uncompared,
        /// fails here.
        @Test
        func aRenamedCaseBreaks() throws {
            try property(
                reaching: [
                    "an enumeration", "a union", "renamed in the reader", "renamed in the writer",
                ],
                reachingAfter: [
                    "in a named type": 1_000, "a case with fields": 1_000, "nested": 1_000,
                ]
            ) { tc in
                let lean = try #draw(
                    Gen<CompositeKind>.element(of: [.enumeration, .union]),
                    from: tc
                )
                let fitting = try CompatibilityGenerators.structureFitting(
                    tc,
                    unknownSlots: false,
                    leaning: lean
                )
                let side = SchemaSide(schema: fitting.schema, definitions: fitting.definitions)
                let sites = ReachableSites(side)
                let candidates = (sites.enumerations + sites.unions).filter { site in
                    switch side.schema(at: site) {
                        case .enumeration(let cases)?: !cases.isEmpty
                        case .union(let cases)?: !cases.isEmpty
                        default: false
                    }
                }
                // A schema the policy drew without cases has nothing to
                // rename; the reach claims bound how often.
                guard !candidates.isEmpty else { return }
                let site = try #draw(Gen<SchemaSite>.element(of: candidates), from: tc)
                let position = try #draw(Gen<Int>.int(in: 0...7), from: tc)
                let fresh = try CompatibilityGenerators.freshName(tc, avoiding: [])
                let toReader = try #draw(Gen<Bool>.bool(), from: tc)
                let renamed: TypeSchema
                switch side.schema(at: site) {
                    case .enumeration(var cases)?:
                        try tc.event("an enumeration")
                        var name = fresh
                        while cases.contains(where: { $0.name == name }) { name += "'" }
                        cases[position % cases.count].name = name
                        renamed = .enumeration(cases: cases)
                    case .union(var cases)?:
                        try tc.event("a union")
                        var name = fresh
                        while cases.contains(where: { $0.name == name }) { name += "'" }
                        let index = position % cases.count
                        if !cases[index].fields.isEmpty { try tc.event("a case with fields") }
                        cases[index].name = name
                        renamed = .union(cases: cases)
                    default:
                        throw GeneratorFault(description: "no cases at \(site.path)")
                }
                try tc.event(toReader ? "renamed in the reader" : "renamed in the writer")
                if site.definition != nil { try tc.event("in a named type") }
                if !site.path.isEmpty { try tc.event("nested") }
                tc.note("at \(site.path): \(renamed)")

                let edited = side.rewriting(site, .node { _ in renamed })
                let (reader, writer) = toReader ? (edited, side) : (side, edited)
                let verdict = TypeSchema.compatibility(
                    reader: reader.schema,
                    readerTypes: reader.resolver,
                    writer: writer.schema,
                    writerTypes: writer.resolver
                )
                #expect(
                    verdict.breaks.contains {
                        $0.path == site.path && $0.reason.hasPrefix("renamed or replaced cases")
                    },
                    "a renamed case without a break at \(site.path): \(verdict)"
                )
            }
        }

        /// A required field added to one side of a call breaks exactly
        /// when that side reads the part it is in: the server reads the
        /// request and the request stream, the client the response and the
        /// response stream. Added to the side that writes the part, the
        /// other side skips it. The break names the part and the field, in a
        /// union case whose writer's case has no fields too.
        ///
        /// Mutation check: a part judged with the client and the server
        /// swapped, or a stream part left unjudged, fails here.
        @Test
        func aRequiredFieldBreaksOnlyItsReader() throws {
            try property(
                reaching: [
                    "added by the client", "added by the server", "judged breaking",
                    "judged compatible",
                ],
                reachingAfter: [
                    "in the request": 1_000, "in the response": 1_000,
                    "in the request stream": 1_000,
                    "in the response stream": 1_000, "in a named type": 1_000,
                    "in a union case": 1_000, "the first field of a case": 1_000,
                ]
            ) { tc in
                let part = try #draw(Gen<CallPart>.element(of: CallPart.allCases), from: tc)
                let fitting = try CompatibilityGenerators.structureFitting(tc, unknownSlots: false)
                let side = SchemaSide(schema: fitting.schema, definitions: fitting.definitions)
                let sites = ReachableSites(side, root: part.rawValue)
                let list = try #draw(Gen<SchemaSite>.element(of: sites.fieldLists), from: tc)
                let type = try #draw(
                    Gen<TypeSchema>.element(
                        of: CompatibilityGenerators.fieldTypes(for: side, unknownSlots: false)
                    ),
                    from: tc
                )
                let before = side.fields(at: list)
                let added = try CompatibilityGenerators.freshField(tc, among: before, type: type)
                let edited = side.rewriting(list, .fields { $0 + [added] })
                let byServer = try #draw(Gen<Bool>.bool(), from: tc)
                try tc.event(byServer ? "added by the server" : "added by the client")
                try tc.event("in the \(part.rawValue)")
                if list.definition != nil { try tc.event("in a named type") }
                if list.inUnionCase { try tc.event("in a union case") }
                let fieldPath = "\(list.path).\(added.name)"
                if list.isUnionCase, before.isEmpty { try tc.event("the first field of a case") }
                tc.note("added \(added) at \(fieldPath)")

                let (client, server) = byServer ? (side, edited) : (edited, side)
                let verdict = MethodSignature.compatibility(
                    client: part.signature(client.schema),
                    clientTypes: client.resolver,
                    server: part.signature(server.schema),
                    serverTypes: server.resolver
                )
                try tc.event(verdict.isBreaking ? "judged breaking" : "judged compatible")
                if byServer == part.readByServer {
                    #expect(
                        verdict.breaks.contains { $0.path == fieldPath },
                        "a field the \(byServer ? "server" : "client") reads and requires, unwritten, did not break: \(verdict)"
                    )
                } else {
                    #expect(
                        verdict == .compatible,
                        "a field only the writer has breaks: \(verdict)"
                    )
                }
            }
        }

        /// A reader judged compatible with a writer reads every value the
        /// writer writes: the writer's value sent with the writer's schema
        /// decodes with the reader's, after any mix of up to three edits to
        /// the reader — fields added, removed, renamed, rekeyed, retyped,
        /// made optional or required, and enumeration and union cases added,
        /// removed or renamed.
        ///
        /// Mutation check: a field the writer leaves out or writes as an
        /// optional judged readable by a reader that requires it, a kind
        /// change judged compatible, fields paired by name in a keyed type,
        /// or a fieldless writer case judged readable by a case with a
        /// required field, fails here.
        @Test
        func aCompatibleReaderReadsWhatTheWriterWrites() throws {
            try property(
                reaching: ["judged compatible", "judged breaking", "read back"],
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: [
                        ReaderEdit.addOptionalField, .removeField, .renameField, .makeFieldOptional,
                        .addEnumerationCase, .removeEnumerationCase, .addUnionCase,
                        .removeUnionCase,
                    ].map { ("read back after \($0.rawValue)", 1_000) }
                        + ReaderEdit.allCases.map { ($0.rawValue, 1_000) }
                )
            ) { tc in
                // Most edits are to fields; lean on cases in some cases.
                let family = try #draw(
                    Gen<ReaderEdit.Family>.element(of: [.fields, .fields, .enumerations, .unions]),
                    from: tc
                )
                let fitting = try CompatibilityGenerators.structureFitting(
                    tc,
                    unknownSlots: false,
                    leaning: family.composite
                )
                let writer = SchemaSide(schema: fitting.schema, definitions: fitting.definitions)
                var reader = writer
                var edits: [ReaderEdit] = []
                for _ in 0..<(try #draw(Gen<Int>.int(in: 1...3), from: tc)) {
                    let sites = ReachableSites(reader)
                    let available = ReaderEdit.allCases.filter { $0.applies(to: sites) }
                    let preferred = available.filter { $0.family == family }
                    let edit = try #draw(
                        Gen<ReaderEdit>.element(of: preferred.isEmpty ? available : preferred),
                        from: tc
                    )
                    reader = try edit.applied(tc, to: reader, sites: sites)
                    edits.append(edit)
                }
                for edit in Set(edits) { try tc.event(edit.rawValue) }
                tc.note("reader: \(reader.schema)\n\(reader.definitions)")

                let verdict = TypeSchema.compatibility(
                    reader: reader.schema,
                    readerTypes: reader.resolver,
                    writer: writer.schema,
                    writerTypes: writer.resolver
                )
                guard !verdict.isBreaking else {
                    try tc.event("judged breaking")
                    return
                }
                try tc.event("judged compatible")
                let request = try MMCLIDynamicRequest(
                    schema: writer.schema,
                    definitions: writer.definitions,
                    json: fitting.value
                )
                let bytes = try MMPackEncoder().encode(request).get()
                let read = Result {
                    try MMCLIDynamicResponse.$schema.withValue((reader.schema, reader.definitions))
                    {
                        try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
                    }
                }
                switch read {
                    case .success:
                        try tc.event("read back")
                        for edit in Set(edits) { try tc.event("read back after \(edit.rawValue)") }
                    case .failure(let error):
                        Issue.record(
                            "judged compatible, yet \(fitting.value) did not read: \(error)"
                        )
                }
            }
        }

        /// A reader whose rules the writer is judged to keep takes every
        /// value the writer's rules take: a field's and a named scalar's
        /// rules on each side, on an int, a uint, a double or a string,
        /// bounds of the field's kind and integer bounds on a double, and
        /// values at, beside and between the bounds.
        ///
        /// Mutation check: a reader's minimum judged kept by a lower one, a
        /// maximum by a higher one, a length or a pattern the writer does
        /// not keep judged kept, or a named scalar's rules left out, fails
        /// here. Bounds of two kinds past 2^53 have a property of their own.
        @Test
        func aRuleJudgedKeptHoldsForEveryValueTheWriterKeeps() throws {
            try property(
                reaching: ["judged compatible", "judged breaking", "the writer keeps the value"],
                reachingAfter: [
                    "an int": 1_000, "a uint": 1_000, "a double": 1_000, "a string": 1_000,
                    "kept by both, judged compatible": 1_000, "a named scalar's rules": 1_000,
                    "an integer bound on a double": 1_000, "a pattern": 1_000,
                    "a value the reader refuses, judged breaking": 1_000,
                ]
            ) { tc in
                let kind = try #draw(
                    Gen<TypeSchema>.element(of: [.int, .uint, .double, .string]),
                    from: tc
                )
                let decorator = ConstraintDecorator(
                    definitions: [],
                    constraintRate: 1,
                    ruleRate: try #draw(Gen<Double>.element(of: [0.4, 0.8]), from: tc),
                    aliasRate: 0
                )
                func rules() throws -> [TypeSchema.Constraints?] {
                    [
                        try decorator.constraints(tc, for: kind),
                        try #draw(Gen<Bool>.bool(probability: 0.3), from: tc)
                            ? try decorator.constraints(tc, for: kind) : nil,
                    ]
                }
                let readerRules = try rules()
                let writerRules = try rules()
                func side(_ rules: [TypeSchema.Constraints?], _ name: String) -> SchemaSide {
                    let named = rules[1] != nil
                    return SchemaSide(
                        schema: .structure(fields: [
                            TypeSchema.Field(
                                key: 0,
                                name: "value",
                                type: named ? .reference(name) : kind,
                                constraints: rules[0]
                            )
                        ]),
                        definitions: named
                            ? [TypeDefinition(name: name, schema: kind, constraints: rules[1])] : []
                    )
                }
                let reader = side(readerRules, "rules.Reader")
                let writer = side(writerRules, "rules.Writer")
                let verdict = TypeSchema.compatibility(
                    reader: reader.schema,
                    readerTypes: reader.resolver,
                    writer: writer.schema,
                    writerTypes: writer.resolver
                )
                let all = (readerRules + writerRules).compactMap { $0 }
                try tc.event(
                    "a \(kindName(kind))".replacingOccurrences(of: "a int", with: "an int")
                )
                if readerRules[1] != nil || writerRules[1] != nil {
                    try tc.event("a named scalar's rules")
                }
                if all.contains(where: { $0.pattern != nil }) { try tc.event("a pattern") }
                if kind == .double,
                    all.contains(where: {
                        [$0.minimum, $0.maximum].contains {
                            if case .integer? = $0 { true } else { false }
                        }
                    })
                {
                    try tc.event("an integer bound on a double")
                }
                let value = try #draw(Self.values(of: kind, around: all), from: tc)
                tc.note("value: \(value)")
                func keeps(_ rules: [TypeSchema.Constraints?]) -> Bool {
                    rules.compactMap { $0 }.allSatisfy { value.violation(of: $0) == nil }
                }
                let writerKeeps = keeps(writerRules)
                let readerKeeps = keeps(readerRules)
                try tc.event(verdict.isBreaking ? "judged breaking" : "judged compatible")
                if writerKeeps { try tc.event("the writer keeps the value") }
                if writerKeeps, readerKeeps, !verdict.isBreaking {
                    try tc.event("kept by both, judged compatible")
                }
                if writerKeeps, !readerKeeps {
                    try tc.event("a value the reader refuses, judged breaking")
                    #expect(
                        verdict.isBreaking,
                        "the writer keeps \(value), the reader refuses it, yet judged compatible"
                    )
                }
            }
        }

        /// Past 2^53 a `Double` no longer holds every integer, so an integer
        /// and a floating bound order only where both are exact: a bound
        /// judged kept there holds for every value the writer's bound
        /// takes, on an int, a uint or a double, a minimum or a maximum.
        /// The bounds and values sit at and beside 2^53, where a check
        /// converts an int to `Double` for a floating bound and keeps it
        /// exact for an integer one.
        ///
        /// Mutation check: an integer and a floating bound ordered through
        /// `Double` at any size, in either order, fails here.
        @Test
        func aBoundJudgedKeptHoldsPast2To53() throws {
            try property(
                reaching: [
                    "a minimum", "a maximum", "the writer keeps the value", "bounds of two kinds",
                ],
                reachingAfter: [
                    "an int": 1_000, "a uint": 1_000, "a double": 1_000,
                    "a value the reader refuses, judged breaking": 1_000,
                ]
            ) { tc in
                let kind = try #draw(Gen<TypeSchema>.element(of: [.int, .uint, .double]), from: tc)
                let isMinimum = try #draw(Gen<Bool>.bool(), from: tc)
                let readerBound = try #draw(
                    Gen<TypeSchema.Bound>.element(of: Self.boundsPast2To53),
                    from: tc
                )
                let writerBound = try #draw(
                    Gen<TypeSchema.Bound>.element(of: Self.boundsPast2To53),
                    from: tc
                )
                let integer = try #draw(Gen<Int64>.element(of: Self.valuesPast2To53), from: tc)
                let value: RuleValue =
                    switch kind {
                        case .int: .int(integer)
                        case .uint: .uint(UInt64(integer))
                        default: .double(Double(integer))
                    }
                func rules(_ bound: TypeSchema.Bound) -> TypeSchema.Constraints {
                    isMinimum
                        ? TypeSchema.Constraints(minimum: bound)
                        : TypeSchema.Constraints(maximum: bound)
                }
                func schema(_ bound: TypeSchema.Bound) -> TypeSchema {
                    .structure(fields: [
                        TypeSchema.Field(
                            key: 0,
                            name: "value",
                            type: kind,
                            constraints: rules(bound)
                        )
                    ])
                }
                try tc.event(
                    "a \(kindName(kind))".replacingOccurrences(of: "a int", with: "an int")
                )
                try tc.event(isMinimum ? "a minimum" : "a maximum")
                if case .integer = readerBound, case .floating = writerBound {
                    try tc.event("bounds of two kinds")
                }
                if case .floating = readerBound, case .integer = writerBound {
                    try tc.event("bounds of two kinds")
                }
                tc.note("reads \(rules(readerBound)), writes \(rules(writerBound)), value \(value)")

                let verdict = TypeSchema.compatibility(
                    reader: schema(readerBound),
                    writer: schema(writerBound)
                )
                let writerKeeps = value.violation(of: rules(writerBound)) == nil
                let readerKeeps = value.violation(of: rules(readerBound)) == nil
                if writerKeeps { try tc.event("the writer keeps the value") }
                if writerKeeps, !readerKeeps {
                    try tc.event("a value the reader refuses, judged breaking")
                    #expect(
                        verdict.isBreaking,
                        "the writer keeps \(value), the reader refuses it, yet judged compatible"
                    )
                }
            }
        }

        /// Bounds at and beside 2^53, of both kinds: 2^53 + 1 is the first
        /// integer a `Double` rounds, to 2^53.
        static let boundsPast2To53: [TypeSchema.Bound] = [
            .integer(1 << 53), .integer((1 << 53) + 1), .floating(9_007_199_254_740_992),
            .floating(9_007_199_254_740_994),
        ]

        /// Values at and beside 2^53.
        static let valuesPast2To53: [Int64] = [
            (1 << 53) - 1, 1 << 53, (1 << 53) + 1, (1 << 53) + 2,
        ]

        /// A value a rule applies to, for the rule properties.
        enum RuleValue: Sendable, CustomStringConvertible {
            case int(Int64)
            case uint(UInt64)
            case double(Double)
            case string(String)

            func violation(of rules: TypeSchema.Constraints) -> String? {
                switch self {
                    case .int(let value): rules.violation(of: value)
                    case .uint(let value): rules.violation(of: value)
                    case .double(let value): rules.violation(of: value)
                    case .string(let value): rules.violation(of: value)
                }
            }

            var description: String {
                switch self {
                    case .int(let value): "\(value)"
                    case .uint(let value): "\(value)"
                    case .double(let value): "\(value)"
                    case .string(let value): "\"\(value)\""
                }
            }
        }

        /// Values of `kind`: at, just beside and between the bounds the
        /// rules use, or anywhere in the kind's domain.
        static func values(of kind: TypeSchema, around rules: [TypeSchema.Constraints]) -> Gen<
            RuleValue
        > {
            let bounds = rules.flatMap { [$0.minimum, $0.maximum].compactMap { $0 } }
            let numbers = bounds.compactMap { bound -> Double? in
                switch bound {
                    case .integer(let value): Double(value)
                    case .floating(let value): value
                    case .duration: nil
                }
            }
            let integers = bounds.compactMap {
                if case .integer(let value) = $0 { value } else { nil }
            }
            switch kind {
                case .int:
                    let near = integers.flatMap { [$0, $0 &- 1, $0 &+ 1] } + [0, .min, .max]
                    return Gen<Int64>.oneOf(.element(of: near), .integer()).map {
                        RuleValue.int($0)
                    }
                case .uint:
                    let near =
                        integers.flatMap { [$0, $0 &- 1, $0 &+ 1] }.filter { $0 >= 0 }.map(
                            UInt64.init
                        )
                        + [0, .max, UInt64(Int64.max) + 1]
                    return Gen<UInt64>.oneOf(.element(of: near), .integer()).map {
                        RuleValue.uint($0)
                    }
                case .double:
                    let near =
                        numbers.flatMap { [$0, $0.nextUp, $0.nextDown] } + [
                            0, -0.0, .nan, .infinity, -.infinity,
                        ]
                    return Gen<Double>.oneOf(.element(of: near), .double()).map {
                        RuleValue.double($0)
                    }
                default:
                    return Gen<String>.string(of: .characters("az09"), count: 0...7).map {
                        RuleValue.string($0)
                    }
            }
        }
    }

#endif

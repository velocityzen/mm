/// Whether a peer that reads with one schema reads what a peer that writes
/// with another writes: the verdict that sorts a schema change into
/// compatible or breaking. See ``TypeSchema/compatibility(reader:readerTypes:writer:writerTypes:)``
/// for the rules.
public enum SchemaCompatibility: Sendable, Hashable, CustomStringConvertible {
    /// The reader reads every value the writer writes, and every rule the
    /// reader requires, the writer keeps.
    case compatible
    /// Something the writer writes, the reader does not read as the
    /// contract says; each break says where and why.
    case breaking([SchemaBreak])

    /// The verdict these breaks add up to: compatible when there are none.
    public init(breaks: [SchemaBreak]) {
        self = breaks.isEmpty ? .compatible : .breaking(breaks)
    }

    /// Whether anything breaks.
    public var isBreaking: Bool {
        if case .breaking = self { true } else { false }
    }

    /// Where and why it breaks; empty when compatible.
    public var breaks: [SchemaBreak] {
        if case .breaking(let breaks) = self { breaks } else { [] }
    }

    /// `compatible`, or the breaks: `count: read as int, written as string`.
    public var description: String {
        switch self {
            case .compatible: "compatible"
            case .breaking(let breaks): breaks.map(\.description).joined(separator: "; ")
        }
    }
}

/// One way a reader fails to read what a writer writes.
public struct SchemaBreak: Sendable, Hashable, CustomStringConvertible {
    /// Where it breaks, from the root of what was judged: field names
    /// joined by dots, `[]` for an array's elements, `[key]` and `[value]`
    /// for a map's, and a union case in parentheses, as in
    /// `request.entries[].kind` or `response(moved).to`. Empty at the root.
    /// A break inside a named type is named once, at the first position
    /// that reaches it.
    public var path: String
    /// What breaks there, in words: `read as int, written as string`.
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    /// `path: reason`, or the reason alone at the root.
    public var description: String {
        self.path.isEmpty ? self.reason : "\(self.path): \(self.reason)"
    }
}

extension TypeSchema {
    /// Whether a peer that reads `reader` reads every value a peer that
    /// writes `writer` writes. References resolve through each side's own
    /// named types: `readerTypes` for the reader's, `writerTypes` for the
    /// writer's.
    ///
    /// - **Fields** pair up as a reader finds them: a reader's field reads
    ///   the writer's field of its integer key, or else a writer's field
    ///   that has no key and the reader's field's name. So a field renamed
    ///   with its key and type kept reads as before, and a field that gains
    ///   a key still reads a writer that names it. A field only the writer
    ///   has is skipped. A field only the
    ///   reader has must be optional: a field the reader requires breaks
    ///   when the writer does not write it, or writes it as an optional.
    /// - **Kinds** must match once references are followed and optionals
    ///   unwrapped. The reader may take an optional where the writer always
    ///   writes a value. `unknown`, which a kind this peer does not know
    ///   decodes as, matches only `unknown`.
    /// - **Enumeration and union cases**: a case only one side declares
    ///   reads, since a reader keeps a value it does not declare as its
    ///   `unknown` case. When each side declares a case the other does not,
    ///   a case was renamed or replaced, and that breaks. A union case both
    ///   declare compares its fields as a structure does. A case the writer
    ///   declares with no fields leaves its fields map out, which a reader
    ///   reads as a map of no fields: a reader's case whose fields are all
    ///   optional reads it, and one with a required field breaks.
    /// - **Constraints** the reader requires, the writer must keep: a bound
    ///   or length at least as tight, and the same pattern. A field's rules
    ///   and those of the named scalars its type names all hold.
    ///   Defaults are not compared: a field with one is optional on the
    ///   wire, and the field rule judges it.
    /// - **References**: a name neither side defines stands for the same
    ///   unknown type on both sides. A name only one side defines, or one
    ///   that resolves to itself, breaks.
    ///
    /// Descriptions and deprecations are never compared.
    public static func compatibility(
        reader: TypeSchema,
        readerTypes: TypeResolver = TypeResolver([]),
        writer: TypeSchema,
        writerTypes: TypeResolver = TypeResolver([])
    ) -> SchemaCompatibility {
        SchemaCompatibility(
            breaks: Self.breaks(
                reader: reader,
                readerTypes: readerTypes,
                writer: writer,
                writerTypes: writerTypes,
                at: ""
            )
        )
    }

    /// The breaks between `reader` and `writer`, with paths under `path`.
    static func breaks(
        reader: TypeSchema,
        readerTypes: TypeResolver,
        writer: TypeSchema,
        writerTypes: TypeResolver,
        at path: String
    ) -> [SchemaBreak] {
        var judge = CompatibilityJudge(readerTypes: readerTypes, writerTypes: writerTypes)
        judge.judge(
            reader: reader,
            readerRules: CompatibilityJudge.Rules(),
            writer: writer,
            writerRules: CompatibilityJudge.Rules(),
            at: path
        )
        return judge.breaks
    }
}

extension TypeDefinition {
    /// Whether a peer that reads values of `reader` reads every value a
    /// peer that writes `writer` writes: the two definitions' shapes and
    /// constraints compared as ``TypeSchema/compatibility(reader:readerTypes:writer:writerTypes:)``
    /// compares schemas, each side's references resolved through its own
    /// named types. Paths start at the reader's name.
    public static func compatibility(
        reader: TypeDefinition,
        readerTypes: TypeResolver,
        writer: TypeDefinition,
        writerTypes: TypeResolver
    ) -> SchemaCompatibility {
        var judge = CompatibilityJudge(readerTypes: readerTypes, writerTypes: writerTypes)
        judge.judge(
            reader: reader.schema,
            readerRules: CompatibilityJudge.Rules(reader.constraints),
            writer: writer.schema,
            writerRules: CompatibilityJudge.Rules(writer.constraints),
            at: reader.name,
            inside: (reader.name, writer.name)
        )
        return SchemaCompatibility(breaks: judge.breaks)
    }
}

extension MethodSignature {
    /// How a client built against `client` works with a server that serves
    /// `server` under the same name. The server reads the request and the
    /// request stream; the client reads the response, the response stream
    /// and the declared errors. Each part is judged as
    /// ``TypeSchema/compatibility(reader:readerTypes:writer:writerTypes:)``
    /// judges a schema, with paths starting at the part: `request`,
    /// `request stream`, `response`, `response stream` or `errors`.
    ///
    /// A changed access breaks, and so does a stream only one side declares.
    /// No declared errors read as a union of no cases, so errors only one
    /// side declares are cases only one side declares.
    public static func compatibility(
        client: MethodSignature,
        clientTypes: TypeResolver,
        server: MethodSignature,
        serverTypes: TypeResolver
    ) -> SchemaCompatibility {
        var breaks: [SchemaBreak] = []
        if client.access != server.access {
            breaks.append(
                SchemaBreak(
                    path: "access",
                    reason:
                        "the client expects \(client.access), the server requires \(server.access)"
                )
            )
        }
        func part(
            reader: TypeSchema,
            readerTypes: TypeResolver,
            writer: TypeSchema,
            writerTypes: TypeResolver,
            at path: String
        ) {
            breaks += TypeSchema.breaks(
                reader: reader,
                readerTypes: readerTypes,
                writer: writer,
                writerTypes: writerTypes,
                at: path
            )
        }
        func stream(client: TypeSchema?, server: TypeSchema?, serverReads: Bool, at path: String) {
            switch (client, server) {
                case (nil, nil):
                    break
                case (.some, nil):
                    breaks.append(SchemaBreak(path: path, reason: "declared by the client only"))
                case (nil, .some):
                    breaks.append(SchemaBreak(path: path, reason: "declared by the server only"))
                case (.some(let client), .some(let server)):
                    if serverReads {
                        part(
                            reader: server,
                            readerTypes: serverTypes,
                            writer: client,
                            writerTypes: clientTypes,
                            at: path
                        )
                    } else {
                        part(
                            reader: client,
                            readerTypes: clientTypes,
                            writer: server,
                            writerTypes: serverTypes,
                            at: path
                        )
                    }
            }
        }
        part(
            reader: server.request,
            readerTypes: serverTypes,
            writer: client.request,
            writerTypes: clientTypes,
            at: "request"
        )
        stream(
            client: client.requestStream,
            server: server.requestStream,
            serverReads: true,
            at: "request stream"
        )
        part(
            reader: client.response,
            readerTypes: clientTypes,
            writer: server.response,
            writerTypes: serverTypes,
            at: "response"
        )
        stream(
            client: client.responseStream,
            server: server.responseStream,
            serverReads: false,
            at: "response stream"
        )
        part(
            reader: client.errors ?? .union(cases: []),
            readerTypes: clientTypes,
            writer: server.errors ?? .union(cases: []),
            writerTypes: serverTypes,
            at: "errors"
        )
        return SchemaCompatibility(breaks: breaks)
    }
}

/// The walk behind ``TypeSchema/compatibility(reader:readerTypes:writer:writerTypes:)``:
/// the reader's and the writer's schemas side by side, position by
/// position, collecting what breaks.
struct CompatibilityJudge {
    let readerTypes: TypeResolver
    let writerTypes: TypeResolver
    private(set) var breaks: [SchemaBreak] = []
    /// The pairs of named types compared already, or being compared
    /// further up the walk, each with the rules its position adds: met
    /// again, at another position, through another alias or inside itself,
    /// a pair is not compared again. So the walk is linear in the schemas'
    /// size however many positions share a type, and a break in a named
    /// type is named once, at the first position the walk reaches it by.
    private var met: Set<Visit> = []

    init(readerTypes: TypeResolver, writerTypes: TypeResolver) {
        self.readerTypes = readerTypes
        self.writerTypes = writerTypes
    }

    struct Visit: Hashable {
        var reader: String
        var writer: String
        var readerRules: Rules
        var writerRules: Rules
    }

    /// The rules on one value: a field's and those of every named scalar
    /// its type resolves through, all of them kept at once.
    struct Rules: Hashable {
        var minimums: [TypeSchema.Bound] = []
        var maximums: [TypeSchema.Bound] = []
        var minimumLength: Int?
        var maximumLength: Int?
        var patterns: [String] = []

        init(_ constraints: TypeSchema.Constraints? = nil) {
            self.add(constraints)
        }

        mutating func add(_ constraints: TypeSchema.Constraints?) {
            guard let constraints else { return }
            if let minimum = constraints.minimum { self.minimums.append(minimum) }
            if let maximum = constraints.maximum { self.maximums.append(maximum) }
            if let length = constraints.minimumLength {
                self.minimumLength = max(self.minimumLength ?? length, length)
            }
            if let length = constraints.maximumLength {
                self.maximumLength = min(self.maximumLength ?? length, length)
            }
            if let pattern = constraints.pattern, !self.patterns.contains(pattern) {
                self.patterns.append(pattern)
            }
        }
    }

    /// One side's schema at a position, references followed and optionals
    /// unwrapped.
    struct Unwrapped {
        /// What is left: a kind that is neither a reference nor an
        /// optional, or the reference that did not resolve.
        var core: TypeSchema
        /// Whether an optional wrapped the core: the value may be absent.
        var optional: Bool
        var rules: Rules
        /// The named type the references resolve to, the last one
        /// followed, if any: an alias and the type it names are one.
        var resolved: String?
        /// Why a reference did not resolve, if one did not.
        var failure: Failure?
    }

    enum Failure: Equatable {
        case undefined(String)
        case loop(String)

        func reason(for side: String) -> String {
            switch self {
                case .undefined(let name): "the \(side) has no type \"\(name)\""
                case .loop(let name): "the \(side)'s type \"\(name)\" resolves to itself"
            }
        }
    }

    static func unwrap(_ schema: TypeSchema, rules: Rules, through types: TypeResolver) -> Unwrapped
    {
        var unwrapped = Unwrapped(core: schema, optional: false, rules: rules)
        var followed: [String] = []
        while true {
            switch unwrapped.core {
                case .optional(let wrapped):
                    unwrapped.optional = true
                    unwrapped.core = wrapped
                case .reference(let name):
                    guard !followed.contains(name) else {
                        unwrapped.failure = .loop(name)
                        return unwrapped
                    }
                    guard let definition = types.definition(named: name) else {
                        unwrapped.failure = .undefined(name)
                        return unwrapped
                    }
                    followed.append(name)
                    unwrapped.resolved = name
                    unwrapped.rules.add(definition.constraints)
                    unwrapped.core = definition.schema
                default:
                    return unwrapped
            }
        }
    }

    mutating func judge(
        reader readerSchema: TypeSchema,
        readerRules: Rules,
        writer writerSchema: TypeSchema,
        writerRules: Rules,
        at path: String,
        inside visit: (reader: String, writer: String)? = nil
    ) {
        if let visit {
            self.met.insert(
                Visit(
                    reader: visit.reader,
                    writer: visit.writer,
                    readerRules: readerRules,
                    writerRules: writerRules
                )
            )
        }
        let reader = Self.unwrap(readerSchema, rules: readerRules, through: self.readerTypes)
        let writer = Self.unwrap(writerSchema, rules: writerRules, through: self.writerTypes)
        if writer.optional, !reader.optional {
            self.add(path, "required by the reader, optional for the writer")
        }
        switch (reader.failure, writer.failure) {
            case (nil, nil):
                break
            case (.some(let readerFailure), .some(let writerFailure))
            where readerFailure == writerFailure:
                // One name neither side resolves: the same unknown type.
                return
            case (let readerFailure, let writerFailure):
                if let readerFailure { self.add(path, readerFailure.reason(for: "reader")) }
                if let writerFailure { self.add(path, writerFailure.reason(for: "writer")) }
                return
        }
        if let readerName = reader.resolved, let writerName = writer.resolved {
            let pair = Visit(
                reader: readerName,
                writer: writerName,
                readerRules: reader.rules,
                writerRules: writer.rules
            )
            guard self.met.insert(pair).inserted else { return }
        }
        self.judgeRules(reader: reader.rules, writer: writer.rules, at: path)
        self.judgeCores(reader: reader.core, writer: writer.core, at: path)
    }

    private mutating func judgeCores(reader: TypeSchema, writer: TypeSchema, at path: String) {
        switch (reader, writer) {
            case (.array(let readerElement), .array(let writerElement)):
                self.judge(
                    reader: readerElement,
                    readerRules: Rules(),
                    writer: writerElement,
                    writerRules: Rules(),
                    at: path + "[]"
                )
            case (.map(let readerKey, let readerValue), .map(let writerKey, let writerValue)):
                self.judge(
                    reader: readerKey,
                    readerRules: Rules(),
                    writer: writerKey,
                    writerRules: Rules(),
                    at: path + "[key]"
                )
                self.judge(
                    reader: readerValue,
                    readerRules: Rules(),
                    writer: writerValue,
                    writerRules: Rules(),
                    at: path + "[value]"
                )
            case (.structure(let readerFields), .structure(let writerFields)):
                self.judgeFields(reader: readerFields, writer: writerFields, at: path)
            case (.enumeration(let readerCases), .enumeration(let writerCases)):
                self.judgeCases(
                    reader: readerCases.map(\.name),
                    writer: writerCases.map(\.name),
                    at: path
                )
            case (.union(let readerCases), .union(let writerCases)):
                self.judgeCases(
                    reader: readerCases.map(\.name),
                    writer: writerCases.map(\.name),
                    at: path
                )
                var writerByName: [String: TypeSchema.UnionCase] = [:]
                for writerCase in writerCases where writerByName[writerCase.name] == nil {
                    writerByName[writerCase.name] = writerCase
                }
                var judged: Set<String> = []
                for readerCase in readerCases where judged.insert(readerCase.name).inserted {
                    guard let writerCase = writerByName[readerCase.name] else { continue }
                    // A case with no fields leaves its fields map out, and
                    // a reader reads a missing map as one of no fields: only
                    // a field it requires breaks, as for any other map.
                    let casePath = "\(path)(\(readerCase.name))"
                    self.judgeFields(
                        reader: readerCase.fields,
                        writer: writerCase.fields,
                        at: casePath
                    )
                }
            default:
                if reader.isLeaf, reader.tag == writer.tag { return }
                self.add(path, "read as \(Self.kind(reader)), written as \(Self.kind(writer))")
        }
    }

    /// What a field travels under on the wire: its integer key, or its
    /// name when it has none.
    private enum FieldIdentity: Hashable {
        case key(Int)
        case name(String)

        init(_ field: TypeSchema.Field) {
            self = field.key.map(Self.key) ?? .name(field.name)
        }
    }

    private mutating func judgeFields(
        reader: [TypeSchema.Field],
        writer: [TypeSchema.Field],
        at path: String
    ) {
        var writerFields: [FieldIdentity: [TypeSchema.Field]] = [:]
        for field in writer {
            writerFields[FieldIdentity(field), default: []].append(field)
        }
        // A key declared twice pairs up in order: the first with the first.
        var occurrences: [FieldIdentity: Int] = [:]
        func written(_ identity: FieldIdentity) -> TypeSchema.Field? {
            let occurrence = occurrences[identity, default: 0]
            occurrences[identity] = occurrence + 1
            guard let fields = writerFields[identity], occurrence < fields.count else { return nil }
            return fields[occurrence]
        }
        for field in reader {
            let fieldPath = path.isEmpty ? field.name : "\(path).\(field.name)"
            // A reader looks for a field's key, then for its name.
            let match = field.key.flatMap { written(.key($0)) } ?? written(.name(field.name))
            if let match {
                self.judge(
                    reader: field.type,
                    readerRules: Rules(field.constraints),
                    writer: match.type,
                    writerRules: Rules(match.constraints),
                    at: fieldPath
                )
            } else if !Self.unwrap(field.type, rules: Rules(), through: self.readerTypes).optional {
                self.add(fieldPath, "required by the reader, not written")
            }
        }
    }

    private mutating func judgeCases(reader: [String], writer: [String], at path: String) {
        let readerNames = Set(reader)
        let writerNames = Set(writer)
        let readerOnly = Self.distinct(reader.filter { !writerNames.contains($0) })
        let writerOnly = Self.distinct(writer.filter { !readerNames.contains($0) })
        guard !readerOnly.isEmpty, !writerOnly.isEmpty else { return }
        self.add(
            path,
            "renamed or replaced cases: reads \(Self.quoted(readerOnly)), writes \(Self.quoted(writerOnly))"
        )
    }

    /// Every rule the reader requires, the writer must keep.
    private mutating func judgeRules(reader: Rules, writer: Rules, at path: String) {
        for minimum in reader.minimums
        where !writer.minimums.contains(where: { Self.order($0, minimum) == .some(true) }) {
            self.add(
                path,
                "the reader requires a minimum of \(minimum), the writer keeps \(Self.listed(writer.minimums, "minimum"))"
            )
        }
        for maximum in reader.maximums
        where !writer.maximums.contains(where: { Self.order(maximum, $0) == .some(true) }) {
            self.add(
                path,
                "the reader requires a maximum of \(maximum), the writer keeps \(Self.listed(writer.maximums, "maximum"))"
            )
        }
        if let length = reader.minimumLength, (writer.minimumLength ?? .min) < length {
            self.add(
                path,
                "the reader requires a minimum length of \(length), the writer keeps \(writer.minimumLength.map { "a minimum length of \($0)" } ?? "no minimum length")"
            )
        }
        if let length = reader.maximumLength, (writer.maximumLength ?? .max) > length {
            self.add(
                path,
                "the reader requires a maximum length of \(length), the writer keeps \(writer.maximumLength.map { "a maximum length of \($0)" } ?? "no maximum length")"
            )
        }
        for pattern in reader.patterns where !writer.patterns.contains(pattern) {
            self.add(
                path,
                "the reader requires the pattern \(pattern), the writer does not keep it"
            )
        }
    }

    /// Whether `high` is at least `low`, or nil when the two are not
    /// ordered: a number and a duration, or an integer and a floating
    /// number one of which a `Double` holds no exact twin of. Two bounds of
    /// one kind order exactly, and so do an integer and a floating number
    /// both below 2^53 in size, where a value on either side of one is on
    /// the same side of the other whichever way a check converts it.
    static func order(_ high: TypeSchema.Bound, _ low: TypeSchema.Bound) -> Bool? {
        switch (high, low) {
            case (.integer(let high), .integer(let low)):
                return high >= low
            case (.floating(let high), .floating(let low)):
                return high >= low
            case (.duration(let high), .duration(let low)):
                return high >= low
            case (.integer(let integer), .floating(let floating)):
                guard Self.isExact(integer), Self.isExact(floating) else { return nil }
                return Double(integer) >= floating
            case (.floating(let floating), .integer(let integer)):
                guard Self.isExact(integer), Self.isExact(floating) else { return nil }
                return floating >= Double(integer)
            default:
                return nil
        }
    }

    private static let exactLimit = Double(1 << 53)

    private static func isExact(_ integer: Int64) -> Bool {
        integer.magnitude < 1 << 53
    }

    private static func isExact(_ floating: Double) -> Bool {
        floating.magnitude < Self.exactLimit
    }

    private mutating func add(_ path: String, _ reason: String) {
        self.breaks.append(SchemaBreak(path: path, reason: reason))
    }

    private static func listed(_ bounds: [TypeSchema.Bound], _ name: String) -> String {
        bounds.isEmpty
            ? "no \(name)"
            : "a \(name) of " + bounds.map(\.description).joined(separator: " and ")
    }

    private static func distinct(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    private static func quoted(_ names: [String]) -> String {
        names.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    /// A kind in words, for a break's reason.
    static func kind(_ schema: TypeSchema) -> String {
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
            case .optional: "an optional"
            case .array: "an array"
            case .map: "a map"
            case .structure: "a structure"
            case .enumeration: "an enumeration"
            case .union: "a union"
            case .reference(let name): "the type \"\(name)\""
            case .unknown: "a kind this peer does not know"
        }
    }
}

extension TypeSchema {
    /// Whether this kind holds no other schema.
    var isLeaf: Bool {
        switch self {
            case .bool, .int, .uint, .float, .double, .string, .bytes,
                .date, .datetime, .timestamp, .duration, .uuid, .unknown:
                true
            case .optional, .array, .map, .structure, .enumeration, .union, .reference:
                false
        }
    }
}

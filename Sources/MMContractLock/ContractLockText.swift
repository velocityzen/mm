import Foundation
import MMSchema

extension ContractLock {
    /// The lock's file form: Foundation's pretty-printed JSON, keys sorted,
    /// with a final newline. A lock of one method:
    ///
    /// ```json
    /// {
    ///   "fingerprint" : "0x13898f76182373e5",
    ///   "format" : 1,
    ///   "methods" : [
    ///     {
    ///       "access" : "-w-",
    ///       "name" : "journal.append",
    ///       "request" : {
    ///         "structure" : [
    ///           {
    ///             "key" : 0,
    ///             "name" : "line",
    ///             "type" : "string"
    ///           }
    ///         ]
    ///       },
    ///       "response" : {
    ///         "reference" : "journal.Count"
    ///       }
    ///     }
    ///   ],
    ///   "types" : [
    ///     {
    ///       "name" : "journal.Count",
    ///       "schema" : "int"
    ///     }
    ///   ]
    /// }
    /// ```
    ///
    /// Every kind is named: a scalar by its name (`"string"`), a composite
    /// by a key holding its parts (`{"optional": "int"}`,
    /// `{"map": {"key": "string", "value": "int"}}`). A bound or a default
    /// names its kind too (`{"integer": 5}`, `{"floating": 5}`,
    /// `{"duration": "PT30S"}`), since JSON writes the number 5.0 as 5.
    /// The fingerprint is the contents' own (``fingerprint``):
    /// ``parse(_:)`` refuses a lock whose contents no longer match it.
    public var text: String {
        LockText.text(
            of: LockFile(
                format: LockText.format,
                fingerprint: LockText.hexadecimal(self.fingerprint),
                methods: self.methods.map(LockedMethod.init),
                types: self.types.map(LockedType.init)
            )
        )
    }

    /// Reads a lock from its file form (``text``): a format this version
    /// reads, every kind and rule one it knows, and contents that match the
    /// fingerprint they were written with.
    public static func parse(_ text: String) -> Result<ContractLock, ContractLockError> {
        let decoder = LockText.decoder()
        let data = Data(text.utf8)
        let format: Int
        do {
            format = try decoder.decode(LockFormat.self, from: data).format
        } catch {
            return .failure(.malformed(LockText.reason(error)))
        }
        guard format == LockText.format else { return .failure(.unsupportedFormat(format)) }
        let file: LockFile
        do {
            file = try decoder.decode(LockFile.self, from: data)
        } catch {
            return .failure(.malformed(LockText.reason(error)))
        }
        guard let recorded = LockText.fingerprint(file.fingerprint) else {
            return .failure(
                .malformed("the fingerprint \"\(file.fingerprint)\" is not 0x and 16 hex digits")
            )
        }
        let lock = ContractLock(
            methods: file.methods.map(\.signature),
            types: file.types.map(\.definition)
        )
        guard lock.fingerprint == recorded else {
            return .failure(.damaged(recorded: recorded, contents: lock.fingerprint))
        }
        return .success(lock)
    }
}

/// Why a lock could not be read or written.
public enum ContractLockError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The text is not a lock: not JSON, or JSON without a part a lock has,
    /// or with a kind, a rule or an access it does not know.
    case malformed(String)
    /// A lock in a format this version does not read.
    case unsupportedFormat(Int)
    /// The contents no longer match the fingerprint the lock was written
    /// with: edited by hand, or merged. Delete the lock and check again to
    /// write it anew.
    case damaged(recorded: UInt64, contents: UInt64)
    /// The lock file is there but could not be read.
    case unreadable(path: String, reason: String)
    /// The lock file could not be written.
    case unwritable(path: String, reason: String)

    public var description: String {
        switch self {
            case .malformed(let reason):
                "not a contract lock: \(reason)"
            case .unsupportedFormat(let format):
                "a contract lock in format \(format), which this version does not read"
            case .damaged(let recorded, let contents):
                "the lock's contents (\(LockText.hexadecimal(contents))) no longer match its fingerprint (\(LockText.hexadecimal(recorded))): delete the lock and check again to write it anew"
            case .unreadable(let path, let reason):
                "cannot read \(path): \(reason)"
            case .unwritable(let path, let reason):
                "cannot write \(path): \(reason)"
        }
    }
}

/// The JSON coding the lock's file form uses.
enum LockText {
    static let format = 1

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    /// The file form of `file`.
    static func text(of file: LockFile) -> String {
        Self.encoded(file, pretty: true) + "\n"
    }

    /// A compact form of `value`, for ordering elements that share a name.
    static func form(of value: some Encodable) -> String {
        Self.encoded(value, pretty: false)
    }

    private static func encoded(_ value: some Encodable, pretty: Bool) -> String {
        do {
            return String(decoding: try Self.encoder(pretty: pretty).encode(value), as: UTF8.self)
        } catch {
            // Unreachable: every number the lock writes is finite or written
            // as text, and every other value is a string, a boolean or an
            // integer.
            preconditionFailure("a contract lock did not encode: \(error)")
        }
    }

    static func hexadecimal(_ fingerprint: UInt64) -> String {
        let digits = String(fingerprint, radix: 16)
        return "0x" + String(repeating: "0", count: 16 - digits.count) + digits
    }

    static func fingerprint(_ text: String) -> UInt64? {
        guard text.hasPrefix("0x"), text.utf8.count == 18 else { return nil }
        let digits = text.dropFirst(2)
        guard digits.utf8.allSatisfy({ Self.hexadecimalDigits.contains($0) }) else { return nil }
        return UInt64(digits, radix: 16)
    }

    private static let hexadecimalDigits = Set("0123456789abcdef".utf8)

    /// Where a decode failed and why, in one line.
    static func reason(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        let context: DecodingError.Context
        switch error {
            case .typeMismatch(_, let found), .valueNotFound(_, let found),
                .dataCorrupted(let found):
                context = found
            case .keyNotFound(let key, let found):
                return "\(Self.path(found.codingPath + [key])): missing"
            @unknown default:
                return "\(error)"
        }
        let path = Self.path(context.codingPath)
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }
}

/// The part of a lock read first, so a lock in another format is refused
/// as one rather than as malformed.
struct LockFormat: Decodable {
    var format: Int
}

struct LockFile: Codable {
    var format: Int
    var fingerprint: String
    var methods: [LockedMethod]
    var types: [LockedType]
}

/// Builds a decoding error at `container`'s position.
func corrupted(
    _ reason: String,
    at codingPath: [any CodingKey]
) -> DecodingError {
    .dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: reason))
}

struct LockedMethod: Codable {
    var signature: MethodSignature

    init(_ signature: MethodSignature) {
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case name, access, target, request, requestStream, response, responseStream, errors
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.signature.name, forKey: .name)
        try container.encode(LockText.accessText(self.signature.access), forKey: .access)
        try container.encodeIfPresent(self.signature.target, forKey: .target)
        try container.encode(LockedSchema(self.signature.request), forKey: .request)
        try container.encodeIfPresent(
            self.signature.requestStream.map(LockedSchema.init),
            forKey: .requestStream
        )
        try container.encode(LockedSchema(self.signature.response), forKey: .response)
        try container.encodeIfPresent(
            self.signature.responseStream.map(LockedSchema.init),
            forKey: .responseStream
        )
        try container.encodeIfPresent(self.signature.errors.map(LockedSchema.init), forKey: .errors)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accessText = try container.decode(String.self, forKey: .access)
        guard let access = LockText.access(accessText) else {
            throw corrupted(
                "the access \"\(accessText)\" is not r or -, w or -, x or -, and any further bits as +0x and hex",
                at: container.codingPath + [CodingKeys.access]
            )
        }
        self.signature = MethodSignature(
            name: try container.decode(String.self, forKey: .name),
            access: access,
            request: try container.decode(LockedSchema.self, forKey: .request).schema,
            response: try container.decode(LockedSchema.self, forKey: .response).schema,
            requestStream: try container.decodeIfPresent(LockedSchema.self, forKey: .requestStream)?
                .schema,
            responseStream: try container.decodeIfPresent(
                LockedSchema.self,
                forKey: .responseStream
            )?.schema,
            errors: try container.decodeIfPresent(LockedSchema.self, forKey: .errors)?.schema,
            target: try container.decodeIfPresent([EntityPattern].self, forKey: .target)
        )
    }
}

struct LockedType: Codable {
    var definition: TypeDefinition

    init(_ definition: TypeDefinition) {
        self.definition = definition
    }

    enum CodingKeys: String, CodingKey {
        case name, schema, constraints
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.definition.name, forKey: .name)
        try container.encode(LockedSchema(self.definition.schema), forKey: .schema)
        try container.encodeIfPresent(
            self.definition.constraints.map(LockedConstraints.init),
            forKey: .constraints
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.definition = TypeDefinition(
            name: try container.decode(String.self, forKey: .name),
            schema: try container.decode(LockedSchema.self, forKey: .schema).schema,
            constraints: try container.decodeIfPresent(
                LockedConstraints.self,
                forKey: .constraints
            )?
            .constraints
        )
    }
}

/// A schema as the lock writes it: a scalar as its name, a composite as an
/// object with one key, the composite's name, holding its parts.
struct LockedSchema: Codable {
    var schema: TypeSchema

    init(_ schema: TypeSchema) {
        self.schema = schema
    }

    static let scalars: [(name: String, schema: TypeSchema)] = [
        ("bool", .bool), ("int", .int), ("uint", .uint), ("float", .float), ("double", .double),
        ("string", .string), ("bytes", .bytes), ("date", .date), ("datetime", .datetime),
        ("timestamp", .timestamp), ("duration", .duration), ("uuid", .uuid), ("unknown", .unknown),
    ]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case optional, array, map, structure, enumeration, union, reference
    }

    enum MapKeys: String, CodingKey {
        case key, value
    }

    func encode(to encoder: any Encoder) throws {
        if let scalar = Self.scalars.first(where: { $0.schema == self.schema }) {
            var container = encoder.singleValueContainer()
            try container.encode(scalar.name)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.schema {
            case .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime,
                .timestamp, .duration, .uuid, .unknown:
                // Unreachable: written above, as a scalar's name.
                preconditionFailure("a scalar kind missing from the lock's scalar names")
            case .optional(let wrapped):
                try container.encode(LockedSchema(wrapped), forKey: .optional)
            case .array(let element):
                try container.encode(LockedSchema(element), forKey: .array)
            case .map(let key, let value):
                var map = container.nestedContainer(keyedBy: MapKeys.self, forKey: .map)
                try map.encode(LockedSchema(key), forKey: .key)
                try map.encode(LockedSchema(value), forKey: .value)
            case .structure(let fields):
                try container.encode(fields.map(LockedField.init), forKey: .structure)
            case .enumeration(let cases):
                try container.encode(cases.map(\.name), forKey: .enumeration)
            case .union(let cases):
                try container.encode(cases.map(LockedUnionCase.init), forKey: .union)
            case .reference(let name):
                try container.encode(name, forKey: .reference)
        }
    }

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
            let name = try? single.decode(String.self)
        {
            guard let scalar = Self.scalars.first(where: { $0.name == name }) else {
                throw corrupted("\"\(name)\" is not a kind", at: decoder.codingPath)
            }
            self.schema = scalar.schema
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let kind = container.allKeys.first else {
            throw corrupted(
                "a schema is a kind's name or an object with one of the keys \(CodingKeys.allCases.map(\.rawValue).joined(separator: ", "))",
                at: decoder.codingPath
            )
        }
        switch kind {
            case .optional:
                self.schema = .optional(
                    try container.decode(LockedSchema.self, forKey: kind).schema
                )
            case .array:
                self.schema = .array(try container.decode(LockedSchema.self, forKey: kind).schema)
            case .map:
                let map = try container.nestedContainer(keyedBy: MapKeys.self, forKey: kind)
                self.schema = .map(
                    key: try map.decode(LockedSchema.self, forKey: .key).schema,
                    value: try map.decode(LockedSchema.self, forKey: .value).schema
                )
            case .structure:
                self.schema = .structure(
                    fields: try container.decode([LockedField].self, forKey: kind).map(\.field)
                )
            case .enumeration:
                self.schema = .enumeration(
                    cases: try container.decode([String].self, forKey: kind).map {
                        TypeSchema.EnumCase(name: $0)
                    }
                )
            case .union:
                self.schema = .union(
                    cases: try container.decode([LockedUnionCase].self, forKey: kind).map(
                        \.unionCase
                    )
                )
            case .reference:
                self.schema = .reference(try container.decode(String.self, forKey: kind))
        }
    }
}

struct LockedField: Codable {
    var field: TypeSchema.Field

    init(_ field: TypeSchema.Field) {
        self.field = field
    }

    enum CodingKeys: String, CodingKey {
        case key, name, type, constraints
        case defaultValue = "default"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.field.key, forKey: .key)
        try container.encode(self.field.name, forKey: .name)
        try container.encode(LockedSchema(self.field.type), forKey: .type)
        try container.encodeIfPresent(
            self.field.constraints.map(LockedConstraints.init),
            forKey: .constraints
        )
        try container.encodeIfPresent(
            self.field.defaultValue.map(LockedDefault.init),
            forKey: .defaultValue
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.field = TypeSchema.Field(
            key: try container.decodeIfPresent(Int.self, forKey: .key),
            name: try container.decode(String.self, forKey: .name),
            type: try container.decode(LockedSchema.self, forKey: .type).schema,
            constraints: try container.decodeIfPresent(
                LockedConstraints.self,
                forKey: .constraints
            )?
            .constraints,
            defaultValue: try container.decodeIfPresent(LockedDefault.self, forKey: .defaultValue)?
                .defaultValue
        )
    }
}

struct LockedUnionCase: Codable {
    var unionCase: TypeSchema.UnionCase

    init(_ unionCase: TypeSchema.UnionCase) {
        self.unionCase = unionCase
    }

    enum CodingKeys: String, CodingKey {
        case name, fields
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.unionCase.name, forKey: .name)
        if !self.unionCase.fields.isEmpty {
            try container.encode(self.unionCase.fields.map(LockedField.init), forKey: .fields)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.unionCase = TypeSchema.UnionCase(
            name: try container.decode(String.self, forKey: .name),
            fields: try container.decodeIfPresent([LockedField].self, forKey: .fields)?.map(\.field)
                ?? []
        )
    }
}

struct LockedConstraints: Codable {
    var constraints: TypeSchema.Constraints

    init(_ constraints: TypeSchema.Constraints) {
        self.constraints = constraints
    }

    enum CodingKeys: String, CodingKey {
        case minimum, maximum, minimumLength, maximumLength, pattern
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(
            self.constraints.minimum.map(LockedBound.init),
            forKey: .minimum
        )
        try container.encodeIfPresent(
            self.constraints.maximum.map(LockedBound.init),
            forKey: .maximum
        )
        try container.encodeIfPresent(self.constraints.minimumLength, forKey: .minimumLength)
        try container.encodeIfPresent(self.constraints.maximumLength, forKey: .maximumLength)
        try container.encodeIfPresent(self.constraints.pattern, forKey: .pattern)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.constraints = TypeSchema.Constraints(
            minimum: try container.decodeIfPresent(LockedBound.self, forKey: .minimum)?.bound,
            maximum: try container.decodeIfPresent(LockedBound.self, forKey: .maximum)?.bound,
            minimumLength: try container.decodeIfPresent(Int.self, forKey: .minimumLength),
            maximumLength: try container.decodeIfPresent(Int.self, forKey: .maximumLength),
            pattern: try container.decodeIfPresent(String.self, forKey: .pattern)
        )
    }
}

struct LockedBound: Codable {
    var bound: TypeSchema.Bound

    init(_ bound: TypeSchema.Bound) {
        self.bound = bound
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case integer, floating, duration
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.bound {
            case .integer(let value): try container.encode(value, forKey: .integer)
            case .floating(let value): try container.encode(value, forKey: .floating)
            case .duration(let value): try container.encode(value.description, forKey: .duration)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try LockText.onlyKey(of: container, decoder) {
            case .integer: self.bound = .integer(try container.decode(Int64.self, forKey: .integer))
            case .floating:
                self.bound = .floating(try container.decode(Double.self, forKey: .floating))
            case .duration:
                self.bound = .duration(
                    try LockText.duration(container.decode(String.self, forKey: .duration), decoder)
                )
        }
    }
}

struct LockedDefault: Codable {
    var defaultValue: TypeSchema.Default

    init(_ defaultValue: TypeSchema.Default) {
        self.defaultValue = defaultValue
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case bool, integer, floating, string, duration
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.defaultValue {
            case .bool(let value): try container.encode(value, forKey: .bool)
            case .integer(let value): try container.encode(value, forKey: .integer)
            case .floating(let value): try container.encode(value, forKey: .floating)
            case .string(let value): try container.encode(value, forKey: .string)
            case .duration(let value): try container.encode(value.description, forKey: .duration)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try LockText.onlyKey(of: container, decoder) {
            case .bool: self.defaultValue = .bool(try container.decode(Bool.self, forKey: .bool))
            case .integer:
                self.defaultValue = .integer(try container.decode(Int64.self, forKey: .integer))
            case .floating:
                self.defaultValue = .floating(try container.decode(Double.self, forKey: .floating))
            case .string:
                self.defaultValue = .string(try container.decode(String.self, forKey: .string))
            case .duration:
                self.defaultValue = .duration(
                    try LockText.duration(container.decode(String.self, forKey: .duration), decoder)
                )
        }
    }
}

extension LockText {
    /// The one key a tagged value's object holds.
    static func onlyKey<Key: CodingKey & CaseIterable & RawRepresentable<String>>(
        of container: KeyedDecodingContainer<Key>,
        _ decoder: any Decoder
    ) throws -> Key {
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw corrupted(
                "an object with one of the keys \(Key.allCases.map(\.rawValue).joined(separator: ", "))",
                at: decoder.codingPath
            )
        }
        return key
    }

    static func duration(_ text: String, _ decoder: any Decoder) throws -> MMDuration {
        switch MMDuration.parse(text) {
            case .success(let duration): return duration
            case .failure:
                throw corrupted("\"\(text)\" is not a duration's text", at: decoder.codingPath)
        }
    }

    /// An access as `ls` writes it, `rw-`, with any bits past the three
    /// after it as `+0x` and hex, as ``AccessMode``'s description has it.
    static func accessText(_ access: AccessMode) -> String {
        access.description
    }

    static func access(_ text: String) -> AccessMode? {
        let characters = Array(text.utf8)
        guard characters.count >= 3 else { return nil }
        var raw: UInt8 = 0
        for (index, (letter, bit)) in [
            (UInt8(ascii: "r"), 4), (UInt8(ascii: "w"), 2), (UInt8(ascii: "x"), 1),
        ]
        .enumerated() {
            switch characters[index] {
                case letter: raw |= UInt8(bit)
                case UInt8(ascii: "-"): break
                default: return nil
            }
        }
        let rest = characters.dropFirst(3)
        guard !rest.isEmpty else { return AccessMode(rawValue: raw) }
        let prefix = Array("+0x".utf8)
        guard rest.starts(with: prefix) else { return nil }
        let digits = rest.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.first != UInt8(ascii: "0"),
            digits.allSatisfy({ Self.hexadecimalDigits.contains($0) }),
            let unknown = UInt8(String(decoding: digits, as: UTF8.self), radix: 16),
            unknown & AccessMode.all.rawValue == 0
        else { return nil }
        return AccessMode(rawValue: raw | unknown)
    }
}

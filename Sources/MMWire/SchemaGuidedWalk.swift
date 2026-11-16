import MMSchema
import NIOCore

extension MMPackDecoder {
    /// The first place `payload` breaks `schema`: its path and the problem,
    /// in the forms `SchemaValue.validated(against:resolver:path:checkingConstraints:)`
    /// gives them (`"line.tags[2]"`, `"expected string, got integer"`).
    ///
    /// The cold path behind an ingress error. When a typed decode of a
    /// payload fails, the receiver walks the payload's bytes against the
    /// declared schema, by the wire's own rules, to name the field that
    /// failed. The walk never refuses what a decode accepts: it takes any
    /// string for an enumeration and any case name for a union (both decode
    /// to a fallback case), skips unknown keys and later duplicates, and
    /// does not know a field's Swift width. So it can find nothing even
    /// though the decode failed, as for an integer too wide for an `Int8`
    /// field. Then it returns nil and the error names no field.
    public func firstProblem(
        in payload: ByteBuffer,
        against schema: TypeSchema,
        resolver: TypeResolver
    ) -> SchemaValueError? {
        var walk = SchemaGuidedWalk(buffer: payload, resolver: resolver, maxDepth: self.maxDepth)
        return walk.value(schema, path: "", depth: 0)
    }
}

/// One schema-guided walk over a payload's bytes; see
/// ``MMPackDecoder/firstProblem(in:against:resolver:)``.
struct SchemaGuidedWalk {
    var buffer: ByteBuffer
    let resolver: TypeResolver
    let maxDepth: Int

    /// Walks one value of `schema` at `path`, which `depth` containers
    /// enclose. Nil when the value reads as the schema says.
    mutating func value(_ schema: TypeSchema, path: String, depth: Int) -> SchemaValueError? {
        let resolved: TypeSchema
        switch self.resolver.resolve(schema) {
            case .success(let followed):
                resolved = followed
            case .failure(.unresolved(let name)):
                return SchemaValueError(path: path, problem: "names the undefined type \(name)")
            case .failure(.cycle(let name)):
                return SchemaValueError(path: path, problem: "names the type \(name), which refers to itself")
        }
        switch resolved {
            case .optional(let wrapped):
                if self.buffer.peekMessagePackFormat() == MPFormat.nilByte {
                    self.buffer.moveReaderIndex(forwardBy: 1)
                    return nil
                }
                return self.value(wrapped, path: path, depth: depth)
            case .bool:
                return self.read(path, expected: "bool") { $0.readMessagePackBool().map { _ in } }
            case .int:
                return self.read(path, expected: "integer") { $0.readMessagePackInt().map { _ in } }
            case .uint:
                return self.read(path, expected: "unsigned integer") {
                    $0.readMessagePackUInt().map { _ in }
                }
            case .float:
                return self.read(path, expected: "float") { $0.readMessagePackFloat().map { _ in } }
            case .double:
                return self.read(path, expected: "float") { $0.readMessagePackDouble().map { _ in } }
            case .string, .enumeration:
                // Any string decodes as an enumeration: an unrecognized one
                // becomes the fallback case.
                return self.read(path, expected: "string") { $0.readMessagePackString().map { _ in } }
            case .bytes:
                return self.read(path, expected: "bytes") { $0.readMessagePackBinary().map { _ in } }
            case .date:
                return self.read(path, expected: "date") { buffer in
                    Self.catching { _ = try mpReadDate(from: &buffer) }
                }
            case .datetime:
                return self.read(path, expected: "datetime") { buffer in
                    Self.catching { _ = try mpReadDateTime(from: &buffer) }
                }
            case .timestamp:
                return self.read(path, expected: "timestamp") { buffer in
                    Self.catching { _ = try mpReadTimestamp(from: &buffer) }
                }
            case .array(let element):
                return self.array(of: element, path: path, depth: depth)
            case .map(_, let value):
                // Any string or integer key names an entry; the walk leaves
                // a key's kind to the decode.
                return self.map(of: value, path: path, depth: depth)
            case .structure(let fields):
                return self.structure(fields, path: path, depth: depth)
            case .union(let cases):
                return self.union(cases, path: path, depth: depth)
            case .reference, .unknown:
                // A resolved schema is never a reference; an unknown slot
                // takes any value.
                return self.skip(path: path, depth: depth)
        }
    }

    private mutating func array(of element: TypeSchema, path: String, depth: Int) -> SchemaValueError? {
        let inner = depth + 1
        guard inner <= self.maxDepth else { return self.tooDeep(path) }
        let count: Int
        switch self.header(path, expected: "array", { $0.readMessagePackArrayHeader() }) {
            case .success(let read): count = read
            case .failure(let problem): return problem
        }
        for index in 0..<count {
            if let problem = self.value(element, path: MMConstraintPath.element(index, under: path), depth: inner) {
                return problem
            }
        }
        return nil
    }

    /// A map's entries: each key names its entry (an integer key by its
    /// decimal text), and a later entry under a key already seen is
    /// skipped, as a decode keeps the first.
    private mutating func map(
        of valueSchema: TypeSchema,
        path: String,
        depth: Int
    ) -> SchemaValueError? {
        let inner = depth + 1
        guard inner <= self.maxDepth else { return self.tooDeep(path) }
        let count: Int
        switch self.header(path, expected: "map", { $0.readMessagePackMapHeader() }) {
            case .success(let read): count = read
            case .failure(let problem): return problem
        }
        var seen: Set<String> = []
        for _ in 0..<count {
            let format = self.buffer.peekMessagePackFormat()
            let name: String
            switch self.mapKey() {
                case .some(let read):
                    name = read
                case .none:
                    return SchemaValueError(
                        path: path,
                        problem: "expected a string or integer key, got \(Self.wireKind(format))"
                    )
            }
            guard seen.insert(name).inserted else {
                if let problem = self.skip(path: path, depth: inner) { return problem }
                continue
            }
            if let problem = self.value(
                valueSchema,
                path: MMConstraintPath.member(name, under: path),
                depth: inner
            ) {
                return problem
            }
        }
        return nil
    }

    /// A structure's entries, matched to fields by the lookup rules of the
    /// wire: an integer key names the field with that key, a string key the
    /// field with that name. Unknown keys and later duplicates are skipped;
    /// then the first required field no entry named is missing.
    private mutating func structure(
        _ fields: [TypeSchema.Field],
        path: String,
        depth: Int
    ) -> SchemaValueError? {
        let inner = depth + 1
        guard inner <= self.maxDepth else { return self.tooDeep(path) }
        let count: Int
        switch self.header(path, expected: "map", { $0.readMessagePackMapHeader() }) {
            case .success(let read): count = read
            case .failure(let problem): return problem
        }
        var seen: Set<Int> = []
        for _ in 0..<count {
            let index = self.fieldKey(fields)
            guard let index, seen.insert(index).inserted else {
                if let problem = self.skip(path: path, depth: inner) { return problem }
                continue
            }
            let field = fields[index]
            if let problem = self.value(
                field.type,
                path: MMConstraintPath.member(field.name, under: path),
                depth: inner
            ) {
                return problem
            }
        }
        return Self.missingField(fields, seen: seen, path: path)
    }

    /// A union's map: key 0 names the case, key 1 holds the case's fields.
    /// An unrecognized case name decodes as the fallback case, its fields
    /// skipped.
    private mutating func union(
        _ cases: [TypeSchema.UnionCase],
        path: String,
        depth: Int
    ) -> SchemaValueError? {
        let inner = depth + 1
        guard inner <= self.maxDepth else { return self.tooDeep(path) }
        let count: Int
        switch self.header(path, expected: "map", { $0.readMessagePackMapHeader() }) {
            case .success(let read): count = read
            case .failure(let problem): return problem
        }
        let casePath = MMConstraintPath.member("case", under: path)
        let fieldsPath = MMConstraintPath.member("fields", under: path)
        let slots = [
            TypeSchema.Field(key: 0, name: "case", type: .string),
            TypeSchema.Field(key: 1, name: "fields", type: .unknown),
        ]
        var caseName: String?
        var fields: ByteBuffer?
        for _ in 0..<count {
            switch self.fieldKey(slots) {
                case 0 where caseName == nil:
                    let format = self.buffer.peekMessagePackFormat()
                    switch self.buffer.readMessagePackString() {
                        case .success(let name):
                            caseName = name
                        case .failure(let error):
                            return SchemaValueError(
                                path: casePath,
                                problem: Self.problem(error, expected: "string", format: format)
                            )
                    }
                case 1 where fields == nil:
                    switch self.buffer.sliceMessagePackValue(currentDepth: inner, cap: self.maxDepth) {
                        case .success(let slice):
                            fields = slice
                        case .failure(let error):
                            return SchemaValueError(
                                path: fieldsPath,
                                problem: Self.problem(error, expected: "map", format: nil)
                            )
                    }
                default:
                    if let problem = self.skip(path: path, depth: inner) { return problem }
            }
        }
        guard let caseName else {
            return SchemaValueError(path: casePath, problem: "missing required field")
        }
        guard let unionCase = cases.first(where: { $0.name == caseName }) else { return nil }
        guard let fields else {
            return Self.missingField(unionCase.fields, seen: [], path: fieldsPath)
        }
        var walk = SchemaGuidedWalk(buffer: fields, resolver: self.resolver, maxDepth: self.maxDepth)
        return walk.structure(unionCase.fields, path: fieldsPath, depth: inner)
    }

    // MARK: - Keys

    /// Reads one structure key and returns the index of the field it names,
    /// or nil, with the key consumed, when it names none.
    private mutating func fieldKey(_ fields: [TypeSchema.Field]) -> Int? {
        switch self.key() {
            case .integer(let key):
                return fields.firstIndex { $0.key.map { Int64($0) } == key }
            case .string(let name):
                return fields.firstIndex { $0.name == name }
            case .neither:
                return nil
        }
    }

    /// Reads one map key as its entry's name: a string as itself, an integer
    /// as its decimal text. Nil, with the key consumed, for any other key.
    private mutating func mapKey() -> String? {
        switch self.key() {
            case .integer(let key): String(key)
            case .string(let name): name
            case .neither: nil
        }
    }

    private enum Key {
        case integer(Int64)
        case string(String)
        case neither
    }

    /// Reads one key. An integer outside `i64`, a string that is not UTF-8,
    /// or a key of any other kind matches nothing: it is skipped whole.
    private mutating func key() -> Key {
        switch self.buffer.readMessagePackInt() {
            case .success(let key):
                return .integer(key)
            case .failure:
                break
        }
        switch self.buffer.readMessagePackString() {
            case .success(let name):
                return .string(name)
            case .failure:
                _ = self.buffer.skipMessagePackValue(maxDepth: self.maxDepth)
                return .neither
        }
    }

    // MARK: - Reading

    private mutating func read(
        _ path: String,
        expected: String,
        _ body: (inout ByteBuffer) -> Result<Void, MMWireError>
    ) -> SchemaValueError? {
        let format = self.buffer.peekMessagePackFormat()
        switch body(&self.buffer) {
            case .success:
                return nil
            case .failure(let error):
                return SchemaValueError(
                    path: path,
                    problem: Self.problem(error, expected: expected, format: format)
                )
        }
    }

    private mutating func header(
        _ path: String,
        expected: String,
        _ body: (inout ByteBuffer) -> Result<Int, MMWireError>
    ) -> Result<Int, SchemaValueError> {
        let format = self.buffer.peekMessagePackFormat()
        return body(&self.buffer).mapError { error in
            SchemaValueError(path: path, problem: Self.problem(error, expected: expected, format: format))
        }
    }

    /// Steps over one value at `depth` that nothing checks.
    private mutating func skip(path: String, depth: Int) -> SchemaValueError? {
        switch self.buffer.skipMessagePackValue(currentDepth: depth, cap: self.maxDepth) {
            case .success:
                return nil
            case .failure(let error):
                return SchemaValueError(
                    path: path,
                    problem: Self.problem(error, expected: "a value", format: nil)
                )
        }
    }

    private func tooDeep(_ path: String) -> SchemaValueError {
        SchemaValueError(path: path, problem: "nests deeper than \(self.maxDepth) levels")
    }

    private static func missingField(
        _ fields: [TypeSchema.Field],
        seen: Set<Int>,
        path: String
    ) -> SchemaValueError? {
        for (index, field) in fields.enumerated() where !seen.contains(index) {
            if case .optional = field.type { continue }
            return SchemaValueError(
                path: MMConstraintPath.member(field.name, under: path),
                problem: "missing required field"
            )
        }
        return nil
    }

    private static func catching(_ body: () throws -> Void) -> Result<Void, MMWireError> {
        do {
            try body()
            return .success(())
        } catch let error as MMWireError {
            return .failure(error)
        } catch {
            return .failure(.decodingFailed(description: "\(error)"))
        }
    }

    // MARK: - Problems

    /// What a failed read says about the value it read: expected one kind and
    /// found `format`, ran past the payload's end, and so on.
    static func problem(_ error: MMWireError, expected: String, format: UInt8?) -> String {
        switch error {
            case .typeMismatch:
                "expected \(expected), got \(Self.wireKind(format))"
            case .truncated:
                "ends before its value does"
            case .numberOutOfRange:
                "is out of range for \(expected)"
            case .invalidUTF8:
                "is not valid UTF-8"
            case .invalidFormat(let byte):
                "holds the reserved byte 0x\(String(byte, radix: 16))"
            case .nestingTooDeep(let limit):
                "nests deeper than \(limit) levels"
            case .decodingFailed(let description):
                description
            default:
                "\(error)"
        }
    }

    /// The MessagePack family a format byte opens, in the words of
    /// ``SchemaValue``'s mismatches.
    static func wireKind(_ format: UInt8?) -> String {
        guard let format else { return "the end of the payload" }
        switch format {
            case MPFormat.nilByte: return "nil"
            case MPFormat.falseByte, MPFormat.trueByte: return "bool"
            case 0x00...0x7f, 0xe0...0xff, 0xcc...0xd3: return "integer"
            case MPFormat.float32, MPFormat.float64: return "float"
            case 0xa0...0xbf, 0xd9...0xdb: return "string"
            case 0xc4...0xc6: return "bytes"
            case 0x90...0x9f, 0xdc, 0xdd: return "array"
            case 0x80...0x8f, 0xde, 0xdf: return "map"
            case 0xc1: return "the reserved byte 0xc1"
            default: return "an extension value"
        }
    }
}

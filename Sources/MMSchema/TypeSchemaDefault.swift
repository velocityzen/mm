extension TypeSchema {
    /// The value a field holds when its key is absent from the wire, declared
    /// as `Field("limit", .int, default: 50)`. A field with a default is an
    /// optional on the wire, so a peer that knows nothing of defaults reads
    /// it as one; the code `#schema` generates holds a plain value and fills
    /// in the default when the key is absent or nil.
    ///
    /// The kind matches the field's: a boolean for `bool`, an integer for
    /// `int` and `uint`, a floating number for `float` and `double`, a
    /// string for `string`, a duration for `duration` (declared as its ISO
    /// 8601 text, `default: "PT30S"`), and for a named type the kind of what
    /// it names: a case's name for an enum, the scalar's kind for an alias.
    ///
    /// ## Wire encoding (fixed)
    ///
    /// The value itself: a MessagePack bool, integer, float64, or string,
    /// and a duration as its canonical ISO 8601 text. An integer reads as
    /// ``integer(_:)`` and any other number as ``floating(_:)``. Text reads
    /// as ``string(_:)``, and on a `duration` field (optionals unwrapped) as
    /// ``duration(_:)`` when it is a duration's text. A default this peer
    /// cannot read decodes as absent, like a key it does not know.
    public enum Default: Sendable, Hashable, CustomStringConvertible {
        case bool(Bool)
        case integer(Int64)
        case floating(Double)
        /// A string, or the name of an enum's case.
        case string(String)
        case duration(MMDuration)

        public var description: String {
            switch self {
                case .bool(let value): "\(value)"
                case .integer(let value): "\(value)"
                case .floating(let value): "\(value)"
                case .string(let value): "\"\(value)\""
                case .duration(let value): "\(value)"
            }
        }
    }
}

extension TypeSchema.Default: SchemaDescribable {
    /// A default is whichever scalar its field takes, and its decoder reads
    /// whichever the value is, so its shape depends on the value: `unknown`
    /// by construction, as for ``TypeSchema/Bound``.
    public static var schema: TypeSchema { .unknown }
}

extension TypeSchema.Default: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case .bool(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .floating(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            // Text on every coder; the wire's `bin` form is for values.
            case .duration(let value): try container.encode(value.description)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .floating(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

extension TypeSchema.Default {
    /// This default as a field of `kind` holds it, or why it cannot be that
    /// field's: a `bool`, `int`, `uint`, `float`, `double` or `string`
    /// field takes a value of its own kind, an integer standing for a
    /// floating number; a `duration` field takes a duration, or text that
    /// reads as one; an enumeration takes one of its case names; every
    /// other kind takes none. The value must keep `constraints`, a `float`
    /// field's as the `Float` the generated code holds.
    package func fitted(
        to kind: TypeSchema,
        constraints: TypeSchema.Constraints?
    ) -> Result<Self, TypeSchema.DefaultRefusal> {
        let fitted: Self
        switch (kind, self) {
            case (.bool, .bool), (.int, .integer), (.string, .string):
                fitted = self
            case (.uint, .integer(let value)) where value >= 0:
                fitted = self
            case (.float, .integer(let value)), (.double, .integer(let value)):
                fitted = .floating(Double(value))
            case (.double, .floating(let value)) where value.isFinite:
                fitted = self
            case (.float, .floating(let value)) where Float(value).isFinite:
                fitted = self
            case (.enumeration(let cases), .string(let name))
            where cases.contains(where: { $0.name == name }):
                fitted = self
            case (.duration, .duration):
                fitted = self
            case (.duration, .string(let text)):
                guard case .success(let value) = MMDuration.parse(text) else {
                    return .failure(.mismatch(self, kind: kind.kindName))
                }
                fitted = .duration(value)
            case (.bool, _), (.int, _), (.uint, _), (.float, _), (.double, _), (.string, _),
                (.enumeration, _), (.duration, _):
                return .failure(.mismatch(self, kind: kind.kindName))
            default:
                return .failure(.unsupported(kind: kind.kindName))
        }
        guard let constraints, let problem = fitted.violation(of: constraints, as: kind) else {
            return .success(fitted)
        }
        return .failure(.constraints(fitted, problem: problem))
    }

    private func violation(
        of constraints: TypeSchema.Constraints,
        as kind: TypeSchema
    ) -> String? {
        switch (kind, self) {
            case (.int, .integer(let value)):
                constraints.violation(of: value)
            case (.uint, .integer(let value)):
                constraints.violation(of: UInt64(value))
            case (.float, .floating(let value)):
                constraints.violation(of: Double(Float(value)))
            case (.double, .floating(let value)):
                constraints.violation(of: value)
            case (.string, .string(let value)):
                constraints.violation(of: value)
            case (.duration, .duration(let value)):
                constraints.violation(of: value)
            default:
                nil
        }
    }
}

extension TypeSchema {
    /// Why a declared default cannot be its field's; see
    /// ``Default/fitted(to:constraints:)``.
    package enum DefaultRefusal: Error, Hashable, CustomStringConvertible {
        /// The field's kind takes no default.
        case unsupported(kind: String)
        /// The default is no value of the field's kind.
        case mismatch(Default, kind: String)
        /// The default breaks the field's constraints.
        case constraints(Default, problem: String)

        package var description: String {
            switch self {
                case .unsupported(let kind):
                    "a field of \(kind) takes no default"
                case .mismatch(let value, let kind):
                    "the default \(value) is no value of \(kind)"
                case .constraints(let value, let problem):
                    "the default \(value) \(problem)"
            }
        }
    }
}

extension TypeSchema {
    /// The same shape with each field's text default read as a duration
    /// where the field's kind, through `optional` and the named scalars in
    /// `definitions`, is `duration`. A duration default travels as text, so
    /// a field decoded on its own reads one as a duration only when its own
    /// type says so; a field of a named scalar needs the type table, which
    /// a discovery response carries (section 8.1 of the wire spec).
    func readingDurationDefaults(through definitions: [String: TypeSchema]) -> TypeSchema {
        self.rewritten(field: { field in
            guard case .string(let text)? = field.defaultValue,
                Self.isDuration(field.type, through: definitions),
                case .success(let duration) = MMDuration.parse(text)
            else { return field }
            var read = field
            read.defaultValue = .duration(duration)
            return read
        })
    }

    /// Whether `schema`, through `optional` and references to named types,
    /// is a duration; false for a reference that never ends.
    private static func isDuration(_ schema: TypeSchema, through definitions: [String: TypeSchema])
        -> Bool
    {
        var current = schema
        var seen: Set<String> = []
        while true {
            switch current {
                case .optional(let wrapped):
                    current = wrapped
                case .reference(let name):
                    guard seen.insert(name).inserted, let next = definitions[name] else {
                        return false
                    }
                    current = next
                case .duration:
                    return true
                default:
                    return false
            }
        }
    }
}

extension SchemaResponse {
    /// The response with every duration default read as a duration, the
    /// named scalars resolved through its own type table.
    func readingDurationDefaults() -> SchemaResponse {
        var table: [String: TypeSchema] = [:]
        for definition in self.types where table[definition.name] == nil {
            table[definition.name] = definition.schema
        }
        var read = self
        read.methods = self.methods.map { method in
            var method = method
            method.request = method.request.readingDurationDefaults(through: table)
            method.response = method.response.readingDurationDefaults(through: table)
            method.requestStream = method.requestStream?.readingDurationDefaults(through: table)
            method.responseStream = method.responseStream?.readingDurationDefaults(through: table)
            method.errors = method.errors?.readingDurationDefaults(through: table)
            return method
        }
        read.types = self.types.map { definition in
            var definition = definition
            definition.schema = definition.schema.readingDurationDefaults(through: table)
            return definition
        }
        return read
    }
}

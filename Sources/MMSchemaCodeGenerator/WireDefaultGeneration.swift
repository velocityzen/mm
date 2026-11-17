import SwiftSyntax

// MARK: - Wire defaults

/// A field's wire default, spelled for the generated code: a `default:` on a
/// field that is not optional. The field travels as an optional whose
/// `TypeSchema.Field.defaultValue` is the default, and its property holds a
/// plain value that reads the default when the key is absent or nil.
struct ParsedWireDefault {
    /// The Swift expression the property holds when the key is absent.
    var swiftExpression: String
    /// The `TypeSchema.Default` expression the described schema serves.
    var schemaLiteral: String
}

/// Checks and spells a block's wire defaults by the runtime's rules
/// (`TypeSchema.Default.fitted(to:constraints:)`): a `bool`, `int`, `uint`,
/// `float`, `double` or `string` field takes a value of its own kind that
/// keeps its constraints, an integer standing for a floating number; a field
/// of the block's `Enum` or of an inline `.enumeration` takes one of its case
/// names, and of the block's `Alias` a value of the alias's scalar that keeps
/// the alias's constraints. Every other kind takes none.
struct WireDefaultResolver {
    let types: [String: ParsedTypeDecl.Payload]

    init(types: [ParsedTypeDecl]) {
        self.types = Dictionary(
            types.map { ($0.name, $0.payload) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func resolve(_ type: ParsedTypeDecl) throws -> ParsedTypeDecl {
        var resolved = type
        switch type.payload {
            case .structure(let fields):
                resolved.payload = .structure(
                    try self.resolve(fields, context: "Type(\"\(type.name)\")")
                )
            case .union(let cases):
                resolved.payload = .union(
                    try cases.map { unionCase in
                        var resolvedCase = unionCase
                        resolvedCase.fields = try self.resolve(
                            unionCase.fields,
                            context: "Union(\"\(type.name)\").Case(\"\(unionCase.name)\")"
                        )
                        return resolvedCase
                    }
                )
            case .enumeration, .alias:
                break
        }
        return resolved
    }

    /// A call's wire fields: its parts' and its own error cases'. The CLI
    /// options never reach the wire, so their `default:` stays a CLI default.
    func resolve(_ call: ParsedCall) throws -> ParsedCall {
        var resolved = call
        let context = "Call(\"\(call.name)\")"
        resolved.request = try self.resolve(call.request, context: "\(context).Request")
        resolved.response = try self.resolve(call.response, context: "\(context).Response")
        resolved.requestStream = try call.requestStream.map {
            try self.resolve($0, context: "\(context).RequestStream")
        }
        resolved.responseStream = try call.responseStream.map {
            try self.resolve($0, context: "\(context).ResponseStream")
        }
        resolved.ownErrors = try call.ownErrors.map {
            try self.resolve($0, context: "\(context) Errors")
        }
        return resolved
    }

    func resolve(_ errorCase: ParsedErrorCase, context: String) throws -> ParsedErrorCase {
        guard case .fields(let fields) = errorCase.payload else { return errorCase }
        var resolved = errorCase
        resolved.payload = .fields(
            try self.resolve(fields, context: "\(context).Case(\"\(errorCase.name)\")")
        )
        return resolved
    }

    func resolve(_ error: ParsedNamedError) throws -> ParsedNamedError {
        var resolved = error
        resolved.fields = try self.resolve(error.fields, context: "Error(\"\(error.name)\")")
        return resolved
    }

    func resolve(_ fields: [ParsedField], context: String) throws -> [ParsedField] {
        try fields.map { field in
            var resolved = field
            resolved.type = try self.resolve(field.type, context: "\(context).\(field.name)")
            resolved.wireDefault = try self.wireDefault(
                for: resolved,
                context: "\(context): field \"\(field.name)\""
            )
            return resolved
        }
    }

    /// Resolves the nested `Field("x") { }` blocks inside a type.
    private func resolve(_ type: ParsedType, context: String) throws -> ParsedType {
        switch type {
            case .optional(let wrapped):
                return .optional(try self.resolve(wrapped, context: context))
            case .array(let element):
                return .array(try self.resolve(element, context: context))
            case .map(let key, let value):
                return .map(key: key, value: try self.resolve(value, context: context))
            case .structure(let name, let fields):
                return .structure(name: name, fields: try self.resolve(fields, context: context))
            default:
                return type
        }
    }

    private func wireDefault(
        for field: ParsedField,
        context: String
    ) throws -> ParsedWireDefault? {
        guard let literal = field.defaultValue else { return nil }
        switch field.type {
            case .optional:
                // An optional field's default is a CLI default.
                return nil
            case .enumeration(let name, let cases):
                return try caseDefault(literal, cases: cases, of: name, context: context)
            case .reference(let name):
                switch self.types[name] {
                    case .enumeration(let cases)?:
                        return try caseDefault(literal, cases: cases, of: name, context: context)
                    case .alias(let scalar, let constraints)?:
                        let fitted = try fittedDefault(
                            literal,
                            kind: scalar,
                            constraints: constraints,
                            context: "\(context) of \(name)"
                        )
                        return ParsedWireDefault(
                            swiftExpression: "\(name)(rawValue: \(fitted.swiftExpression))",
                            schemaLiteral: fitted.schemaLiteral
                        )
                    case .structure?, .union?:
                        throw SchemaMacroError(
                            description:
                                "\(context): a field of \(name), a structure or union, takes no default"
                        )
                    case nil:
                        throw SchemaMacroError(
                            description:
                                "\(context): reference \"\(name)\" does not resolve to an Enum/Type declared in this block"
                        )
                }
            case .external(let path):
                throw SchemaMacroError(
                    description:
                        "\(context): \(path) is declared in another block, which this one cannot check a default against — a cross-schema reference takes no default"
                )
            default:
                return try fittedDefault(
                    literal,
                    kind: field.type,
                    constraints: field.constraints,
                    context: context
                )
        }
    }
}

/// The default of a field of a wire enum, named or inline: one of its case
/// names.
private func caseDefault(
    _ literal: ParsedFieldDefault,
    cases: [ParsedCase],
    of name: String,
    context: String
) throws -> ParsedWireDefault {
    guard case .string(let caseName) = literal,
        cases.contains(where: { $0.name == caseName })
    else {
        throw SchemaMacroError(
            description:
                "\(context): the default must name a case of \(name) (\(cases.map(\.name).joined(separator: ", ")))"
        )
    }
    return ParsedWireDefault(
        swiftExpression: ".`\(caseName)`",
        schemaLiteral: ".string(\(quoted(caseName)))"
    )
}

/// A `default:` literal fitted to a scalar kind, or the reason it cannot be
/// that kind's.
private func fittedDefault(
    _ literal: ParsedFieldDefault,
    kind: ParsedType,
    constraints: ParsedConstraints?,
    context: String
) throws -> ParsedWireDefault {
    func refusal(_ problem: String) -> SchemaMacroError {
        SchemaMacroError(description: "\(context): \(problem)")
    }
    func check(_ problem: String?) throws {
        if let problem { throw refusal("the default \(problem)") }
    }
    switch (kind, literal) {
        case (_, .now):
            throw refusal(
                ".now is a CLI default, read when the command runs; a field that is not optional takes a fixed default"
            )
        case (.bool, .boolean(let text)):
            return ParsedWireDefault(swiftExpression: text, schemaLiteral: ".bool(\(text))")
        case (.int, .integer(let text)), (.uint, .integer(let text)):
            guard let value = integerLiteral(text.filter { $0 != "_" }) else {
                throw refusal("the default \(text) is beyond a 64-bit integer")
            }
            if case .uint = kind, value < 0 {
                throw refusal("the default \(text) is no value of uint")
            }
            try check(constraints?.violation(of: value, text: text))
            return ParsedWireDefault(swiftExpression: text, schemaLiteral: ".integer(\(text))")
        case (.float, .integer(let text)), (.double, .integer(let text)),
            (.float, .floating(let text)), (.double, .floating(let text)):
            let digits = text.filter { $0 != "_" }
            let value: Double
            if case .integer = literal {
                guard let integer = integerLiteral(digits) else {
                    throw refusal("the default \(text) is beyond a 64-bit integer")
                }
                value = Double(integer)
            } else {
                guard let parsed = Double(digits), parsed.isFinite else {
                    throw refusal("the default \(text) is not a finite number")
                }
                value = parsed
            }
            let held: Double
            if case .float = kind {
                guard Float(value).isFinite else {
                    throw refusal("the default \(text) is beyond float")
                }
                // The value the generated `Float` property holds.
                held = Double(Float(value))
            } else {
                held = value
            }
            try check(constraints?.violation(of: held, text: text))
            return ParsedWireDefault(swiftExpression: text, schemaLiteral: ".floating(\(text))")
        case (.string, .string(let value)):
            try check(constraints?.violation(of: value))
            return ParsedWireDefault(
                swiftExpression: quoted(value),
                schemaLiteral: ".string(\(quoted(value)))"
            )
        case (.bool, _), (.int, _), (.uint, _), (.float, _), (.double, _), (.string, _):
            throw refusal("the default \(literal.text) is no value of \(kindName(kind))")
        default:
            throw refusal("a field of \(kindName(kind)) takes no default")
    }
}

extension ParsedFieldDefault {
    /// The literal as written.
    var text: String {
        switch self {
            case .string(let value): quoted(value)
            case .integer(let text), .floating(let text), .boolean(let text): text
            case .now: ".now"
        }
    }
}

extension ParsedConstraints {
    /// Why an integer default breaks these constraints, as the runtime's
    /// `TypeSchema.Constraints.violation(of:)` decides it.
    fileprivate func violation(of value: Int64, text: String) -> String? {
        func isBelow(_ bound: ParsedBound) -> Bool {
            switch bound {
                case .integer(let limit): value < limit
                case .floating(let limit): Double(value) < limit
            }
        }
        func isAbove(_ bound: ParsedBound) -> Bool {
            switch bound {
                case .integer(let limit): value > limit
                case .floating(let limit): Double(value) > limit
            }
        }
        if let minimum, isBelow(minimum) {
            return "\(text) is less than the minimum \(minimum.text)"
        }
        if let maximum, isAbove(maximum) {
            return "\(text) is more than the maximum \(maximum.text)"
        }
        return nil
    }

    /// Why a floating default breaks these constraints.
    fileprivate func violation(of value: Double, text: String) -> String? {
        if let minimum, value < minimum.doubleValue {
            return "\(text) is less than the minimum \(minimum.text)"
        }
        if let maximum, value > maximum.doubleValue {
            return "\(text) is more than the maximum \(maximum.text)"
        }
        return nil
    }

    /// Why a string default breaks these constraints: its length in
    /// Unicode scalars first, then its pattern.
    fileprivate func violation(of value: String) -> String? {
        let length = value.unicodeScalars.count
        if let minimumLength, length < minimumLength {
            return
                "\(quoted(value)) has length \(length), less than the minimum length \(minimumLength)"
        }
        if let maximumLength, length > maximumLength {
            return
                "\(quoted(value)) has length \(length), more than the maximum length \(maximumLength)"
        }
        if let pattern {
            let matches = (try? Regex(pattern)).map { value.wholeMatch(of: $0) != nil } ?? false
            if !matches {
                return "\(quoted(value)) does not match the pattern \(pattern)"
            }
        }
        return nil
    }
}

/// The expression decoding `field` from the keyed container `container`, as
/// synthesized `Decodable` decodes it: `decodeIfPresent` for an optional,
/// `decode` otherwise — and for a field with a wire default,
/// `decodeIfPresent` falling back to the default.
func keyedFieldDecode(_ field: ParsedField, container: String) -> String {
    if case .optional(let wrapped) = field.type {
        return
            "try \(container).decodeIfPresent(\(swiftType(wrapped)).self, forKey: .\(field.name))"
    }
    if let wireDefault = field.wireDefault {
        return
            "try \(container).decodeIfPresent(\(swiftType(field.type)).self, forKey: .\(field.name)) ?? \(wireDefault.swiftExpression)"
    }
    return "try \(container).decode(\(swiftType(field.type)).self, forKey: .\(field.name))"
}

/// The field as the wire carries it: optional when it has a wire default.
func wireField(_ field: ParsedField) -> ParsedField {
    guard field.wireDefault != nil else { return field }
    var wire = field
    wire.type = .optional(field.type)
    return wire
}

// MARK: - Reserved keys and names

/// Parses `Reserved(3, 5, "oldName")`: non-negative integer keys and
/// non-empty names.
func parseReserved(
    _ call: FunctionCallExprSyntax,
    context: String
) throws -> (keys: [Int], names: [String]) {
    guard call.trailingClosure == nil, !call.arguments.isEmpty else {
        throw SchemaMacroError(
            description: "\(context): Reserved(...) lists integer keys and string names"
        )
    }
    var keys: [Int] = []
    var names: [String] = []
    for argument in call.arguments {
        guard argument.label == nil else {
            throw SchemaMacroError(
                description:
                    "\(context): Reserved(...) takes unlabeled keys and names, not \(argument.trimmedDescription)"
            )
        }
        if let literal = argument.expression.as(IntegerLiteralExprSyntax.self) {
            guard let key = Int(literal.literal.text.filter { $0 != "_" }) else {
                throw SchemaMacroError(description: "\(context): unreadable reserved key")
            }
            keys.append(key)
        } else if let name = stringLiteral(argument.expression), !name.isEmpty {
            names.append(name)
        } else {
            throw SchemaMacroError(
                description:
                    "\(context): Reserved(...) takes non-negative integer literals and non-empty string literals, not \(argument.expression.trimmedDescription)"
            )
        }
    }
    return (keys, names)
}

/// Gives every field its key with reserved keys and names held back, by the
/// runtime's rules (`fieldKeys(for:reservedKeys:reservedNames:)`): a field
/// may not take a reserved name or pin a reserved key, and an unpinned
/// field takes the lowest key from 0 that no field pins and no reservation
/// holds. The keys are written into the fields as pins, so later key
/// assignment keeps them.
func reservingKeys(
    _ fields: [ParsedField],
    keys reservedKeys: Set<Int>,
    names reservedNames: Set<String>,
    context: String
) throws -> [ParsedField] {
    var used: Set<Int> = []
    for field in fields {
        if reservedNames.contains(field.name) {
            throw SchemaMacroError(
                description: "\(context): field name \"\(field.name)\" is reserved"
            )
        }
        guard let pin = field.pinnedKey else { continue }
        if reservedKeys.contains(pin) {
            throw SchemaMacroError(
                description: "\(context): field key \(pin) is reserved (\(field.name))"
            )
        }
        if !used.insert(pin).inserted {
            throw SchemaMacroError(description: "duplicate field key \(pin) (\(field.name))")
        }
    }
    used.formUnion(reservedKeys)
    var next = 0
    return fields.map { field in
        guard field.pinnedKey == nil else { return field }
        while used.contains(next) { next += 1 }
        used.insert(next)
        var pinned = field
        pinned.pinnedKey = next
        return pinned
    }
}

// MARK: - Deprecation

/// Extracts a `deprecated:` labeled argument as a literal string (static
/// subset).
func labeledDeprecation(
    _ arguments: LabeledExprListSyntax,
    context: String
) throws -> String? {
    for argument in arguments where argument.label?.text == "deprecated" {
        return try requireDeprecationLiteral(argument.expression, context: context)
    }
    return nil
}

func requireDeprecationLiteral(_ expression: ExprSyntax, context: String) throws -> String {
    guard let literal = stringLiteral(expression) else {
        throw SchemaMacroError(
            description: "\(context): deprecated: must be a literal string (static subset)"
        )
    }
    return literal
}

/// The doc-comment line noting a deprecation.
func deprecationDocLine(_ deprecation: String) -> String {
    deprecation.isEmpty ? "/// Deprecated." : "/// Deprecated: \(docCommentText(deprecation))"
}

/// The attribute deprecating a generated member.
func deprecationAttribute(_ deprecation: String) -> String {
    deprecation.isEmpty
        ? "@available(*, deprecated)"
        : "@available(*, deprecated, message: \(quoted(deprecation)))"
}

/// Where a generated struct keeps a field: a deprecated field's public
/// property is deprecated, so the generated code reads and writes its
/// private storage instead.
func storageName(_ field: ParsedField) -> String {
    field.deprecation == nil ? field.name : "_\(field.name)"
}

/// The help text a deprecated option or argument adds to its description.
func deprecatedHelp(_ description: String?, deprecation: String) -> String {
    let note = deprecation.isEmpty ? "deprecated" : "deprecated: \(deprecation)"
    guard let description else { return note.prefix(1).uppercased() + note.dropFirst() }
    return "\(description) (\(note))"
}

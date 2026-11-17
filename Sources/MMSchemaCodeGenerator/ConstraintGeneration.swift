import SwiftSyntax

// MARK: - The parsed model

/// The rules a field's or an `Alias`'s `constraints:` list declares, read
/// from source: the macro's twin of the runtime DSL's
/// `TypeSchema.Constraints`, checked by the same rules (`problem(applyingTo:)`
/// and `combinedConstraints`).
struct ParsedConstraints: Equatable {
    var minimum: ParsedBound?
    var maximum: ParsedBound?
    var minimumLength: Int?
    var maximumLength: Int?
    var pattern: String?
}

/// One end of a declared range.
enum ParsedBound: Equatable {
    case integer(Int64)
    case floating(Double)
    /// A duration, in attoseconds.
    case duration(Int128)

    /// The bound as a number; nil for a duration.
    var doubleValue: Double? {
        switch self {
            case .integer(let value): Double(value)
            case .floating(let value): value
            case .duration: nil
        }
    }

    /// Whether this bound lies above `other`: exactly for two integers,
    /// which a `Double` cannot tell apart near the ends of `Int64`, and for
    /// two durations. A number and a duration are not ordered.
    func isMore(than other: Self) -> Bool {
        switch (self, other) {
            case (.integer(let value), .integer(let otherValue)):
                return value > otherValue
            case (.duration(let value), .duration(let otherValue)):
                return value > otherValue
            case (.duration, _), (_, .duration):
                return false
            default:
                return self.doubleValue! > other.doubleValue!
        }
    }

    /// The `TypeSchema.Bound` expression.
    var literal: String {
        switch self {
            case .integer(let value): ".integer(\(value))"
            case .floating(let value): ".floating(\(value))"
            case .duration(let attoseconds): ".duration(\(durationExpression(attoseconds)))"
        }
    }

    /// The bound as the runtime's `TypeSchema.Bound` describes it.
    var text: String {
        switch self {
            case .integer(let value): "\(value)"
            case .floating(let value): "\(value)"
            case .duration(let attoseconds): durationText(attoseconds)
        }
    }
}

/// One rule as written, before the list is combined.
private enum ParsedConstraint {
    case range(minimum: ParsedBound?, maximum: ParsedBound?)
    case length(minimum: Int?, maximum: Int?)
    case pattern(String)

    var kind: String {
        switch self {
            case .range: "range"
            case .length: "length"
            case .pattern: "pattern"
        }
    }
}

// MARK: - Parsing

/// Splits a `Field`'s or an `Alias`'s arguments at `constraints:`: the
/// variadic list runs from the argument with that label to the end.
func splitConstraintArguments(
    _ arguments: [LabeledExprSyntax]
) -> (leading: [LabeledExprSyntax], constraints: [ExprSyntax]) {
    guard let start = arguments.firstIndex(where: { $0.label?.text == "constraints" }) else {
        return (arguments, [])
    }
    return (Array(arguments[..<start]), arguments[start...].map(\.expression))
}

/// The constraints a `constraints:` list declares on a value of `type`, or
/// nil for an empty list. As in the runtime DSL, integer bounds on a `float`
/// or `double` value become floating ones, and a rule that does not fit the
/// kind, a second rule of one kind, a non-finite bound or a pattern that
/// does not compile is refused.
func parseConstraints(
    _ expressions: [ExprSyntax],
    for type: ParsedType,
    context: String
) throws -> ParsedConstraints? {
    guard !expressions.isEmpty else { return nil }
    let rules = try expressions.map { try parseConstraint($0, context: context) }
    var seen: Set<String> = []
    for rule in rules where !seen.insert(rule.kind).inserted {
        throw SchemaMacroError(description: "\(context) declares a \(rule.kind) twice")
    }
    var kind = type
    while case .optional(let wrapped) = kind { kind = wrapped }
    let floatingKind: Bool
    switch kind {
        case .float, .double: floatingKind = true
        default: floatingKind = false
    }
    func bound(_ bound: ParsedBound?) throws -> ParsedBound? {
        switch bound {
            case .integer(let value) where floatingKind:
                return .floating(Double(value))
            case .floating(let value):
                guard value.isFinite else {
                    throw SchemaMacroError(description: "\(context) declares a non-finite bound")
                }
                // -0.0 and 0.0 are one bound; keep one encoding of it.
                return .floating(value == 0 ? 0 : value)
            default:
                return bound
        }
    }
    var constraints = ParsedConstraints()
    for rule in rules {
        switch rule {
            case .range(let minimum, let maximum):
                constraints.minimum = try bound(minimum)
                constraints.maximum = try bound(maximum)
            case .length(let minimum, let maximum):
                constraints.minimumLength = minimum
                constraints.maximumLength = maximum
            case .pattern(let pattern):
                constraints.pattern = pattern
        }
    }
    if let problem = constraints.problem(applyingTo: kind) {
        throw SchemaMacroError(description: "\(context): \(problem)")
    }
    return constraints
}

private func parseConstraint(_ expression: ExprSyntax, context: String) throws -> ParsedConstraint {
    if let member = expression.as(MemberAccessExprSyntax.self), member.base == nil,
        member.declName.baseName.text == "nonEmpty"
    {
        return .length(minimum: 1, maximum: nil)
    }
    guard let call = expression.as(FunctionCallExprSyntax.self),
        let member = call.calledExpression.as(MemberAccessExprSyntax.self),
        member.base == nil,
        call.arguments.count == 1,
        let argument = call.arguments.first,
        argument.label == nil
    else {
        throw SchemaMacroError(
            description:
                "\(context): unsupported constraint \(expression.trimmedDescription) — the macro subset supports .range(...), .length(...), .nonEmpty and .pattern(\"...\")"
        )
    }
    let rule = member.declName.baseName.text
    switch rule {
        case "range":
            let (minimum, maximum) = try parseRange(argument.expression, context: context)
            return .range(minimum: minimum, maximum: maximum)
        case "length":
            let (minimum, maximum) = try parseRange(argument.expression, context: context)
            func length(_ bound: ParsedBound?) throws -> Int? {
                switch bound {
                    case nil: return nil
                    case .integer(let value): return Int(value)
                    case .floating, .duration:
                        throw SchemaMacroError(
                            description: "\(context): a length takes integer bounds")
                }
            }
            return .length(minimum: try length(minimum), maximum: try length(maximum))
        case "pattern":
            guard let pattern = stringLiteral(argument.expression) else {
                throw SchemaMacroError(
                    description: "\(context): a pattern is a literal string, not \(argument.expression.trimmedDescription)"
                )
            }
            return .pattern(pattern)
        default:
            throw SchemaMacroError(
                description:
                    "\(context): unsupported constraint .\(rule) — the macro subset supports .range(...), .length(...), .nonEmpty and .pattern(\"...\")"
            )
    }
}

/// Reads a range of numeric literals: `1...1000`, `1...`, `...100`,
/// `0.0...1.0`, `-5...5`; or of `Duration` literals:
/// `.seconds(1)...(.seconds(300))`, `.milliseconds(250)...`. A floating
/// literal at either end makes both ends floating, as Swift infers the
/// runtime overload.
private func parseRange(
    _ expression: ExprSyntax,
    context: String
) throws -> (ParsedBound?, ParsedBound?) {
    let text = expression.trimmedDescription.filter { !$0.isWhitespace && $0 != "_" }
    let parts = text.split(separator: "...", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, !(parts[0].isEmpty && parts[1].isEmpty), !parts[1].hasPrefix("<")
    else {
        throw SchemaMacroError(
            description:
                "\(context): a range is closed or one-sided, of numeric or Duration literals (1...10, 1..., ...10, .seconds(1)...(.seconds(5))), not \(expression.trimmedDescription)"
        )
    }
    func literal(_ text: String) throws -> ParsedBound? {
        guard !text.isEmpty else { return nil }
        if let integer = integerLiteral(text) { return .integer(integer) }
        let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        if digits.first?.isNumber == true, !digits.hasPrefix("0x"), let value = Double(text) {
            return .floating(value)
        }
        if let attoseconds = durationLiteralAttoseconds(text) { return .duration(attoseconds) }
        throw SchemaMacroError(
            description:
                "\(context): a bound is a numeric literal or a Duration literal with an integer count (.seconds(30), .milliseconds(250)), not \(text) — the macro reads bounds from source"
        )
    }
    var minimum = try literal(parts[0])
    var maximum = try literal(parts[1])
    switch (minimum, maximum) {
        case (.duration, .integer?), (.duration, .floating?), (.integer, .duration?),
            (.floating, .duration?):
            throw SchemaMacroError(
                description:
                    "\(context): a range's ends are both numbers or both durations, not \(expression.trimmedDescription)"
            )
        default:
            break
    }
    if case .floating = minimum, case .integer(let value) = maximum { maximum = .floating(Double(value)) }
    if case .floating = maximum, case .integer(let value) = minimum { minimum = .floating(Double(value)) }
    return (minimum, maximum)
}

/// An integer literal as Swift reads it: decimal, or `0x`, `0o`, `0b`, with
/// an optional leading minus.
func integerLiteral(_ text: String) -> Int64? {
    let negative = text.hasPrefix("-")
    let body = negative ? String(text.dropFirst()) : text
    let radix: Int
    let digits: Substring
    if body.hasPrefix("0x") {
        (radix, digits) = (16, body.dropFirst(2))
    } else if body.hasPrefix("0o") {
        (radix, digits) = (8, body.dropFirst(2))
    } else if body.hasPrefix("0b") {
        (radix, digits) = (2, body.dropFirst(2))
    } else {
        (radix, digits) = (10, Substring(body))
    }
    guard !digits.isEmpty, let magnitude = UInt64(digits, radix: radix) else { return nil }
    if negative {
        guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
        return magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude)
    }
    return Int64(exactly: magnitude)
}

extension ParsedConstraints {
    /// Why these constraints cannot apply to a value of `kind` (optionals
    /// already unwrapped), or nil: the rules of the runtime's
    /// `TypeSchema.Constraints.problem(applyingTo:)`.
    func problem(applyingTo kind: ParsedType) -> String? {
        switch kind {
            case .reference(let name):
                return "a field of the named type \(name) takes its constraints from the type"
            case .external(let path):
                return "a field of the type \(path) takes its constraints from the type"
            default:
                break
        }
        if self.minimum != nil || self.maximum != nil {
            let bounds = [self.minimum, self.maximum].compactMap { $0 }
            switch kind {
                case .int, .uint:
                    for bound in bounds {
                        guard case .integer = bound else {
                            return "a range on \(kindName(kind)) takes integer bounds"
                        }
                    }
                case .float, .double:
                    for case .duration in bounds {
                        return "a range on \(kindName(kind)) takes numeric bounds"
                    }
                case .duration:
                    for bound in bounds {
                        guard case .duration = bound else {
                            return "a range on duration takes duration bounds"
                        }
                    }
                default:
                    return
                        "a range applies to int, uint, float, double or duration, not \(kindName(kind))"
            }
        }
        if let minimum, let maximum, minimum.isMore(than: maximum) {
            return "a range's minimum \(minimum.text) is more than its maximum \(maximum.text)"
        }
        if self.minimumLength != nil || self.maximumLength != nil {
            switch kind {
                case .string, .bytes, .array, .map: break
                default:
                    return "a length applies to string, bytes, an array or a map, not \(kindName(kind))"
            }
        }
        if let minimumLength, minimumLength < 0 {
            return "a minimum length is not negative"
        }
        if let maximumLength, maximumLength < 0 {
            return "a maximum length is not negative"
        }
        if let minimumLength, let maximumLength, maximumLength < minimumLength {
            return "a length's minimum \(minimumLength) is more than its maximum \(maximumLength)"
        }
        if let pattern {
            guard case .string = kind else {
                return "a pattern applies to string, not \(kindName(kind))"
            }
            if (try? Regex(pattern)) == nil {
                return "the pattern \(pattern) does not compile"
            }
        }
        return nil
    }

    /// The `TypeSchema.Constraints` expression.
    var literal: String {
        var arguments: [String] = []
        if let minimum { arguments.append("minimum: \(minimum.literal)") }
        if let maximum { arguments.append("maximum: \(maximum.literal)") }
        if let minimumLength { arguments.append("minimumLength: \(minimumLength)") }
        if let maximumLength { arguments.append("maximumLength: \(maximumLength)") }
        if let pattern { arguments.append("pattern: \(quoted(pattern))") }
        return "TypeSchema.Constraints(\(arguments.joined(separator: ", ")))"
    }
}

/// The kind's name in constraint diagnostics, as the runtime names it.
func kindName(_ type: ParsedType) -> String {
    switch type {
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
        case .reference(let name): name
        case .external(let path): path
    }
}

/// Whether `type` is a kind an `Alias` may name.
func isScalarKind(_ type: ParsedType) -> Bool {
    switch type {
        case .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime, .timestamp,
            .duration, .uuid:
            true
        default:
            false
    }
}

/// `Alias("Slug", .string, constraints: ..., description: "...")`.
func parseAliasDecl(_ call: FunctionCallExprSyntax) throws -> ParsedTypeDecl {
    guard let nameExpression = call.arguments.first?.expression,
        let name = stringLiteral(nameExpression)
    else {
        throw SchemaMacroError(description: "Alias requires a literal type-name string")
    }
    guard isValidTypeIdentifier(name) else {
        throw SchemaMacroError(
            description:
                "Alias name \"\(name)\" is not a valid Swift type identifier ([A-Z_][A-Za-z0-9_]*)"
        )
    }
    let context = "Alias(\"\(name)\")"
    guard call.trailingClosure == nil else {
        throw SchemaMacroError(description: "\(context) takes no trailing closure")
    }
    var arguments = Array(call.arguments.dropFirst())
    var description: String?
    var deprecation: String?
    while let last = arguments.last, let label = last.label?.text,
        label == "description" || label == "deprecated"
    {
        if label == "description" {
            guard description == nil else {
                throw SchemaMacroError(description: "\(context) declares description twice")
            }
            description = try requireDescriptionLiteral(last.expression, context: context)
        } else {
            guard deprecation == nil else {
                throw SchemaMacroError(description: "\(context) declares deprecated twice")
            }
            deprecation = try requireDeprecationLiteral(last.expression, context: context)
        }
        arguments.removeLast()
    }
    let (leading, constraintExpressions) = splitConstraintArguments(arguments)
    guard leading.count == 1, let typeArgument = leading.first, typeArgument.label == nil else {
        throw SchemaMacroError(
            description:
                "\(context) takes a scalar kind, then constraints:, then description: and deprecated:"
        )
    }
    let type = try parseType(typeArgument.expression, context: context)
    guard isScalarKind(type) else {
        throw SchemaMacroError(
            description: "\(context) names \(kindName(type)): an Alias names a scalar kind")
    }
    let constraints = try parseConstraints(constraintExpressions, for: type, context: context)
    return ParsedTypeDecl(
        name: name,
        description: description,
        payload: .alias(type, constraints),
        deprecation: deprecation
    )
}

// MARK: - Which values hold constraints

/// The names of the declared types whose values may break a constraint:
/// an `Alias` with constraints, and a structure or union with a constrained
/// field anywhere inside it, through other declared types too.
func constrainedTypeNames(_ types: [ParsedTypeDecl]) -> Set<String> {
    var names: Set<String> = []
    var changed = true
    while changed {
        changed = false
        for type in types where !names.contains(type.name) {
            let constrained: Bool
            switch type.payload {
                case .alias(_, let constraints):
                    constrained = constraints != nil
                case .structure(let fields):
                    constrained = fieldsHoldConstraints(fields, constrained: names)
                case .union(let cases):
                    constrained = cases.contains {
                        fieldsHoldConstraints($0.fields, constrained: names)
                    }
                case .enumeration:
                    constrained = false
            }
            if constrained {
                names.insert(type.name)
                changed = true
            }
        }
    }
    return names
}

func fieldsHoldConstraints(_ fields: [ParsedField], constrained: Set<String>) -> Bool {
    fields.contains { $0.constraints != nil || holdsConstraints($0.type, constrained: constrained) }
}

/// Whether a value of `type` may hold a constrained value: a constrained
/// declared type, a nested structure with a constrained field, or a type
/// declared elsewhere, which may check constraints of its own.
func holdsConstraints(_ type: ParsedType, constrained: Set<String>) -> Bool {
    switch type {
        case .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime, .timestamp,
            .duration, .uuid, .enumeration:
            return false
        case .optional(let wrapped), .array(let wrapped):
            return holdsConstraints(wrapped, constrained: constrained)
        case .map(_, let value):
            return holdsConstraints(value, constrained: constrained)
        case .structure(_, let fields):
            return fieldsHoldConstraints(fields, constrained: constrained)
        case .reference(let name):
            return constrained.contains(name)
        case .external:
            return true
    }
}

private func mentionsExternal(_ type: ParsedType) -> Bool {
    switch type {
        case .optional(let wrapped), .array(let wrapped): mentionsExternal(wrapped)
        case .map(_, let value): mentionsExternal(value)
        case .external: true
        default: false
    }
}

// MARK: - Generated checks

/// The statements checking one value's constraints, in the order
/// `SchemaValue.validated` checks them: the values inside it first, then
/// its own rules. Each returns the first violation it finds. `value` is the
/// Swift expression, `path` the expression of its path, `checker` the
/// expression of its own rules' `ConstraintChecker`.
func constraintCheckLines(
    _ field: ParsedField,
    value: String,
    path: String,
    checker: String,
    constrained: Set<String>
) -> [String] {
    var lines: [String] = []
    if holdsConstraints(field.type, constrained: constrained) {
        // A type declared elsewhere may not check constraints; the overload
        // the compiler picks for it says.
        let call =
            mentionsExternal(field.type)
            ? "MMConstraintPath.violation(in: \(value), at: \(path))"
            : "\(value).constraintViolation(at: \(path))"
        lines.append("if let violation = \(call) { return violation }")
    }
    guard field.constraints != nil else { return lines }
    var kind = field.type
    var unwrapped = value
    var bindings: [String] = []
    var depth = 0
    while case .optional(let wrapped) = kind {
        let name = "value\(depth)"
        bindings.append("let \(name) = \(unwrapped)")
        unwrapped = name
        kind = wrapped
        depth += 1
    }
    let argument: String
    switch kind {
        case .int: argument = "of: Int64(\(unwrapped))"
        case .uint, .double, .string, .duration: argument = "of: \(unwrapped)"
        case .float: argument = "of: Double(\(unwrapped))"
        default: argument = "ofLength: \(unwrapped).count"
    }
    let conditions = bindings + ["let problem = \(checker).violation(\(argument))"]
    lines.append("if \(conditions.joined(separator: ", ")) {")
    lines.append("    return SchemaValueError(path: \(path), problem: problem)")
    lines.append("}")
    return lines
}

/// A struct's `MMConstraintValidating` members: one `ConstraintChecker` per
/// constrained field, kept in `MMConstraintCheckers`, and
/// `constraintViolation(at:)` checking every field in declaration order.
func structConstraintMembers(
    _ keyed: [(field: ParsedField, key: Int)],
    constrained: Set<String>
) -> [String] {
    var lines: [String] = []
    let checked = keyed.filter { $0.field.constraints != nil }
    if !checked.isEmpty {
        lines.append("enum MMConstraintCheckers {")
        for (field, _) in checked {
            lines.append(
                "    static let `\(field.name)` = TypeSchema.ConstraintChecker(\(field.constraints!.literal))"
            )
        }
        lines.append("}")
    }
    var body: [String] = []
    for (field, _) in keyed {
        body.append(
            contentsOf: constraintCheckLines(
                field,
                value: "self.\(storageName(field))",
                path: "MMConstraintPath.member(\(quoted(field.name)), under: path)",
                checker: "MMConstraintCheckers.`\(field.name)`",
                constrained: constrained
            ))
    }
    lines.append(contentsOf: constraintViolationFunction(body))
    return lines
}

/// A union's `MMConstraintValidating` members: a case's fields are checked
/// as a structure's under `path.fields`, as `SchemaValue` names them.
func unionConstraintMembers(
    _ keyedCases: [(ParsedUnionCase, [(field: ParsedField, key: Int)])],
    constrained: Set<String>
) -> [String] {
    var lines: [String] = []
    let checkedCases = keyedCases.filter { _, keyed in
        keyed.contains { $0.field.constraints != nil }
    }
    if !checkedCases.isEmpty {
        lines.append("enum MMConstraintCheckers {")
        for (unionCase, keyed) in checkedCases {
            lines.append("    enum `\(unionCase.name)` {")
            for (field, _) in keyed where field.constraints != nil {
                lines.append(
                    "        static let `\(field.name)` = TypeSchema.ConstraintChecker(\(field.constraints!.literal))"
                )
            }
            lines.append("    }")
        }
        lines.append("}")
    }
    let checkedAtAll = keyedCases.filter { _, keyed in
        keyed.contains {
            $0.field.constraints != nil || holdsConstraints($0.field.type, constrained: constrained)
        }
    }
    guard !checkedAtAll.isEmpty else {
        lines.append(contentsOf: constraintViolationFunction([]))
        return lines
    }
    var body: [String] = []
    body.append("let fieldsPath = MMConstraintPath.member(\"fields\", under: path)")
    body.append("switch self {")
    for (unionCase, keyed) in checkedAtAll {
        // Bind only the fields a check reads, so no binding goes unused.
        let bindings = keyed.enumerated().map { index, entry in
            entry.field.constraints != nil
                || holdsConstraints(entry.field.type, constrained: constrained)
                ? "let field\(index)" : "_"
        }
        body.append("    case .`\(unionCase.name)`(\(bindings.joined(separator: ", "))):")
        for (index, (field, _)) in keyed.enumerated() where bindings[index] != "_" {
            body.append(
                contentsOf: constraintCheckLines(
                    field,
                    value: "field\(index)",
                    path: "MMConstraintPath.member(\(quoted(field.name)), under: fieldsPath)",
                    checker: "MMConstraintCheckers.`\(unionCase.name)`.`\(field.name)`",
                    constrained: constrained
                ).map { "        \($0)" })
        }
        body.append("        return nil")
    }
    body.append("    default:")
    body.append("        return nil")
    body.append("}")
    lines.append(contentsOf: constraintViolationFunction(body, endsWithReturn: true))
    return lines
}

func constraintViolationFunction(_ body: [String], endsWithReturn: Bool = false) -> [String] {
    var lines = ["public func constraintViolation(at path: String) -> SchemaValueError? {"]
    lines.append(contentsOf: body.map { "    \($0)" })
    if !endsWithReturn { lines.append("    return nil") }
    lines.append("}")
    return lines
}

/// The wrapper struct an `Alias` generates: its scalar as `rawValue`,
/// coded as the bare scalar, described as its qualified reference, and
/// checking its constraints.
func generateAlias(
    _ name: String,
    scalar: ParsedType,
    constraints: ParsedConstraints?,
    qualified: String,
    description: String?,
    deprecation: String?
) -> String {
    let raw = swiftType(scalar)
    var conformances = [
        "RawRepresentable", "Codable", "Hashable", "Sendable", "SchemaDescribable",
        "MMPackCodable", "MMConstraintValidating",
    ]
    var literalInitializers: [String] = []
    switch scalar {
        case .string:
            conformances.append("ExpressibleByStringLiteral")
            literalInitializers.append(
                "public init(stringLiteral value: String) { self.rawValue = value }")
        case .int:
            conformances.append("ExpressibleByIntegerLiteral")
            literalInitializers.append(
                "public init(integerLiteral value: Int) { self.rawValue = value }")
        case .uint:
            conformances.append("ExpressibleByIntegerLiteral")
            literalInitializers.append(
                "public init(integerLiteral value: UInt64) { self.rawValue = value }")
        case .float, .double:
            conformances.append(contentsOf: ["ExpressibleByFloatLiteral", "ExpressibleByIntegerLiteral"])
            literalInitializers.append(
                "public init(floatLiteral value: \(raw)) { self.rawValue = value }")
            literalInitializers.append(
                "public init(integerLiteral value: Int) { self.rawValue = \(raw)(value) }")
        case .bool:
            conformances.append("ExpressibleByBooleanLiteral")
            literalInitializers.append(
                "public init(booleanLiteral value: Bool) { self.rawValue = value }")
        default:
            break
    }
    var lines: [String] = []
    if let description {
        lines.append("/// \(docCommentText(description))")
    }
    if let deprecation {
        lines.append(deprecationDocLine(deprecation))
    }
    lines.append("public struct \(name): \(conformances.joined(separator: ", ")) {")
    lines.append("    public var rawValue: \(raw)")
    lines.append("    public init(rawValue: \(raw)) { self.rawValue = rawValue }")
    lines.append("    public init(_ rawValue: \(raw)) { self.rawValue = rawValue }")
    lines.append(contentsOf: literalInitializers.map { "    \($0)" })
    lines.append("    public init(from decoder: any Decoder) throws {")
    lines.append("        self.rawValue = try decoder.singleValueContainer().decode(\(raw).self)")
    lines.append("    }")
    lines.append("    public func encode(to encoder: any Encoder) throws {")
    lines.append("        var container = encoder.singleValueContainer()")
    lines.append("        try container.encode(self.rawValue)")
    lines.append("    }")
    lines.append("    public func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {")
    lines.append("        \(mmPackWrite(scalar, value: "self.rawValue"))")
    lines.append("    }")
    lines.append(
        "    public init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {")
    lines.append("        self.rawValue = \(mmPackRead(scalar, level: 0))")
    lines.append("    }")
    lines.append("    public static var schema: TypeSchema {")
    lines.append("        .reference(\(quoted(qualified)))")
    lines.append("    }")
    if let constraints {
        lines.append(
            "    static let constraintChecker = TypeSchema.ConstraintChecker(\(constraints.literal))")
        let field = ParsedField(
            pinnedKey: nil, name: "rawValue", type: scalar, description: nil,
            defaultValue: nil, cliHint: nil, constraints: constraints)
        let body = constraintCheckLines(
            field, value: "self.rawValue", path: "path", checker: "Self.constraintChecker",
            constrained: [])
        lines.append(contentsOf: constraintViolationFunction(body).map { "    \($0)" })
    } else {
        lines.append(contentsOf: constraintViolationFunction([]).map { "    \($0)" })
    }
    lines.append("}")
    return lines.joined(separator: "\n")
}

// MARK: - Descriptors

/// The constraint checks a call's descriptor carries, as its trailing
/// initializer arguments (`, requestCheck: ...`): one for each part the
/// client sends — the request and the request-stream element — whose value
/// may hold a constrained value. `beforeSending` is the expression of
/// whether a client checks before sending.
func descriptorCheckArguments(
    for call: ParsedCall,
    constrained: Set<String>,
    beforeSending: String
) -> String {
    func holds(_ fields: [ParsedField]?, _ payload: ParsedType?) -> Bool {
        if let payload { return holdsConstraints(payload, constrained: constrained) }
        return fields.map { fieldsHoldConstraints($0, constrained: constrained) } ?? false
    }
    func check(_ swiftType: String) -> String {
        "MMConstraintCheck<\(swiftType)>.ifConstrained(beforeSending: \(beforeSending))"
    }
    var arguments: [String] = []
    if holds(call.request, call.requestPayload) {
        arguments.append("requestCheck: \(check(call.requestSwiftType))")
    }
    if call.hasRequestStream, holds(call.requestStream, call.requestStreamPayload) {
        let label = call.hasResponseStream ? "requestElementCheck" : "elementCheck"
        arguments.append("\(label): \(check(call.requestElementSwiftType))")
    }
    return arguments.map { ", \($0)" }.joined()
}

/// The namespace member the generated descriptors read: whether a client
/// checks a request's constraints before sending it. `#if DEBUG` sits in
/// the expansion, so it follows the build of the module that declares the
/// calls, not of mm.
let constraintChecksBeforeSendingDeclaration = """
    /// Whether this namespace's calls check a request's constraints before
    /// sending it: in debug builds of the module that declares them.
    #if DEBUG
    public static let checksConstraintsBeforeSending = true
    #else
    public static let checksConstraintsBeforeSending = false
    #endif
    """

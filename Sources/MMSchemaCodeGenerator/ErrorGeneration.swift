import SwiftSyntax

// MARK: - Parsed errors

/// One entry of an `Errors { ... }` block, as written.
struct ParsedErrorCase {
    enum Payload {
        /// `Case("readOnly", exitCode: 10)`.
        case none
        /// `Case("tooLong", exitCode: 12) { Field("limit", .int) }`.
        case fields([ParsedField])
        /// `Case("conflict", .reference("Conflict"), exitCode: 11)`: a `Type`
        /// or `Error` of the block.
        case type(String)
        /// `Case(.reference("Full"))`: the named error itself.
        case namedError(String)
    }

    var name: String
    /// 0 for `Case(.reference("Full"))`, which takes the named error's.
    var exitCode: Int
    var description: String?
    var payload: Payload
}

/// One `Error("Full", exitCode: 40) { ... }` declaration: a named struct that
/// `Errors` blocks list and error cases carry.
struct ParsedNamedError {
    var name: String
    var exitCode: Int
    var description: String?
    var fields: [ParsedField]
}

/// One error case resolved against its block: the generated enum's case, the
/// union case its signature serves, and the CLI's exit code.
struct ResolvedErrorCase {
    enum Payload {
        /// No fields: `case readOnly`.
        case none
        /// Inline fields: `case tooLong(limit: Int)`.
        case fields([ParsedField])
        /// A named `Type` or `Error` struct: `case full(Full)`. Its fields are
        /// the case's fields on the wire.
        case value(type: String, fields: [ParsedField])
    }

    var name: String
    var exitCode: Int
    var description: String?
    var payload: Payload

    /// The fields the case carries on the wire, keyed from 0.
    var wireFields: [ParsedField] {
        switch self.payload {
            case .none: return []
            case .fields(let fields): return fields
            case .value(_, let fields): return fields
        }
    }
}

/// The exit codes a declared error may take; restates MMSchema's
/// `declaredErrorExitCodes`.
private let declaredErrorExitCodes = 2...63

// MARK: - Parsing

/// Parses an `Errors { ... }` block: `Case(...)` entries, at least one.
func parseErrors(_ call: FunctionCallExprSyntax, context: String) throws -> [ParsedErrorCase] {
    guard call.arguments.isEmpty, let body = call.trailingClosure else {
        throw SchemaMacroError(
            description: "\(context): Errors takes only a trailing closure of Case(...) entries"
        )
    }
    var cases: [ParsedErrorCase] = []
    for item in body.statements {
        guard let entry = item.item.as(FunctionCallExprSyntax.self), calleeName(entry) == "Case"
        else {
            throw SchemaMacroError(
                description: "\(context): only Case(...) entries are supported (static subset)"
            )
        }
        cases.append(try parseErrorCase(entry, context: context))
    }
    guard !cases.isEmpty else {
        throw SchemaMacroError(description: "\(context) declares no cases")
    }
    return cases
}

/// `Case("name", [.reference("Type"),] exitCode: N[, description: "..."])`,
/// with an optional trailing closure of fields — or `Case(.reference("Full"))`,
/// listing a named error.
private func parseErrorCase(
    _ call: FunctionCallExprSyntax,
    context: String
) throws -> ParsedErrorCase {
    var arguments = Array(call.arguments)
    if arguments.count == 1, let only = arguments.first, only.label == nil,
        let reference = only.expression.as(FunctionCallExprSyntax.self),
        let name = try referencedTypeName(reference, context: context)
    {
        guard call.trailingClosure == nil else {
            throw SchemaMacroError(
                description:
                    "\(context).Case(.reference(\"\(name)\")): a listed Error carries its own fields"
            )
        }
        return ParsedErrorCase(
            name: errorCaseName(forNamedError: name),
            exitCode: 0,
            description: nil,
            payload: .namedError(name)
        )
    }
    guard let first = arguments.first, first.label == nil,
        let name = stringLiteral(first.expression)
    else {
        throw SchemaMacroError(description: "\(context): Case requires a literal name string")
    }
    arguments.removeFirst()
    let caseContext = "\(context).Case(\"\(name)\")"
    guard isValidSwiftIdentifierish(name) else {
        throw SchemaMacroError(
            description:
                "\(caseContext): the case name must be a Swift identifier — it is both the wire tag and the generated case"
        )
    }
    guard name != "unknown" else {
        throw SchemaMacroError(
            description:
                "\(caseContext): \"unknown\" is reserved — generated error enums decode unrecognized cases to it"
        )
    }
    var payload = ParsedErrorCase.Payload.none
    if let second = arguments.first, second.label == nil {
        guard let call = second.expression.as(FunctionCallExprSyntax.self),
            let typeName = try referencedTypeName(call, context: caseContext)
        else {
            throw SchemaMacroError(
                description:
                    "\(caseContext): an error case carries a Type or Error of this block: .reference(\"Name\")"
            )
        }
        payload = .type(typeName)
        arguments.removeFirst()
    }
    var exitCode: Int?
    var description: String?
    for argument in arguments {
        switch argument.label?.text {
            case "exitCode":
                exitCode = try parseExitCode(argument.expression, context: caseContext)
            case "description":
                description = try requireDescriptionLiteral(
                    argument.expression,
                    context: caseContext
                )
            default:
                throw SchemaMacroError(
                    description:
                        "\(caseContext): unsupported argument \(argument.expression.trimmedDescription)"
                )
        }
    }
    guard let exitCode else {
        throw SchemaMacroError(
            description: "\(caseContext) requires exitCode: — the generated CLI exits with it"
        )
    }
    if let closure = call.trailingClosure {
        guard case .none = payload else {
            throw SchemaMacroError(
                description:
                    "\(caseContext): a case carries either a .reference(...) or fields, not both"
            )
        }
        let fields = try parseFields(closure, context: caseContext)
        try rejectNestedStructures(in: fields, context: caseContext)
        if !fields.isEmpty {
            payload = .fields(fields)
        }
    }
    return ParsedErrorCase(
        name: name,
        exitCode: exitCode,
        description: description,
        payload: payload
    )
}

/// `Error("Full", exitCode: N[, description: "..."])`, with an optional
/// trailing closure of fields.
func parseNamedError(_ call: FunctionCallExprSyntax) throws -> ParsedNamedError {
    var arguments = Array(call.arguments)
    guard let first = arguments.first, first.label == nil,
        let name = stringLiteral(first.expression)
    else {
        throw SchemaMacroError(description: "Error requires a literal type-name string")
    }
    arguments.removeFirst()
    let context = "Error(\"\(name)\")"
    guard isValidTypeIdentifier(name) else {
        throw SchemaMacroError(
            description:
                "Error name \"\(name)\" is not a valid Swift type identifier ([A-Z_][A-Za-z0-9_]*)"
        )
    }
    var exitCode: Int?
    var description: String?
    for argument in arguments {
        switch argument.label?.text {
            case "exitCode":
                exitCode = try parseExitCode(argument.expression, context: context)
            case "description":
                description = try requireDescriptionLiteral(argument.expression, context: context)
            default:
                throw SchemaMacroError(
                    description:
                        "\(context): unsupported argument \(argument.expression.trimmedDescription)"
                )
        }
    }
    guard let exitCode else {
        throw SchemaMacroError(
            description: "\(context) requires exitCode: — the generated CLI exits with it"
        )
    }
    let fields = try call.trailingClosure.map { try parseFields($0, context: context) } ?? []
    return ParsedNamedError(
        name: name,
        exitCode: exitCode,
        description: description,
        fields: fields
    )
}

/// The `exitCode:` argument: an integer literal in 2...63.
private func parseExitCode(_ expression: ExprSyntax, context: String) throws -> Int {
    guard let literal = expression.as(IntegerLiteralExprSyntax.self),
        let value = Int(literal.literal.text.filter { $0 != "_" }),
        declaredErrorExitCodes.contains(value)
    else {
        throw SchemaMacroError(
            description:
                "\(context): exitCode must be an integer literal in \(declaredErrorExitCodes.lowerBound)...\(declaredErrorExitCodes.upperBound) — 0 and 1 mean success and an undeclared failure, 64 and up are sysexits and the shell's"
        )
    }
    return value
}

/// The name in `.reference("Name")`, or nil for anything else. A dotted or
/// otherwise invalid name is an error: an error case carries a type of its
/// own block.
private func referencedTypeName(
    _ call: FunctionCallExprSyntax,
    context: String
) throws -> String? {
    guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
        member.base == nil,
        member.declName.baseName.text == "reference",
        call.arguments.count == 1,
        let argument = call.arguments.first, argument.label == nil,
        let name = stringLiteral(argument.expression)
    else {
        return nil
    }
    guard isValidTypeIdentifier(name) else {
        throw SchemaMacroError(
            description:
                "\(context): .reference(\"\(name)\") must name a Type or Error of this block"
        )
    }
    return name
}

/// Inline error fields stay flat: a namespace error's case is lifted into
/// every call's enum, and a nested struct or enum would be a different type
/// in each.
private func rejectNestedStructures(in fields: [ParsedField], context: String) throws {
    for field in fields where !nestedStructures(in: [field]).isEmpty {
        throw SchemaMacroError(
            description:
                "\(context): field \"\(field.name)\" declares a nested struct — declare a Type and carry it with Case(\"name\", .reference(\"Type\"), exitCode:)"
        )
    }
    for field in fields where inlineEnumeration(in: field.type) != nil {
        throw SchemaMacroError(
            description:
                "\(context): field \"\(field.name)\" declares an inline .enumeration — declare an Enum and name it: Field(\"\(field.name)\", \"Name\")"
        )
    }
}

/// The case a named error becomes in an `Errors` block: its leading capitals
/// lowered, keeping the last one when it starts the next word — `Full` →
/// `full`, `URLTooLong` → `urlTooLong`. Restates MMSchema's
/// `errorCaseName(forNamedError:)`; a property test checks they agree.
package func errorCaseName(forNamedError name: String) -> String {
    let characters = Array(name)
    var capitals = 0
    while capitals < characters.count, characters[capitals].isUppercase {
        capitals += 1
    }
    let lowered =
        capitals > 1 && capitals < characters.count && characters[capitals].isLowercase
        ? capitals - 1 : capitals
    return String(characters[..<lowered]).lowercased() + String(characters[lowered...])
}

// MARK: - Resolution and validation

/// Resolves the block's errors into `contract`: the named errors, the
/// namespace's cases, and each call's full set (the namespace's, then its
/// own). Fails on what the runtime DSL refuses, at expansion instead of at
/// first use: duplicate names, a case reusing a namespace error's name, two
/// errors sharing an exit code, references that do not resolve, and
/// generated names (`Error`, `AppendError`) colliding with declarations.
func resolveErrors(
    in contract: inout ParsedContract,
    namedErrors: [ParsedNamedError],
    namespaceErrors: [ParsedErrorCase],
    generatedNames: Set<String>
) throws {
    let typeNames = Set(contract.types.map(\.name))
    var claimed = generatedNames
    var named: [String: ParsedNamedError] = [:]
    for error in namedErrors {
        let context = "Error(\"\(error.name)\")"
        guard error.name != "Error" else {
            throw SchemaMacroError(
                description:
                    "\(context): \"Error\" is the namespace's generated error enum — name the error after what failed"
            )
        }
        guard named.updateValue(error, forKey: error.name) == nil else {
            throw SchemaMacroError(description: "\(context) is declared twice")
        }
        guard claimed.insert(error.name).inserted else {
            throw SchemaMacroError(
                description:
                    "\(context) collides with another declaration — rename the Error or the Type/Enum"
            )
        }
        try checkReferences(in: error.fields, typeNames: typeNames, context: context)
    }
    var structures: [String: [ParsedField]] = [:]
    for type in contract.types {
        if case .structure(let fields) = type.payload {
            structures[type.name] = fields
        }
    }
    let scope = ErrorResolutionScope(
        namedErrors: named,
        structures: structures,
        typeNames: typeNames
    )
    let namespace = try scope.resolve(namespaceErrors, context: "#schema Errors")
    if !namespace.isEmpty {
        guard claimed.insert("Error").inserted else {
            throw SchemaMacroError(
                description:
                    "the namespace's generated error enum \"Error\" collides with another declaration — rename it"
            )
        }
    }
    for index in contract.calls.indices {
        let call = contract.calls[index]
        let context = "Call(\"\(call.name)\")"
        let own = try scope.resolve(call.ownErrors, context: "\(context) Errors")
        let errors = try flattenedErrors(namespace: namespace, own: own, context: context)
        contract.calls[index].errors = errors
        guard errors.isEmpty || claimed.insert(call.errorTypeName).inserted else {
            throw SchemaMacroError(
                description:
                    "\(context): generated error enum \"\(call.errorTypeName)\" collides with another declaration — rename the Type/Enum/Error"
            )
        }
    }
    contract.namedErrors = namedErrors
    contract.namespaceErrors = namespace
}

/// A call's full error set: the namespace's errors, then its own.
private func flattenedErrors(
    namespace: [ResolvedErrorCase],
    own: [ResolvedErrorCase],
    context: String
) throws -> [ResolvedErrorCase] {
    let namespaceNames = Set(namespace.map(\.name))
    for error in own where namespaceNames.contains(error.name) {
        throw SchemaMacroError(
            description:
                "\(context): error \"\(error.name)\" is also a namespace error — a call's errors add to the namespace's"
        )
    }
    let all = namespace + own
    var owners: [Int: String] = [:]
    for error in all {
        if let owner = owners.updateValue(error.name, forKey: error.exitCode) {
            throw SchemaMacroError(
                description:
                    "\(context): errors \"\(owner)\" and \"\(error.name)\" share exit code \(error.exitCode)"
            )
        }
    }
    return all
}

/// What an `Errors` block's cases resolve against.
private struct ErrorResolutionScope {
    let namedErrors: [String: ParsedNamedError]
    let structures: [String: [ParsedField]]
    let typeNames: Set<String>

    func resolve(_ cases: [ParsedErrorCase], context: String) throws -> [ResolvedErrorCase] {
        var seen: Set<String> = []
        return try cases.map { errorCase in
            let resolved = try self.resolve(errorCase, context: context)
            guard seen.insert(resolved.name).inserted else {
                throw SchemaMacroError(
                    description: "\(context) declares error \"\(resolved.name)\" twice"
                )
            }
            return resolved
        }
    }

    private func resolve(
        _ errorCase: ParsedErrorCase,
        context: String
    ) throws -> ResolvedErrorCase {
        let caseContext = "\(context).Case(\"\(errorCase.name)\")"
        switch errorCase.payload {
            case .none:
                return ResolvedErrorCase(
                    name: errorCase.name,
                    exitCode: errorCase.exitCode,
                    description: errorCase.description,
                    payload: .none
                )
            case .fields(let fields):
                try checkReferences(in: fields, typeNames: self.typeNames, context: caseContext)
                return ResolvedErrorCase(
                    name: errorCase.name,
                    exitCode: errorCase.exitCode,
                    description: errorCase.description,
                    payload: .fields(fields)
                )
            case .type(let typeName):
                guard let fields = self.namedErrors[typeName]?.fields ?? self.structures[typeName]
                else {
                    let kind =
                        self.typeNames.contains(typeName) ? "an Enum or Union" : "no declaration"
                    throw SchemaMacroError(
                        description:
                            "\(caseContext): carries \"\(typeName)\", \(kind) of this block — an error case carries a Type or Error"
                    )
                }
                return ResolvedErrorCase(
                    name: errorCase.name,
                    exitCode: errorCase.exitCode,
                    description: errorCase.description,
                    payload: .value(type: typeName, fields: fields)
                )
            case .namedError(let errorName):
                guard let named = self.namedErrors[errorName] else {
                    throw SchemaMacroError(
                        description:
                            "\(context): Case(.reference(\"\(errorName)\")) names no Error declared in this block"
                    )
                }
                guard errorCase.name != "unknown" else {
                    throw SchemaMacroError(
                        description:
                            "\(context): Error(\"\(errorName)\") becomes the case \"unknown\", which is reserved"
                    )
                }
                return ResolvedErrorCase(
                    name: errorCase.name,
                    exitCode: named.exitCode,
                    description: named.description,
                    payload: .value(type: errorName, fields: named.fields)
                )
        }
    }
}

/// Every reference in error fields must name a `Type`, `Enum` or `Union` of
/// the block. A named `Error` is not a type a field can hold.
private func checkReferences(
    in fields: [ParsedField],
    typeNames: Set<String>,
    context: String
) throws {
    func check(_ type: ParsedType, context: String) throws {
        switch type {
            case .bool, .int, .uint, .float, .double, .string, .bytes,
                .date, .datetime, .timestamp, .duration, .uuid, .enumeration, .external:
                break
            case .optional(let wrapped), .array(let wrapped):
                try check(wrapped, context: context)
            case .map(let key, let value):
                try check(key, context: context)
                try check(value, context: context)
            case .structure(_, let nested):
                for field in nested {
                    try check(field.type, context: "\(context).\(field.name)")
                }
            case .reference(let name):
                guard typeNames.contains(name) else {
                    throw SchemaMacroError(
                        description:
                            "\(context): reference \"\(name)\" does not resolve to an Enum/Type/Union declared in this block"
                    )
                }
        }
    }
    for field in fields {
        try check(field.type, context: "\(context).\(field.name)")
    }
}

// MARK: - Generation

/// The named error structs, the namespace's `Error` enum, and each call's
/// `<Call>Error` enum.
func generateErrorTypes(
    for contract: ParsedContract,
    constrained: Set<String>
) throws -> [String] {
    var declarations: [String] = []
    for error in contract.namedErrors {
        var declaration = try generateStruct(
            name: error.name,
            fields: error.fields,
            namespace: contract.namespace,
            describedAs: .structure,
            constrained: constrained,
            conformingTo: ["Swift.Error"]
        )
        if let description = error.description {
            declaration = "/// \(docCommentText(description))\n" + declaration
        }
        declarations.append(declaration)
    }
    if !contract.namespaceErrors.isEmpty {
        declarations.append(
            try generateErrorEnum(
                name: "Error",
                documentation: "The errors every call in the namespace can fail with.",
                cases: contract.namespaceErrors,
                namespace: contract.namespace,
                lifting: []
            )
        )
    }
    for call in contract.calls where !call.errors.isEmpty {
        declarations.append(
            try generateErrorEnum(
                name: call.errorTypeName,
                documentation:
                    "The errors `\(call.descriptorName)` can fail with: the namespace's, then its own.",
                cases: call.errors,
                namespace: contract.namespace,
                lifting: contract.namespaceErrors
            )
        )
    }
    return declarations
}

/// One error enum: a case per declared error plus `unknown(String)`, its
/// union wire form as `Codable` (`{0: "<case>", 1: <fields>}`, key 1 left
/// out for a case without fields), its `declaredErrors` union, and — for a
/// call's enum in a namespace with errors — `init(_:)` lifting the
/// namespace's `Error` into it.
private func generateErrorEnum(
    name: String,
    documentation: String,
    cases: [ResolvedErrorCase],
    namespace: String,
    lifting namespaceCases: [ResolvedErrorCase]
) throws -> String {
    var lines: [String] = []
    lines.append("/// \(documentation)")
    lines.append("public enum \(name): MMDeclaredError {")
    for errorCase in cases {
        if let description = errorCase.description {
            lines.append("    /// \(docCommentText(description))")
        }
        lines.append("    case `\(errorCase.name)`\(associatedValues(errorCase))")
    }
    lines.append("    /// A declared error this build does not know, by the case name it")
    lines.append("    /// arrived with.")
    lines.append("    case unknown(String)")

    lines.append("    public static var declaredErrors: TypeSchema {")
    lines.append("        .union(cases: [")
    for errorCase in cases {
        let keyed = try assignKeys(errorCase.wireFields, startingAt: 0, reserving: [])
        var literal =
            "TypeSchema.UnionCase(name: \(quoted(errorCase.name)), fields: [\(try fieldLiterals(keyed, namespace: namespace))]"
        if let description = errorCase.description {
            literal += ", description: \(quoted(description))"
        }
        lines.append("            \(literal)),")
    }
    lines.append("        ])")
    lines.append("    }")

    lines.append("    public var caseName: String {")
    lines.append("        switch self {")
    for errorCase in cases {
        lines.append("            case .`\(errorCase.name)`: return \(quoted(errorCase.name))")
    }
    lines.append("            case .unknown(let name): return name")
    lines.append("        }")
    lines.append("    }")

    if !namespaceCases.isEmpty {
        lines.append("    /// Lifts one of the namespace's errors into this call's.")
        lines.append("    public init(_ error: Error) {")
        lines.append("        switch error {")
        for errorCase in namespaceCases {
            switch errorCase.payload {
                case .none:
                    lines.append(
                        "            case .`\(errorCase.name)`: self = .`\(errorCase.name)`"
                    )
                case .value:
                    lines.append(
                        "            case .`\(errorCase.name)`(let value): self = .`\(errorCase.name)`(value)"
                    )
                case .fields(let fields):
                    let keyed = fields.map { (field: $0, key: 0) }
                    let arguments = fields.indices.map { "\(fields[$0].name): field\($0)" }
                    lines.append(
                        "            case .`\(errorCase.name)`\(unionBindings(keyed)): self = .`\(errorCase.name)`(\(arguments.joined(separator: ", ")))"
                    )
            }
        }
        lines.append("            case .unknown(let name): self = .unknown(name)")
        lines.append("        }")
        lines.append("    }")
    }

    lines.append("    enum CodingKeys: Int, CodingKey {")
    lines.append("        case `case` = 0")
    lines.append("        case fields = 1")
    lines.append("    }")
    var keyedInline: [String: [(field: ParsedField, key: Int)]] = [:]
    for errorCase in cases {
        guard case .fields(let fields) = errorCase.payload else { continue }
        let keyed = try assignKeys(fields, startingAt: 0, reserving: [])
        keyedInline[errorCase.name] = keyed
        lines.append("    enum \(codingKeysName(errorCase)): Int, CodingKey {")
        for (field, key) in keyed {
            lines.append("        case \(field.name) = \(key)")
        }
        lines.append("    }")
    }

    lines.append("    public init(from decoder: any Decoder) throws {")
    lines.append("        let container = try decoder.container(keyedBy: CodingKeys.self)")
    lines.append("        switch try container.decode(String.self, forKey: .`case`) {")
    for errorCase in cases {
        lines.append("            case \(quoted(errorCase.name)):")
        switch errorCase.payload {
            case .none:
                lines.append("                self = .`\(errorCase.name)`")
            case .value(let type, let fields) where fields.isEmpty:
                lines.append("                self = .`\(errorCase.name)`(\(type)())")
            case .value(let type, let fields):
                let decode =
                    "self = .`\(errorCase.name)`(try container.decode(\(type).self, forKey: .fields))"
                // A case whose type had no fields left key 1 out.
                guard let absent = absentFieldValues(fields) else {
                    lines.append("                \(decode)")
                    continue
                }
                let arguments = zip(fields, absent).map { "\($0.name): \($1)" }
                lines.append("                if container.contains(.fields) {")
                lines.append("                    \(decode)")
                lines.append("                } else {")
                lines.append(
                    "                    self = .`\(errorCase.name)`(\(type)(\(arguments.joined(separator: ", "))))"
                )
                lines.append("                }")
            case .fields:
                let keyed = keyedInline[errorCase.name] ?? []
                let values = keyed.map { field, _ in
                    "\(field.name): \(keyedFieldDecode(field, container: "fields"))"
                }
                var decode = [
                    "let fields = try container.nestedContainer(keyedBy: \(codingKeysName(errorCase)).self, forKey: .fields)",
                    "self = .`\(errorCase.name)`(",
                ]
                decode.append(values.map { "    \($0)" }.joined(separator: ",\n"))
                decode.append(")")
                // A case that had no fields left key 1 out.
                guard let absent = absentFieldValues(keyed.map(\.field)) else {
                    lines.append(contentsOf: decode.map { indented($0, by: 16) })
                    continue
                }
                lines.append("                if container.contains(.fields) {")
                lines.append(contentsOf: decode.map { indented($0, by: 20) })
                lines.append("                } else {")
                lines.append(
                    "                    self = .`\(errorCase.name)`(\(absentArguments(keyed, absent)))"
                )
                lines.append("                }")
        }
    }
    lines.append("            case let name:")
    lines.append("                self = .unknown(name)")
    lines.append("        }")
    lines.append("    }")

    lines.append("    public func encode(to encoder: any Encoder) throws {")
    lines.append("        var container = encoder.container(keyedBy: CodingKeys.self)")
    lines.append("        try container.encode(self.caseName, forKey: .`case`)")
    lines.append("        switch self {")
    for errorCase in cases {
        switch errorCase.payload {
            case .none:
                lines.append("            case .`\(errorCase.name)`:")
                lines.append("                break")
            case .value(_, let fields) where fields.isEmpty:
                lines.append("            case .`\(errorCase.name)`:")
                lines.append("                break")
            case .value:
                lines.append("            case .`\(errorCase.name)`(let value):")
                lines.append("                try container.encode(value, forKey: .fields)")
            case .fields:
                let keyed = keyedInline[errorCase.name] ?? []
                lines.append("            case .`\(errorCase.name)`\(unionBindings(keyed)):")
                lines.append(
                    "                var fields = container.nestedContainer(keyedBy: \(codingKeysName(errorCase)).self, forKey: .fields)"
                )
                for (index, (field, _)) in keyed.enumerated() {
                    let method =
                        if case .optional = field.type { "encodeIfPresent" } else { "encode" }
                    lines.append(
                        "                try fields.\(method)(field\(index), forKey: .\(field.name))"
                    )
                }
        }
    }
    lines.append("            case .unknown:")
    lines.append("                break")
    lines.append("        }")
    lines.append("    }")
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// The case's associated values: none, the named struct, or its labeled
/// inline fields.
private func associatedValues(_ errorCase: ResolvedErrorCase) -> String {
    switch errorCase.payload {
        case .none:
            return ""
        case .value(let type, _):
            return "(\(type))"
        case .fields(let fields):
            return "(" + fields.map { "\($0.name): \(swiftType($0.type))" }.joined(separator: ", ")
                + ")"
    }
}

/// The `CodingKey` enum of an inline-fields case.
private func codingKeysName(_ errorCase: ResolvedErrorCase) -> String {
    "\(capitalizedFirst(errorCase.name))CodingKeys"
}

/// A generated command's descriptor, rebuilt inline: wrapped in
/// `MethodWithErrors` when the call declares errors, so the command's
/// failures carry them.
func commandDescriptor(
    for call: ParsedCall,
    wireName: String,
    constrained: Set<String>,
    beforeSending: String
) -> String {
    let shape = descriptorShape(for: call)
    let checks = descriptorCheckArguments(
        for: call,
        constrained: constrained,
        beforeSending: beforeSending
    )
    let base =
        "\(shape.type)<\(shape.generics)>(name: \"\(wireName)\", access: \(call.accessSource)\(checks))"
    guard !call.errors.isEmpty else { return base }
    return "MethodWithErrors(\(base), errors: \(call.errorTypeName).self)"
}

/// The CLI face of each call's error enum: the exit code the contract pins
/// for each case, and 1 for a case this build does not know.
func exitCodeConformances(for contract: ParsedContract, enclosingType: String) -> [String] {
    contract.calls.filter { !$0.errors.isEmpty && !$0.cliOmitted }.map { call in
        var lines: [String] = []
        lines.append("extension \(enclosingType).\(call.errorTypeName): MMCLIDeclaredError {")
        lines.append("    public var exitCode: Int32 {")
        lines.append("        switch self {")
        for errorCase in call.errors {
            lines.append("            case .`\(errorCase.name)`: return \(errorCase.exitCode)")
        }
        lines.append("            case .unknown: return 1")
        lines.append("        }")
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}

// MARK: - The re-emitted contract

/// The DSL functions a contract calls. Re-emitted module-qualified, so a
/// generated type of the same name in the namespace cannot shadow them.
private let dslCallees: Set<String> = [
    "Access", "Alias", "CLI", "Call", "Case", "Enum", "Error", "Errors", "Field", "FieldGroup",
    "Fields", "Request", "RequestStream", "Reserved", "Response", "ResponseStream", "Target",
    "Type",
    "Union",
]

/// The statements' source with every DSL callee written as
/// `MMSchema.Name(...)` — `Type` as ``MMSchema.`Type` ``, since `X.Type` is
/// the metatype.
func qualifyingDSLCallees(in statements: CodeBlockItemListSyntax) -> String {
    final class CalleeCollector: SyntaxVisitor {
        var callees: [(offset: Int, name: String)] = []

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
                dslCallees.contains(reference.baseName.text)
            {
                self.callees.append(
                    (
                        reference.positionAfterSkippingLeadingTrivia.utf8Offset,
                        reference.baseName.text
                    )
                )
            }
            return .visitChildren
        }
    }
    let collector = CalleeCollector(viewMode: .sourceAccurate)
    collector.walk(statements)
    let start = statements.positionAfterSkippingLeadingTrivia.utf8Offset
    var text = Array(statements.trimmedDescription.utf8)
    for (offset, name) in collector.callees.sorted(by: { $0.offset > $1.offset }) {
        let index = offset - start
        let replacement = name == "Type" ? "MMSchema.`Type`" : "MMSchema.\(name)"
        text.replaceSubrange(index..<(index + name.utf8.count), with: Array(replacement.utf8))
    }
    return String(decoding: text, as: UTF8.self)
}

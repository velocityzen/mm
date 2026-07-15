import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct MMSchemaPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [SchemaContractMacro.self, SchemaTypesMacro.self]
}

/// A precise, position-annotated expansion failure. The macro throws on the
/// first problem; the compiler shows `description` at the expansion site.
struct SchemaMacroError: Error, CustomStringConvertible {
    let description: String
}

/// `#schema("journal") { Call("append") { ... } }` — expands the declarative
/// contract into everything that was previously hand-written in parallel:
///
/// - one struct per request / response / stream element (integer `CodingKeys`
///   from 0, `Codable & Hashable & Sendable`, public memberwise inits) — every
///   generated struct is `SchemaDescribable` so field descriptions and
///   named-type references reach discovery (the call's target entity is
///   envelope metadata, never a payload field),
/// - one Swift type per `Enum` / `Type` declaration (`String`-raw enums with a
///   generated `unknown` case; structs), self-described as their qualified
///   `.reference`,
/// - the typed descriptor per call (`Method` / `ServerStreamMethod` /
///   `ClientStreamMethod` / `BidirectionalStreamMethod`), carrying the declared
///   documentation,
/// - the namespace lists (`static var all: [AnyMethod]`, `static var types`,
///   `static var probedTypes`),
/// - and the runtime contract (`static let contract: SchemaDeclaration`),
///   re-emitted verbatim so `contract.verify(against: Self.self)` doubles as a
///   macro-fidelity check.
///
/// The macro consumes the DSL's **static subset**: literal names and keys,
/// no runtime conditionals. It never executes the DSL — it pattern-matches the
/// syntax tree and generates source.
public struct SchemaContractMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (namespace, closure) = try macroArguments(node, name: "#schema")
        let contract = try parseContract(namespace: namespace, closure: closure)
        var declarations: [String] = []
        for type in contract.types {
            declarations.append(try generateNamedType(type, namespace: namespace))
        }
        for call in contract.calls {
            declarations.append(contentsOf: try generateStructs(for: call, namespace: namespace))
        }
        declarations.append(generateDescriptors(for: contract))
        declarations.append(generateAll(for: contract))
        if !contract.types.isEmpty {
            declarations.append(try generateTypesTable(contract.types, namespace: namespace))
            declarations.append(generateProbedTypes(contract.types, namespace: namespace))
        }
        declarations.append(generateContract(namespace: namespace, closure: closure))
        return declarations.map { DeclSyntax("\(raw: $0)") }
    }
}

/// `#schemaTypes("common") { Enum(...) Type(...) }` — the types-only
/// counterpart: generates the Swift types, `static var types`,
/// `static var probedTypes`, and the verbatim
/// `static let contract: TypeNamespaceDeclaration` fidelity value. See the
/// macro declaration in MMSchema for the full story.
public struct SchemaTypesMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (namespace, closure) = try macroArguments(node, name: "#schemaTypes")
        guard isValidLowerIdentifierPath(namespace) else {
            throw SchemaMacroError(
                description:
                    "#schemaTypes namespace \"\(namespace)\" must be a dotted path of [a-z0-9_] segments"
            )
        }
        var types: [ParsedTypeDecl] = []
        for item in closure.statements {
            guard let call = item.item.as(FunctionCallExprSyntax.self),
                let callee = calleeName(call),
                callee == "Enum" || callee == "Type"
            else {
                throw SchemaMacroError(
                    description:
                        "#schemaTypes supports only Enum(...) and Type(...) declarations (static subset)"
                )
            }
            types.append(try parseTypeDecl(call, kind: callee))
        }
        guard !types.isEmpty else {
            throw SchemaMacroError(description: "#schemaTypes declares no types")
        }
        try validate(types: types, calls: [])
        var declarations: [String] = []
        for type in types {
            declarations.append(try generateNamedType(type, namespace: namespace))
        }
        declarations.append(try generateTypesTable(types, namespace: namespace))
        declarations.append(generateProbedTypes(types, namespace: namespace))
        declarations.append(
            """
            public static let contract: TypeNamespaceDeclaration = Types("\(namespace)") {
            \(closure.statements.trimmedDescription)
            }
            """
        )
        return declarations.map { DeclSyntax("\(raw: $0)") }
    }
}

private func macroArguments(
    _ node: some FreestandingMacroExpansionSyntax,
    name: String
) throws -> (namespace: String, closure: ClosureExprSyntax) {
    guard let namespaceExpr = node.arguments.first?.expression,
        let namespace = stringLiteral(namespaceExpr)
    else {
        throw SchemaMacroError(
            description: "\(name) requires a literal namespace string as its first argument")
    }
    guard let closure = node.trailingClosure else {
        throw SchemaMacroError(
            description: "\(name) requires a trailing closure of declarations")
    }
    return (namespace, closure)
}

// MARK: - Parsed intermediate representation

private struct ParsedContract {
    var namespace: String
    var types: [ParsedTypeDecl]
    var calls: [ParsedCall]
}

private struct ParsedTypeDecl {
    enum Payload {
        case structure([ParsedField])
        case enumeration([ParsedCase])
    }

    var name: String
    var description: String?
    var payload: Payload
}

private struct ParsedCase {
    var name: String
    var description: String?
}

private struct ParsedCall {
    var name: String
    var accessSource: String  // rendered verbatim: ".write" or "[.read, .write]"
    var description: String?
    var request: [ParsedField]
    var requestName: String?
    var requestDescription: String?
    /// A `Request(.reference("X"))` / `Request(X.self)` payload: the request
    /// IS a named type; no request struct is generated.
    var requestPayload: ParsedType?
    var requestStream: [ParsedField]?
    var requestStreamName: String?
    var requestStreamDescription: String?
    /// A `RequestStream(.reference("X"))` / `RequestStream(X.self)` payload:
    /// the elements ARE a named type; no item struct is generated.
    var requestStreamPayload: ParsedType?
    var response: [ParsedField]
    var responseName: String?
    var responseDescription: String?
    /// A `Response(.reference("X"))` / `Response(X.self)` payload: the
    /// response IS a named type; no response struct is generated.
    var responsePayload: ParsedType?
    var responseStream: [ParsedField]?
    var responseStreamName: String?
    var responseStreamDescription: String?
    var responseStreamPayload: ParsedType?

    var capitalized: String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    var requestTypeName: String { requestName ?? "\(capitalized)Request" }
    var responseTypeName: String { responseName ?? "\(capitalized)Response" }
    var requestItemTypeName: String { requestStreamName ?? "\(capitalized)RequestItem" }
    var responseItemTypeName: String { responseStreamName ?? "\(capitalized)ResponseItem" }

    var hasRequestStream: Bool { requestStream != nil || requestStreamPayload != nil }
    var hasResponseStream: Bool { responseStream != nil || responseStreamPayload != nil }
    /// The Swift type each descriptor slot resolves to: a referenced named
    /// type, or the generated struct.
    var requestSwiftType: String { requestPayload.map(swiftType) ?? requestTypeName }
    var responseSwiftType: String { responsePayload.map(swiftType) ?? responseTypeName }
    var requestElementSwiftType: String {
        requestStreamPayload.map(swiftType) ?? requestItemTypeName
    }
    var responseElementSwiftType: String {
        responseStreamPayload.map(swiftType) ?? responseItemTypeName
    }
}

private struct ParsedField {
    var pinnedKey: Int?
    var name: String
    var type: ParsedType
    var description: String?
}

private indirect enum ParsedType {
    case bool, int, uint, float, double, string
    case optional(ParsedType)
    case array(ParsedType)
    case map(key: ParsedType, value: ParsedType)
    /// A nested `Field("owner") { ... }` block: generates a nested struct.
    case structure(name: String, fields: [ParsedField])
    /// A reference to an `Enum`/`Type` declared in the same block, by
    /// unqualified name (`Field("genre", "Genre")`).
    case reference(String)
    /// A cross-schema reference through a Swift type
    /// (`Field("meta", CommonTypes.LineMeta.self)`): the path is the property
    /// type; its `.schema` supplies the qualified reference at runtime.
    case external(String)
}

// MARK: - Parsing

private func parseContract(namespace: String, closure: ClosureExprSyntax) throws -> ParsedContract {
    guard isValidLowerIdentifierPath(namespace) else {
        throw SchemaMacroError(
            description:
                "#schema namespace \"\(namespace)\" must be a dotted path of [a-z0-9_] segments")
    }
    var types: [ParsedTypeDecl] = []
    var calls: [ParsedCall] = []
    var seen: Set<String> = []
    for item in closure.statements {
        guard let call = item.item.as(FunctionCallExprSyntax.self),
            let callee = calleeName(call)
        else {
            throw SchemaMacroError(
                description:
                    "#schema supports only Call, Enum, and Type declarations at the top level (the macro form is the DSL's static subset — no conditionals)"
            )
        }
        switch callee {
            case "Call":
                let parsed = try parseCall(call)
                guard seen.insert(parsed.name).inserted else {
                    throw SchemaMacroError(
                        description: "#schema declares Call(\"\(parsed.name)\") twice")
                }
                calls.append(parsed)
            case "Enum", "Type":
                types.append(try parseTypeDecl(call, kind: callee))
            default:
                throw SchemaMacroError(
                    description:
                        "#schema supports only Call, Enum, and Type declarations at the top level (got \(callee))"
                )
        }
    }
    guard !calls.isEmpty else {
        throw SchemaMacroError(description: "#schema declares no calls")
    }
    try validate(types: types, calls: calls)
    return ParsedContract(namespace: namespace, types: types, calls: calls)
}

/// Cross-declaration validation: unique type names, resolvable local
/// references, and no collisions with the generated per-call struct names.
private func validate(types: [ParsedTypeDecl], calls: [ParsedCall]) throws {
    var typeNames: Set<String> = []
    for type in types {
        guard typeNames.insert(type.name).inserted else {
            throw SchemaMacroError(description: "type \"\(type.name)\" is declared twice")
        }
    }
    var generatedNames = typeNames
    for call in calls {
        var callTypes: [String] = []
        if call.requestPayload == nil { callTypes.append(call.requestTypeName) }
        if call.responsePayload == nil { callTypes.append(call.responseTypeName) }
        if call.requestStream != nil { callTypes.append(call.requestItemTypeName) }
        if call.responseStream != nil { callTypes.append(call.responseItemTypeName) }
        for name in callTypes {
            guard generatedNames.insert(name).inserted else {
                throw SchemaMacroError(
                    description:
                        "generated type name \"\(name)\" collides with another declaration — rename the Type/Enum or the part's type-name literal"
                )
            }
        }
    }
    // References must resolve within the block.
    func check(_ fields: [ParsedField], context: String) throws {
        for field in fields {
            try check(field.type, context: "\(context).\(field.name)")
        }
    }
    func check(_ type: ParsedType, context: String) throws {
        switch type {
            case .bool, .int, .uint, .float, .double, .string, .external:
                break
            case .optional(let wrapped):
                try check(wrapped, context: context)
            case .array(let element):
                try check(element, context: context)
            case .map(let key, let value):
                try check(key, context: context)
                try check(value, context: context)
            case .structure(_, let fields):
                try check(fields, context: context)
            case .reference(let name):
                guard typeNames.contains(name) else {
                    throw SchemaMacroError(
                        description:
                            "\(context): reference \"\(name)\" does not resolve to an Enum/Type declared in this block — cross-schema references use the Swift type (Field(\"x\", Other.Name.self))"
                    )
                }
        }
    }
    for type in types {
        if case .structure(let fields) = type.payload {
            try check(fields, context: type.name)
        }
    }
    for call in calls {
        try check(call.request, context: "\(call.name).Request")
        if let payload = call.requestPayload {
            try check(payload, context: "\(call.name).Request")
        }
        try check(call.response, context: "\(call.name).Response")
        if let payload = call.responsePayload {
            try check(payload, context: "\(call.name).Response")
        }
        if let stream = call.requestStream {
            try check(stream, context: "\(call.name).RequestStream")
        }
        if let payload = call.requestStreamPayload {
            try check(payload, context: "\(call.name).RequestStream")
        }
        if let stream = call.responseStream {
            try check(stream, context: "\(call.name).ResponseStream")
        }
        if let payload = call.responseStreamPayload {
            try check(payload, context: "\(call.name).ResponseStream")
        }
    }
}

private func parseTypeDecl(_ call: FunctionCallExprSyntax, kind: String) throws -> ParsedTypeDecl {
    guard let nameExpr = call.arguments.first?.expression,
        let name = stringLiteral(nameExpr)
    else {
        throw SchemaMacroError(description: "\(kind) requires a literal type-name string")
    }
    guard isValidTypeIdentifier(name) else {
        throw SchemaMacroError(
            description:
                "\(kind) name \"\(name)\" is not a valid Swift type identifier ([A-Z_][A-Za-z0-9_]*)"
        )
    }
    let description = try labeledDescription(call.arguments, context: "\(kind)(\"\(name)\")")
    for argument in call.arguments.dropFirst() where argument.label?.text != "description" {
        throw SchemaMacroError(
            description:
                "\(kind)(\"\(name)\"): unsupported argument \(argument.expression.trimmedDescription)"
        )
    }
    guard let body = call.trailingClosure else {
        throw SchemaMacroError(description: "\(kind)(\"\(name)\") requires a trailing closure")
    }
    if kind == "Type" {
        let fields = try parseFields(body, context: "Type(\"\(name)\")")
        guard !fields.isEmpty else {
            throw SchemaMacroError(description: "Type(\"\(name)\") declares no fields")
        }
        return ParsedTypeDecl(
            name: name, description: description, payload: .structure(fields))
    }
    var cases: [ParsedCase] = []
    var seen: Set<String> = []
    for item in body.statements {
        guard let caseCall = item.item.as(FunctionCallExprSyntax.self),
            calleeName(caseCall) == "Case"
        else {
            throw SchemaMacroError(
                description: "Enum(\"\(name)\"): only Case(...) declarations are supported")
        }
        let parsed = try parseCase(caseCall, enumName: name)
        guard seen.insert(parsed.name).inserted else {
            throw SchemaMacroError(
                description: "Enum(\"\(name)\") declares case \"\(parsed.name)\" twice")
        }
        cases.append(parsed)
    }
    guard !cases.isEmpty else {
        throw SchemaMacroError(description: "Enum(\"\(name)\") declares no cases")
    }
    return ParsedTypeDecl(name: name, description: description, payload: .enumeration(cases))
}

private func parseCase(_ call: FunctionCallExprSyntax, enumName: String) throws -> ParsedCase {
    guard let nameExpr = call.arguments.first?.expression,
        let name = stringLiteral(nameExpr)
    else {
        throw SchemaMacroError(
            description: "Enum(\"\(enumName)\"): Case requires a literal name string")
    }
    guard isValidSwiftIdentifierish(name) else {
        throw SchemaMacroError(
            description:
                "Enum(\"\(enumName)\"): case name \"\(name)\" must be a Swift identifier — it is both the wire value and the generated case"
        )
    }
    guard name != "unknown" else {
        throw SchemaMacroError(
            description:
                "Enum(\"\(enumName)\"): \"unknown\" is reserved — the macro generates it as the unrecognized-value fallback (house wire-enum rule)"
        )
    }
    let description = try labeledDescription(
        call.arguments, context: "Enum(\"\(enumName)\").Case(\"\(name)\")")
    return ParsedCase(name: name, description: description)
}

private func parseCall(_ call: FunctionCallExprSyntax) throws -> ParsedCall {
    guard let nameExpr = call.arguments.first?.expression,
        let name = stringLiteral(nameExpr)
    else {
        throw SchemaMacroError(description: "Call requires a literal method-name string")
    }
    guard isValidSwiftIdentifierish(name) else {
        throw SchemaMacroError(
            description:
                "Call name \"\(name)\" must be a single identifier segment ([A-Za-z_][A-Za-z0-9_]*) so it can name the generated descriptor"
        )
    }
    guard let body = call.trailingClosure else {
        throw SchemaMacroError(
            description: "Call(\"\(name)\") requires a trailing closure of parts")
    }
    var result = ParsedCall(
        name: name, accessSource: "", request: [], response: [])
    result.description = try labeledDescription(call.arguments, context: "Call(\"\(name)\")")
    var sawAccess = false
    var sawRequest = false
    var sawResponse = false
    for item in body.statements {
        guard let part = item.item.as(FunctionCallExprSyntax.self),
            let partName = calleeName(part)
        else {
            throw SchemaMacroError(
                description: "Call(\"\(name)\") contains a statement that is not a DSL part")
        }
        switch partName {
            case "Access":
                guard !sawAccess else {
                    throw SchemaMacroError(description: "Call(\"\(name)\"): Access declared twice")
                }
                sawAccess = true
                result.accessSource = try parseAccess(part, callName: name)
            case "Request":
                guard !sawRequest else {
                    throw SchemaMacroError(description: "Call(\"\(name)\"): Request declared twice")
                }
                sawRequest = true
                let parsed = try parseFieldsPart(part, partName: partName, callName: name)
                result.requestName = parsed.typeName
                result.requestDescription = parsed.description
                result.request = parsed.fields
                result.requestPayload = parsed.payload
            case "Response":
                guard !sawResponse else {
                    throw SchemaMacroError(
                        description: "Call(\"\(name)\"): Response declared twice")
                }
                sawResponse = true
                let parsed = try parseFieldsPart(part, partName: partName, callName: name)
                result.responseName = parsed.typeName
                result.responseDescription = parsed.description
                result.response = parsed.fields
                result.responsePayload = parsed.payload
            case "RequestStream":
                guard !result.hasRequestStream else {
                    throw SchemaMacroError(
                        description: "Call(\"\(name)\"): RequestStream declared twice")
                }
                let parsed = try parseFieldsPart(part, partName: partName, callName: name)
                result.requestStreamName = parsed.typeName
                result.requestStreamDescription = parsed.description
                result.requestStreamPayload = parsed.payload
                result.requestStream = parsed.payload == nil ? parsed.fields : nil
            case "ResponseStream":
                guard !result.hasResponseStream else {
                    throw SchemaMacroError(
                        description: "Call(\"\(name)\"): ResponseStream declared twice")
                }
                let parsed = try parseFieldsPart(part, partName: partName, callName: name)
                result.responseStreamName = parsed.typeName
                result.responseStreamDescription = parsed.description
                result.responseStreamPayload = parsed.payload
                result.responseStream = parsed.payload == nil ? parsed.fields : nil
            default:
                throw SchemaMacroError(
                    description: "Call(\"\(name)\"): unknown part \(partName) (macro static subset)"
                )
        }
    }
    guard sawAccess else {
        throw SchemaMacroError(
            description:
                "Call(\"\(name)\") declares no Access — authorization policy is never defaulted")
    }
    return result
}

private func parseAccess(_ part: FunctionCallExprSyntax, callName: String) throws -> String {
    // Access(.write) or Access { .write }; the expression may also be an
    // OptionSet array literal like [.read, .write]. Rendered verbatim.
    let expr: ExprSyntax
    if let argument = part.arguments.first?.expression {
        expr = argument
    } else if let closure = part.trailingClosure,
        closure.statements.count == 1,
        let only = closure.statements.first?.item.as(ExprSyntax.self)
    {
        expr = only
    } else {
        throw SchemaMacroError(
            description: "Call(\"\(callName)\"): Access must be Access(.x) or Access { .x }")
    }
    let source = expr.trimmedDescription
    guard expr.is(MemberAccessExprSyntax.self) || expr.is(ArrayExprSyntax.self) else {
        throw SchemaMacroError(
            description:
                "Call(\"\(callName)\"): Access must be a literal access expression like .write or [.read, .write], got \(source)"
        )
    }
    return source
}

/// Extracts a `description:` labeled argument as a literal string, rejecting
/// non-literal expressions (static subset).
private func labeledDescription(
    _ arguments: LabeledExprListSyntax,
    context: String
) throws -> String? {
    for argument in arguments where argument.label?.text == "description" {
        guard let literal = stringLiteral(argument.expression) else {
            throw SchemaMacroError(
                description:
                    "\(context): description must be a literal string (static subset)")
        }
        return literal
    }
    return nil
}

/// Parses Request/Response/RequestStream/ResponseStream: an optional leading
/// type-name string literal, an ignored StreamOptions argument, an optional
/// `description:`, and a trailing closure of Field declarations (optional for
/// Request/Response) — or, for Response and the streams, a bare payload
/// reference (`.reference("X")` / `X.self`) meaning the part IS a named type.
private func parseFieldsPart(
    _ part: FunctionCallExprSyntax,
    partName: String,
    callName: String
) throws -> (typeName: String?, description: String?, fields: [ParsedField], payload: ParsedType?) {
    var typeName: String?
    var description: String?
    var payload: ParsedType?
    for argument in part.arguments {
        if argument.label?.text == "payload" {
            throw SchemaMacroError(
                description:
                    "Call(\"\(callName)\"): \(partName)(payload:) has no generated-type form — reference a named type (\(partName)(.reference(\"TypeName\"))) or name the element with \(partName)(\"TypeName\") { Field(...) }"
            )
        }
        if argument.label?.text == "description" {
            guard let literal = stringLiteral(argument.expression) else {
                throw SchemaMacroError(
                    description:
                        "Call(\"\(callName)\"): \(partName) description must be a literal string")
            }
            description = literal
        } else if let literal = stringLiteral(argument.expression) {
            guard isValidTypeIdentifier(literal) else {
                throw SchemaMacroError(
                    description:
                        "Call(\"\(callName)\"): \(partName) type name \"\(literal)\" is not a valid Swift type identifier"
                )
            }
            typeName = literal
        } else if let call = argument.expression.as(FunctionCallExprSyntax.self),
            calleeName(call) == "StreamOptions"
        {
            continue  // reserved options slot; nothing to generate from in v1
        } else if isPayloadReference(argument.expression) {
            payload = try parseType(
                argument.expression, context: "\(callName).\(partName)")
        } else {
            throw SchemaMacroError(
                description:
                    "Call(\"\(callName)\"): unsupported \(partName) argument \(argument.expression.trimmedDescription)"
            )
        }
    }
    if let payload {
        guard part.trailingClosure == nil, typeName == nil else {
            throw SchemaMacroError(
                description:
                    "Call(\"\(callName)\"): \(partName) mixes a payload reference with fields or a type name"
            )
        }
        guard case .reference = payload else {
            guard case .external = payload else {
                throw SchemaMacroError(
                    description:
                        "Call(\"\(callName)\"): \(partName) payload must be a named-type reference"
                )
            }
            return (nil, description, [], payload)
        }
        return (nil, description, [], payload)
    }
    guard let closure = part.trailingClosure else {
        return (typeName, description, [], nil)
    }
    return (
        typeName, description, try parseFields(closure, context: "\(callName).\(partName)"), nil
    )
}

/// Whether a part argument is a payload reference: `.reference("X")` or a
/// Swift type reference (`Other.Name.self`).
private func isPayloadReference(_ expr: ExprSyntax) -> Bool {
    if let call = expr.as(FunctionCallExprSyntax.self),
        let member = call.calledExpression.as(MemberAccessExprSyntax.self),
        member.base == nil,
        member.declName.baseName.text == "reference"
    {
        return true
    }
    if let member = expr.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "self",
        member.base != nil
    {
        return true
    }
    return false
}

private func parseFields(_ closure: ClosureExprSyntax, context: String) throws -> [ParsedField] {
    var fields: [ParsedField] = []
    for item in closure.statements {
        guard let call = item.item.as(FunctionCallExprSyntax.self), calleeName(call) == "Field"
        else {
            throw SchemaMacroError(
                description:
                    "\(context): only Field(...) declarations are supported (static subset)"
            )
        }
        fields.append(try parseField(call, context: context))
    }
    return fields
}

private func parseField(_ call: FunctionCallExprSyntax, context: String) throws -> ParsedField {
    var arguments = Array(call.arguments)
    var description: String?
    if let last = arguments.last, last.label?.text == "description" {
        guard let literal = stringLiteral(last.expression) else {
            throw SchemaMacroError(
                description: "\(context): Field description must be a literal string")
        }
        description = literal
        arguments.removeLast()
    }
    var pinnedKey: Int?
    if let first = arguments.first,
        let literal = first.expression.as(IntegerLiteralExprSyntax.self)
    {
        guard let key = Int(literal.literal.text.filter { $0 != "_" }) else {
            throw SchemaMacroError(description: "\(context): unreadable field key")
        }
        pinnedKey = key
        arguments.removeFirst()
    }
    guard let nameArgument = arguments.first, let name = stringLiteral(nameArgument.expression)
    else {
        throw SchemaMacroError(description: "\(context): Field requires a literal name string")
    }
    guard isValidSwiftIdentifierish(name) else {
        throw SchemaMacroError(
            description:
                "\(context): field name \"\(name)\" must be a Swift identifier ([A-Za-z_][A-Za-z0-9_]*) to become a property"
        )
    }
    arguments.removeFirst()
    if let nested = call.trailingClosure {
        guard arguments.isEmpty else {
            throw SchemaMacroError(
                description:
                    "\(context): Field(\"\(name)\") mixes a type argument with a nested block"
            )
        }
        let nestedName = name.prefix(1).uppercased() + name.dropFirst()
        let nestedFields = try parseFields(nested, context: "\(context).\(name)")
        return ParsedField(
            pinnedKey: pinnedKey, name: name,
            type: .structure(name: nestedName, fields: nestedFields),
            description: description)
    }
    guard let typeArgument = arguments.first, arguments.count == 1 else {
        throw SchemaMacroError(
            description: "\(context): Field(\"\(name)\") requires exactly one type expression")
    }
    return ParsedField(
        pinnedKey: pinnedKey, name: name,
        type: try parseType(typeArgument.expression, context: "\(context).\(name)"),
        description: description)
}

private func parseType(_ expr: ExprSyntax, context: String) throws -> ParsedType {
    // Field("genre", "Genre"): a reference to a type declared in this block.
    if let literal = stringLiteral(expr) {
        guard !literal.contains(".") else {
            throw SchemaMacroError(
                description:
                    "\(context): dotted references (\"\(literal)\") are runtime-DSL-only — the macro cannot know the Swift type behind a wire name; reference the type itself (Field(\"x\", Other.Name.self))"
            )
        }
        guard isValidTypeIdentifier(literal) else {
            throw SchemaMacroError(
                description: "\(context): reference \"\(literal)\" is not a valid type identifier")
        }
        return .reference(literal)
    }
    // Field("meta", CommonTypes.LineMeta.self): a cross-schema Swift type.
    if let member = expr.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "self",
        let base = member.base
    {
        return .external(base.trimmedDescription)
    }
    if let member = expr.as(MemberAccessExprSyntax.self), member.base == nil {
        switch member.declName.baseName.text {
            case "bool": return .bool
            case "int": return .int
            case "uint": return .uint
            case "float": return .float
            case "double": return .double
            case "string": return .string
            case "bytes", "unknown":
                throw SchemaMacroError(
                    description:
                        "\(context): .\(member.declName.baseName.text) has no generated Codable counterpart — declare this method with the runtime DSL and hand-written types"
                )
            default:
                throw SchemaMacroError(
                    description: "\(context): unknown wire shape .\(member.declName.baseName.text)")
        }
    }
    if let call = expr.as(FunctionCallExprSyntax.self),
        let member = call.calledExpression.as(MemberAccessExprSyntax.self),
        member.base == nil
    {
        let arguments = Array(call.arguments)
        switch member.declName.baseName.text {
            case "optional":
                guard arguments.count == 1 else { break }
                return .optional(try parseType(arguments[0].expression, context: context))
            case "array":
                guard arguments.count == 1 else { break }
                return .array(try parseType(arguments[0].expression, context: context))
            case "map":
                guard arguments.count == 2 else { break }
                let key = try parseType(arguments[0].expression, context: context)
                switch key {
                    case .string, .int, .uint: break
                    default:
                        throw SchemaMacroError(
                            description: "\(context): map keys must be .string, .int, or .uint")
                }
                return .map(
                    key: key, value: try parseType(arguments[1].expression, context: context))
            case "reference":
                guard arguments.count == 1, let name = stringLiteral(arguments[0].expression) else {
                    break
                }
                return try parseType(
                    ExprSyntax(StringLiteralExprSyntax(content: name)), context: context)
            case "enumeration":
                throw SchemaMacroError(
                    description:
                        "\(context): inline .enumeration has no generated form — declare it as a named Enum in this block"
                )
            default:
                break
        }
    }
    throw SchemaMacroError(
        description:
            "\(context): unsupported type expression \(expr.trimmedDescription) — the macro subset supports primitives, .optional, .array, .map, nested Field(\"name\") { } blocks, \"TypeName\" references, and Swift type references (Other.Name.self)"
    )
}

// MARK: - Code generation

/// Mirrors the runtime DSL's key assignment exactly: unpinned fields take the
/// smallest unused integer >= `first`, pinned fields keep their pin.
private func assignKeys(
    _ fields: [ParsedField], startingAt first: Int, reserving reserved: Set<Int>
) throws -> [(field: ParsedField, key: Int)] {
    var used = reserved
    for field in fields {
        if let pin = field.pinnedKey {
            guard used.insert(pin).inserted else {
                throw SchemaMacroError(description: "duplicate field key \(pin) (\(field.name))")
            }
        }
    }
    var next = first
    return fields.map { field in
        if let pin = field.pinnedKey { return (field, pin) }
        while used.contains(next) { next += 1 }
        used.insert(next)
        return (field, next)
    }
}

private func swiftType(_ type: ParsedType) -> String {
    switch type {
        case .bool: return "Bool"
        case .int: return "Int"
        case .uint: return "UInt64"
        case .float: return "Float"
        case .double: return "Double"
        case .string: return "String"
        case .optional(let wrapped): return "\(swiftType(wrapped))?"
        case .array(let element): return "[\(swiftType(element))]"
        case .map(let key, let value): return "[\(swiftType(key)): \(swiftType(value))]"
        case .structure(let name, _): return name
        case .reference(let name): return name
        case .external(let path): return path
    }
}

/// Renders a `TypeSchema` expression for the described schema of a generated
/// type. Local references qualify with the namespace; external references
/// defer to the Swift type's own described schema.
private func schemaLiteral(_ type: ParsedType, namespace: String) throws -> String {
    switch type {
        case .bool: return ".bool"
        case .int: return ".int"
        case .uint: return ".uint"
        case .float: return ".float"
        case .double: return ".double"
        case .string: return ".string"
        case .optional(let wrapped):
            return ".optional(\(try schemaLiteral(wrapped, namespace: namespace)))"
        case .array(let element):
            return ".array(\(try schemaLiteral(element, namespace: namespace)))"
        case .map(let key, let value):
            return
                ".map(key: \(try schemaLiteral(key, namespace: namespace)), value: \(try schemaLiteral(value, namespace: namespace)))"
        case .structure(_, let fields):
            let keyed = try assignKeys(fields, startingAt: 0, reserving: [])
            return ".structure(fields: [\(try fieldLiterals(keyed, namespace: namespace))])"
        case .reference(let name):
            return ".reference(\(quoted("\(namespace).\(name)")))"
        case .external(let path):
            return "\(path).schema"
    }
}

private func fieldLiterals(
    _ keyed: [(field: ParsedField, key: Int)],
    namespace: String
) throws -> String {
    try keyed.map { field, key in
        var literal =
            "TypeSchema.Field(key: \(key), name: \(quoted(field.name)), type: \(try schemaLiteral(field.type, namespace: namespace))"
        if let description = field.description {
            literal += ", description: \(quoted(description))"
        }
        return literal + ")"
    }.joined(separator: ", ")
}

/// How a generated struct describes itself: named types describe as their
/// qualified reference; request/response/item structs describe their full
/// structure inline (field descriptions included) — that is how documentation
/// reaches discovery.
private enum DescribedAs {
    case reference(qualified: String)
    case structure
}

private func generateStruct(
    name: String,
    fields: [ParsedField],
    namespace: String,
    describedAs: DescribedAs?
) throws -> String {
    let keyed = try assignKeys(fields, startingAt: 0, reserving: [])
    var lines: [String] = []
    // Nested anonymous structs (Field("x") { } blocks) stay probe-described;
    // an EMPTY nested struct still needs SchemaDescribable because a
    // property-less synthesized decoder never requests a container and would
    // probe as .unknown.
    let describable = describedAs != nil || keyed.isEmpty
    var conformances = ["Codable", "Hashable", "Sendable"]
    if describable { conformances.append("SchemaDescribable") }
    lines.append("public struct \(name): \(conformances.joined(separator: ", ")) {")
    switch describedAs {
        case .reference(let qualified):
            lines.append("    public static var schema: TypeSchema {")
            lines.append("        .reference(\(quoted(qualified)))")
            lines.append("    }")
        case .structure:
            lines.append("    public static var schema: TypeSchema {")
            lines.append(
                "        .structure(fields: [\(try fieldLiterals(keyed, namespace: namespace))])")
            lines.append("    }")
        case nil:
            if describable {
                lines.append("    public static var schema: TypeSchema {")
                lines.append("        .structure(fields: [])")
                lines.append("    }")
            }
    }
    for (nestedName, nestedFields) in nestedStructures(in: fields) {
        let nested = try generateStruct(
            name: nestedName, fields: nestedFields,
            namespace: namespace, describedAs: nil)
        lines.append(
            nested.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))
    }
    for (field, _) in keyed {
        if let description = field.description {
            lines.append("    /// \(docCommentText(description))")
        }
        lines.append("    public var \(field.name): \(swiftType(field.type))")
    }
    var parameters: [String] = []
    var assignments: [String] = []
    for (field, _) in keyed {
        parameters.append("\(field.name): \(swiftType(field.type))")
        assignments.append("        self.\(field.name) = \(field.name)")
    }
    lines.append("    public init(\(parameters.joined(separator: ", "))) {")
    lines.append(contentsOf: assignments)
    lines.append("    }")
    if !keyed.isEmpty {
        lines.append("    enum CodingKeys: Int, CodingKey {")
        for (field, key) in keyed {
            lines.append("        case \(field.name) = \(key)")
        }
        lines.append("    }")
    }
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// Nested structs declared via `Field("owner") { ... }` blocks, at any depth.
private func nestedStructures(in fields: [ParsedField]) -> [(name: String, fields: [ParsedField])] {
    var result: [(String, [ParsedField])] = []
    for field in fields {
        if case .structure(let name, let nested) = field.type {
            result.append((name, nested))
            result.append(contentsOf: nestedStructures(in: nested))
        }
    }
    return result
}

private func generateNamedType(_ type: ParsedTypeDecl, namespace: String) throws -> String {
    let qualified = "\(namespace).\(type.name)"
    switch type.payload {
        case .structure(let fields):
            return try generateStruct(
                name: type.name, fields: fields,
                namespace: namespace, describedAs: .reference(qualified: qualified))
        case .enumeration(let cases):
            var lines: [String] = []
            lines.append(
                "public enum \(type.name): String, Codable, Sendable, CaseIterable, SchemaDescribable {"
            )
            for enumCase in cases {
                if let description = enumCase.description {
                    lines.append("    /// \(docCommentText(description))")
                }
                lines.append("    case `\(enumCase.name)`")
            }
            lines.append("    /// Unrecognized wire values decode here (house wire-enum rule).")
            lines.append("    case unknown")
            lines.append("    public init(from decoder: any Decoder) throws {")
            lines.append("        let raw = try decoder.singleValueContainer().decode(String.self)")
            lines.append("        self = \(type.name)(rawValue: raw) ?? .unknown")
            lines.append("    }")
            lines.append("    public static var schema: TypeSchema {")
            lines.append("        .reference(\(quoted(qualified)))")
            lines.append("    }")
            lines.append("}")
            return lines.joined(separator: "\n")
    }
}

/// The definition a named type serves through `types` — full shape with
/// descriptions (unlike the generated Swift type's `.reference` description).
private func definitionLiteral(_ type: ParsedTypeDecl, namespace: String) throws -> String {
    let schema: String
    switch type.payload {
        case .structure(let fields):
            // The entity field (when present) is declared like any other field,
            // so the definition needs no special casing.
            let keyed = try assignKeys(fields, startingAt: 0, reserving: [])
            schema = ".structure(fields: [\(try fieldLiterals(keyed, namespace: namespace))])"
        case .enumeration(let cases):
            let caseLiterals = cases.map { enumCase in
                var literal = "TypeSchema.EnumCase(name: \(quoted(enumCase.name))"
                if let description = enumCase.description {
                    literal += ", description: \(quoted(description))"
                }
                return literal + ")"
            }.joined(separator: ", ")
            schema = ".enumeration(cases: [\(caseLiterals)])"
    }
    var literal = "TypeDefinition(name: \(quoted("\(namespace).\(type.name)")), schema: \(schema)"
    if let description = type.description {
        literal += ", description: \(quoted(description))"
    }
    return literal + ")"
}

private func generateTypesTable(_ types: [ParsedTypeDecl], namespace: String) throws -> String {
    let entries = try types.map { try definitionLiteral($0, namespace: namespace) }
        .joined(separator: ",\n        ")
    return """
        public static var types: [TypeDefinition] {
            [
                \(entries)
            ]
        }
        """
}

private func generateProbedTypes(_ types: [ParsedTypeDecl], namespace: String) -> String {
    let entries = types.map { type in
        "\(quoted("\(namespace).\(type.name)")): TypeSchema.probed(\(type.name).self)"
    }.joined(separator: ", ")
    return """
        public static var probedTypes: [String: Result<TypeSchema, SchemaError>] {
            [\(entries)]
        }
        """
}

private func generateStructs(for call: ParsedCall, namespace: String) throws -> [String] {
    var declarations: [String] = []
    // A part with a payload reference IS a named type — no struct to generate.
    if call.requestPayload == nil {
        declarations.append(
            try generateStruct(
                name: call.requestTypeName, fields: call.request,
                namespace: namespace, describedAs: .structure))
    }
    if call.responsePayload == nil {
        declarations.append(
            try generateStruct(
                name: call.responseTypeName, fields: call.response,
                namespace: namespace, describedAs: .structure))
    }
    if let stream = call.requestStream {
        declarations.append(
            try generateStruct(
                name: call.requestItemTypeName, fields: stream,
                namespace: namespace, describedAs: .structure))
    }
    if let stream = call.responseStream {
        declarations.append(
            try generateStruct(
                name: call.responseItemTypeName, fields: stream,
                namespace: namespace, describedAs: .structure))
    }
    return declarations
}

/// The `documentation:` argument for a descriptor, or nil when the call
/// declares no descriptions at all.
private func documentationArgument(for call: ParsedCall) -> String? {
    var arguments: [String] = []
    if let text = call.description { arguments.append("description: \(quoted(text))") }
    if let text = call.requestDescription { arguments.append("request: \(quoted(text))") }
    if let text = call.responseDescription { arguments.append("response: \(quoted(text))") }
    if let text = call.requestStreamDescription {
        arguments.append("requestStream: \(quoted(text))")
    }
    if let text = call.responseStreamDescription {
        arguments.append("responseStream: \(quoted(text))")
    }
    guard !arguments.isEmpty else { return nil }
    return "MethodDocumentation(\(arguments.joined(separator: ", ")))"
}

private func descriptor(for call: ParsedCall, namespace: String) -> String {
    let wireName = "\(namespace).\(call.name)"
    let documentation = documentationArgument(for: call).map { ",\n    documentation: \($0)" } ?? ""
    let generics: String
    let descriptorType: String
    switch (call.hasRequestStream, call.hasResponseStream) {
        case (false, false):
            descriptorType = "Method"
            generics = "\(call.requestSwiftType), \(call.responseSwiftType)"
        case (false, true):
            descriptorType = "ServerStreamMethod"
            generics =
                "\(call.requestSwiftType), \(call.responseElementSwiftType), \(call.responseSwiftType)"
        case (true, false):
            descriptorType = "ClientStreamMethod"
            generics =
                "\(call.requestSwiftType), \(call.requestElementSwiftType), \(call.responseSwiftType)"
        case (true, true):
            descriptorType = "BidirectionalStreamMethod"
            generics =
                "\(call.requestSwiftType), \(call.requestElementSwiftType), \(call.responseElementSwiftType), \(call.responseSwiftType)"
    }
    return """
        public static let `\(call.name)` = \(descriptorType)<\(generics)>(
            name: "\(wireName)", access: \(call.accessSource)\(documentation))
        """
}

private func generateDescriptors(for contract: ParsedContract) -> String {
    contract.calls.map { descriptor(for: $0, namespace: contract.namespace) }
        .joined(separator: "\n")
}

private func generateAll(for contract: ParsedContract) -> String {
    let entries = contract.calls
        .map { "AnyMethod(Self.`\($0.name)`)" }
        .joined(separator: ", ")
    return """
        public static var all: [AnyMethod] {
            [\(entries)]
        }
        """
}

private func generateContract(namespace: String, closure: ClosureExprSyntax) -> String {
    // Re-emit the DSL verbatim as the runtime declaration: the generated types
    // above and this value share one source, so `contract.verify(against:)`
    // becomes a macro-fidelity check rather than a drift check.
    let body = closure.statements.trimmedDescription
    return """
        public static let contract: SchemaDeclaration = Schema("\(namespace)") {
        \(body)
        }
        """
}

// MARK: - Small syntax helpers

private func calleeName(_ call: FunctionCallExprSyntax) -> String? {
    call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
}

private func stringLiteral(_ expr: ExprSyntax) -> String? {
    guard let literal = expr.as(StringLiteralExprSyntax.self),
        literal.segments.count == 1,
        let segment = literal.segments.first?.as(StringSegmentSyntax.self)
    else { return nil }
    return segment.content.text
}

/// Flattens free text onto one line so it is safe inside a generated `///`
/// doc comment.
private func docCommentText(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
}

/// Renders free text as a Swift string literal — descriptions may contain
/// quotes, backslashes, or newlines.
private func quoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

private func isValidSwiftIdentifierish(_ name: String) -> Bool {
    guard let first = name.first, first.isLetter || first == "_" else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

private func isValidTypeIdentifier(_ name: String) -> Bool {
    guard let first = name.first, first.isUppercase || first == "_" else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

private func isValidLowerIdentifierPath(_ path: String) -> Bool {
    let segments = path.split(separator: ".", omittingEmptySubsequences: false)
    guard !segments.isEmpty else { return false }
    return segments.allSatisfy { segment in
        guard let first = segment.first, first.isLowercase || first == "_" else { return false }
        return segment.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "_" }
    }
}

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
        var contract = try parseContract(namespace: namespace, closure: closure)
        contract.cliMode = try parsedCLIMode(node)
        try validateCLI(calls: contract.calls)
        var declarations: [String] = []
        for type in contract.types {
            declarations.append(
                try generateNamedType(
                    type, namespace: namespace, cliEnabled: contract.cliMode.enabled))
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
        if contract.cliMode.enabled {
            // The generated verify command references `<Type>.contract`; the
            // enclosing type's name comes from the expansion's lexical
            // context (nested types cannot reach enclosing statics
            // unqualified, and the macro otherwise has no way to know it).
            guard let enclosingType = enclosingTypeName(context.lexicalContext) else {
                throw SchemaMacroError(
                    description:
                        "#schema(cli:) requires expansion inside a named type declaration")
            }
            declarations.append(
                contentsOf: generateCommands(for: contract, enclosingType: enclosingType))
        }
        return declarations.map { DeclSyntax("\(raw: $0)") }
    }
}

/// The innermost named type enclosing the expansion, from the macro's lexical
/// context (innermost first).
private func enclosingTypeName(_ lexicalContext: [Syntax]) -> String? {
    for scope in lexicalContext {
        if let declaration = scope.as(EnumDeclSyntax.self) { return declaration.name.text }
        if let declaration = scope.as(StructDeclSyntax.self) { return declaration.name.text }
        if let declaration = scope.as(ActorDeclSyntax.self) { return declaration.name.text }
        if let declaration = scope.as(ClassDeclSyntax.self) { return declaration.name.text }
        if let declaration = scope.as(ExtensionDeclSyntax.self) {
            return declaration.extendedType.trimmedDescription
        }
    }
    return nil
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

/// Parses the optional `cli:` macro argument (static subset: `.disabled`,
/// `.enabled`, or `.enabled(command: "name")`).
private func parsedCLIMode(
    _ node: some FreestandingMacroExpansionSyntax
) throws -> ParsedCLIMode {
    for argument in node.arguments where argument.label?.text == "cli" {
        let expression = argument.expression
        if let member = expression.as(MemberAccessExprSyntax.self), member.base == nil {
            switch member.declName.baseName.text {
                case "disabled": return .disabled
                case "enabled": return ParsedCLIMode(enabled: true, commandName: nil)
                default: break
            }
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
            let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            member.base == nil,
            member.declName.baseName.text == "enabled",
            call.arguments.count == 1,
            let commandArgument = call.arguments.first,
            commandArgument.label?.text == "command",
            let name = stringLiteral(commandArgument.expression)
        {
            guard isValidCommandName(name) else {
                throw SchemaMacroError(
                    description:
                        "#schema cli command name \"\(name)\" must be lowercase kebab-case ([a-z0-9][a-z0-9-]*)"
                )
            }
            return ParsedCLIMode(enabled: true, commandName: name)
        }
        throw SchemaMacroError(
            description:
                "#schema cli: must be .disabled, .enabled, or .enabled(command: \"name\") (static subset)"
        )
    }
    return .disabled
}

/// `[a-z0-9][a-z0-9-]*` — the shape of a generated command or option name.
private func isValidCommandName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first else { return false }
    guard (first >= "a" && first <= "z") || (first >= "0" && first <= "9") else { return false }
    return name.unicodeScalars.allSatisfy {
        ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-"
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
    var cliMode: ParsedCLIMode = .disabled
}

/// The parsed `cli:` macro argument: `.disabled`, `.enabled`, or
/// `.enabled(command: "name")`.
private struct ParsedCLIMode {
    var enabled: Bool
    var commandName: String?

    static let disabled = ParsedCLIMode(enabled: false, commandName: nil)
}

/// The parsed `CLI(...)` part of one call.
private struct ParsedCLIOverlay {
    var omitted: Bool
    var commandName: String?
    var aliases: [String]
}

/// The parsed `cli:` hint on one field.
private enum ParsedCLIArgument {
    case option(name: String?, short: String?)
    case argument
    case flag
    case omitted
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

    var cliOverlay: ParsedCLIOverlay?

    var capitalized: String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The generated subcommand's name: the `CLI(.command(...))` override, or
    /// the kebab-cased call name.
    var cliCommandName: String { cliOverlay?.commandName ?? kebabCased(name) }
    var cliOmitted: Bool { cliOverlay?.omitted ?? false }
    var commandTypeName: String { "\(capitalized)Command" }

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
    var cliHint: ParsedCLIArgument?
}

/// `importAll` → `import-all`; already-lower names pass through unchanged.
private func kebabCased(_ name: String) -> String {
    var result = ""
    for character in name {
        if character.isUppercase {
            if !result.isEmpty { result.append("-") }
            result.append(character.lowercased())
        } else {
            result.append(character)
        }
    }
    return result
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

/// CLI-overlay validation, run whether or not generation is enabled — a bad
/// hint is an authoring mistake either way. Checks command-name uniqueness
/// (including aliases), reserved names, option/short collisions per command,
/// `.flag` on non-bool fields, and `.omitted` on required fields.
private func validateCLI(calls: [ParsedCall]) throws {
    // Option names claimed by every generated command: the shared connection
    // OptionGroup plus swift-argument-parser's own flags.
    let reservedOptions: Set<String> = [
        "socket", "tcp", "connect-timeout", "hello-timeout", "expect-fingerprint",
        "output", "help", "version",
    ]
    var commandNames: Set<String> = []
    for call in calls where !call.cliOmitted {
        for candidate in [call.cliCommandName] + (call.cliOverlay?.aliases ?? []) {
            guard candidate != "help", candidate != "verify" else {
                throw SchemaMacroError(
                    description:
                        "Call(\"\(call.name)\"): CLI name \"\(candidate)\" is reserved")
            }
            guard commandNames.insert(candidate).inserted else {
                throw SchemaMacroError(
                    description:
                        "CLI command name \"\(candidate)\" is used by more than one call — rename with CLI(.command(...))"
                )
            }
        }
        var optionNames = reservedOptions
        var shortNames: Set<String> = []
        for field in call.request {
            switch field.cliHint {
                case .omitted:
                    guard case .optional = field.type else {
                        throw SchemaMacroError(
                            description:
                                "Call(\"\(call.name)\"): field \"\(field.name)\" is cli: .omitted but not optional — the request must stay constructible"
                        )
                    }
                    continue
                case .flag:
                    guard isBoolShape(field.type) else {
                        throw SchemaMacroError(
                            description:
                                "Call(\"\(call.name)\"): field \"\(field.name)\" is cli: .flag but not .bool"
                        )
                    }
                case .argument:
                    continue
                default:
                    break
            }
            let optionName = cliOptionName(field)
            guard optionNames.insert(optionName).inserted else {
                throw SchemaMacroError(
                    description:
                        "Call(\"\(call.name)\"): option --\(optionName) collides with another option — rename with cli: .option(\"name\")"
                )
            }
            if case .option(_, let short?) = field.cliHint {
                guard shortNames.insert(short).inserted else {
                    throw SchemaMacroError(
                        description:
                            "Call(\"\(call.name)\"): short flag -\(short) is used twice")
                }
            }
        }
    }
}

private func isBoolShape(_ type: ParsedType) -> Bool {
    switch type {
        case .bool: return true
        case .optional(let wrapped): return isBoolShape(wrapped)
        default: return false
    }
}

/// The option (or positional value) name one field surfaces as.
private func cliOptionName(_ field: ParsedField) -> String {
    if case .option(let name?, _) = field.cliHint { return name }
    return kebabCased(field.name)
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
            case "CLI":
                guard result.cliOverlay == nil else {
                    throw SchemaMacroError(description: "Call(\"\(name)\"): CLI declared twice")
                }
                result.cliOverlay = try parseCLIPart(part, callName: name)
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

/// Parses `CLI(.omitted)` / `CLI(.command("add"))` /
/// `CLI(.command("add", aliases: ["append"]))`.
private func parseCLIPart(
    _ part: FunctionCallExprSyntax, callName: String
) throws -> ParsedCLIOverlay {
    guard part.arguments.count == 1, let expression = part.arguments.first?.expression,
        part.trailingClosure == nil
    else {
        throw SchemaMacroError(
            description:
                "Call(\"\(callName)\"): CLI takes exactly one spec — .omitted or .command(\"name\", aliases: [...])"
        )
    }
    if let member = expression.as(MemberAccessExprSyntax.self), member.base == nil,
        member.declName.baseName.text == "omitted"
    {
        return ParsedCLIOverlay(omitted: true, commandName: nil, aliases: [])
    }
    if let call = expression.as(FunctionCallExprSyntax.self),
        let member = call.calledExpression.as(MemberAccessExprSyntax.self),
        member.base == nil,
        member.declName.baseName.text == "command"
    {
        var commandName: String?
        var aliases: [String] = []
        for argument in call.arguments {
            if argument.label == nil {
                guard let literal = stringLiteral(argument.expression),
                    isValidCommandName(literal)
                else {
                    throw SchemaMacroError(
                        description:
                            "Call(\"\(callName)\"): CLI command name must be a lowercase kebab-case literal ([a-z0-9][a-z0-9-]*)"
                    )
                }
                commandName = literal
            } else if argument.label?.text == "aliases" {
                guard let array = argument.expression.as(ArrayExprSyntax.self) else {
                    throw SchemaMacroError(
                        description:
                            "Call(\"\(callName)\"): CLI aliases must be a literal string array (static subset)"
                    )
                }
                for element in array.elements {
                    guard let literal = stringLiteral(element.expression),
                        isValidCommandName(literal)
                    else {
                        throw SchemaMacroError(
                            description:
                                "Call(\"\(callName)\"): CLI alias must be a lowercase kebab-case literal"
                        )
                    }
                    aliases.append(literal)
                }
            } else {
                throw SchemaMacroError(
                    description:
                        "Call(\"\(callName)\"): unsupported CLI .command argument \(argument.trimmedDescription)"
                )
            }
        }
        guard let commandName else {
            throw SchemaMacroError(
                description: "Call(\"\(callName)\"): CLI .command requires a name literal")
        }
        return ParsedCLIOverlay(omitted: false, commandName: commandName, aliases: aliases)
    }
    throw SchemaMacroError(
        description:
            "Call(\"\(callName)\"): CLI spec must be .omitted or .command(\"name\", aliases: [...]) (static subset)"
    )
}

/// Parses a field's `cli:` hint (static subset: `.argument`, `.flag`,
/// `.omitted`, `.option("name", short: "c")`).
private func parseCLIArgument(
    _ expression: ExprSyntax, context: String
) throws -> ParsedCLIArgument {
    if let member = expression.as(MemberAccessExprSyntax.self), member.base == nil {
        switch member.declName.baseName.text {
            case "argument": return .argument
            case "flag": return .flag
            case "omitted": return .omitted
            default: break
        }
    }
    if let call = expression.as(FunctionCallExprSyntax.self),
        let member = call.calledExpression.as(MemberAccessExprSyntax.self),
        member.base == nil,
        member.declName.baseName.text == "option"
    {
        var name: String?
        var short: String?
        for argument in call.arguments {
            if argument.label == nil {
                guard let literal = stringLiteral(argument.expression),
                    isValidCommandName(literal)
                else {
                    throw SchemaMacroError(
                        description:
                            "\(context): cli option name must be a lowercase kebab-case literal"
                    )
                }
                name = literal
            } else if argument.label?.text == "short" {
                guard let literal = stringLiteral(argument.expression), literal.count == 1 else {
                    throw SchemaMacroError(
                        description: "\(context): cli short flag must be a single character")
                }
                short = literal
            } else {
                throw SchemaMacroError(
                    description:
                        "\(context): unsupported cli .option argument \(argument.trimmedDescription)"
                )
            }
        }
        return .option(name: name, short: short)
    }
    throw SchemaMacroError(
        description:
            "\(context): cli must be .argument, .flag, .omitted, or .option(\"name\", short: \"c\") (static subset)"
    )
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
    var cliHint: ParsedCLIArgument?
    // Peel the trailing labeled presentation arguments (`description:` and
    // `cli:`), in either order.
    while let last = arguments.last, let label = last.label?.text,
        label == "description" || label == "cli"
    {
        if label == "description" {
            guard description == nil else {
                throw SchemaMacroError(
                    description: "\(context): Field declares description twice")
            }
            guard let literal = stringLiteral(last.expression) else {
                throw SchemaMacroError(
                    description: "\(context): Field description must be a literal string")
            }
            description = literal
        } else {
            guard cliHint == nil else {
                throw SchemaMacroError(description: "\(context): Field declares cli twice")
            }
            cliHint = try parseCLIArgument(last.expression, context: context)
        }
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
            description: description, cliHint: cliHint)
    }
    guard let typeArgument = arguments.first, arguments.count == 1 else {
        throw SchemaMacroError(
            description: "\(context): Field(\"\(name)\") requires exactly one type expression")
    }
    return ParsedField(
        pinnedKey: pinnedKey, name: name,
        type: try parseType(typeArgument.expression, context: "\(context).\(name)"),
        description: description, cliHint: cliHint)
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

private func generateNamedType(
    _ type: ParsedTypeDecl, namespace: String, cliEnabled: Bool = false
) throws -> String {
    let qualified = "\(namespace).\(type.name)"
    switch type.payload {
        case .structure(let fields):
            return try generateStruct(
                name: type.name, fields: fields,
                namespace: namespace, describedAs: .reference(qualified: qualified))
        case .enumeration(let cases):
            var lines: [String] = []
            // With CLI generation on, wire enums double as typed command
            // arguments (MMCLIEnumArgument hides the `unknown` fallback from
            // help and refuses it as input).
            let cliConformance = cliEnabled ? ", MMCLIEnumArgument" : ""
            lines.append(
                "public enum \(type.name): String, Codable, Sendable, CaseIterable, SchemaDescribable\(cliConformance) {"
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

// MARK: - CLI command generation

/// Emits one swift-argument-parser command per non-omitted unary call, plus
/// the namespace command group. Stream-shaped calls are skipped in this phase
/// (their drivers land with the streaming CLI work).
///
/// Generated commands reconstruct their descriptor inline
/// (`Method<Req, Res>(name:access:)`) rather than referencing the enclosing
/// enum's static: the macro cannot know the enum's Swift name, and nested
/// types cannot reach enclosing statics unqualified. Both spellings share the
/// one DSL source, so they cannot drift.
private func generateCommands(for contract: ParsedContract, enclosingType: String) -> [String] {
    let enumNames = Set(
        contract.types.compactMap { type -> String? in
            if case .enumeration = type.payload { return type.name }
            return nil
        })
    let structsByName = Dictionary(
        uniqueKeysWithValues: contract.types.compactMap { type -> (String, [ParsedField])? in
            if case .structure(let fields) = type.payload { return (type.name, fields) }
            return nil
        })
    var declarations: [String] = []
    var subcommands: [String] = []
    for call in contract.calls where !call.cliOmitted {
        declarations.append(
            commandDeclaration(
                for: call, namespace: contract.namespace, enclosingType: enclosingType,
                enumNames: enumNames, structsByName: structsByName))
        subcommands.append("\(call.commandTypeName).self")
    }
    // Every group also gets `verify`: the namespace-scoped drift check
    // against the compiled contract (the build-time-derived answer to "is
    // this server still what I was built for?").
    declarations.append(
        """
        public struct VerifyCommand: AsyncParsableCommand {
            public static let configuration = CommandConfiguration(
                commandName: "verify",
                abstract: "Verifies the compiled contract against the schema the server serves.")
            @OptionGroup public var connection: MMCLIOptions
            public init() {}
            public func run() async throws {
                try await MMCLIVerify.run(contract: \(enclosingType).contract, options: connection)
            }
        }
        """
    )
    subcommands.append("VerifyCommand.self")
    let groupName =
        contract.cliMode.commandName
        ?? contract.namespace.split(separator: ".").joined(separator: "-")
    declarations.append(
        """
        public struct Command: ParsableCommand {
            public static let configuration = CommandConfiguration(
                commandName: "\(groupName)",
                abstract: "Commands for the \(contract.namespace) namespace.",
                subcommands: [\(subcommands.joined(separator: ", "))])
            public init() {}
        }
        """
    )
    return declarations
}

/// How one request field lands on a generated command.
private enum CommandFieldForm {
    /// A typed `@Option`/`@Argument`/`@Flag` whose property type is the
    /// request property type itself.
    case direct(swiftType: String)
    /// A JSON-literal `@Option` (`String`), decoded into the request property
    /// type inside `run()`.
    case json(swiftType: String)
    /// `cli: .omitted` — no property; the request slot gets `nil`.
    case omitted
}

/// Classifies a field: primitives, wire enums, and arrays of either surface
/// as typed options; structures, maps, non-enum references, and externals
/// take a JSON literal.
private func commandFieldForm(
    _ field: ParsedField, enumNames: Set<String>
) -> CommandFieldForm {
    if case .omitted = field.cliHint { return .omitted }
    func isDirect(_ type: ParsedType) -> Bool {
        switch type {
            case .bool, .int, .uint, .float, .double, .string:
                return true
            case .reference(let name):
                return enumNames.contains(name)
            case .optional(let wrapped), .array(let wrapped):
                return isDirect(wrapped)
            case .map, .structure, .external:
                return false
        }
    }
    let swift = swiftType(field.type)
    return isDirect(field.type) ? .direct(swiftType: swift) : .json(swiftType: swift)
}

/// The stdin line→element mapper for a client-stream or bidirectional
/// command: a single-string-field element takes plain lines; anything else
/// takes JSON lines.
private func lineMapper(
    elementFields: [ParsedField]?,
    elementSwiftType: String
) -> String {
    if let fields = elementFields, fields.count == 1, let only = fields.first,
        case .string = only.type
    {
        return "{ line in \(elementSwiftType)(\(only.name): line) }"
    }
    return
        "{ line in try MMCLIJSON.decodeRequired(\(elementSwiftType).self, from: line, option: \"stdin\") }"
}

private func commandDeclaration(
    for call: ParsedCall,
    namespace: String,
    enclosingType: String,
    enumNames: Set<String>,
    structsByName: [String: [ParsedField]]
) -> String {
    let wireName = "\(namespace).\(call.name)"
    // Request fields: a generated struct's declared fields, a local
    // named-type reference's fields (the type is a sibling with a memberwise
    // init), or — for external references — a single JSON option.
    var fields = call.request
    var requestIsExternalReference = false
    if let payload = call.requestPayload {
        switch payload {
            case .reference(let name):
                fields = structsByName[name] ?? []
                requestIsExternalReference = structsByName[name] == nil
            default:
                requestIsExternalReference = true
        }
    }
    var lines: [String] = []
    lines.append("public struct \(call.commandTypeName): AsyncParsableCommand {")
    var configuration: [String] = ["commandName: \(quoted(call.cliCommandName))"]
    if let abstract = call.description {
        configuration.append("abstract: \(quoted(abstract))")
    }
    if let aliases = call.cliOverlay?.aliases, !aliases.isEmpty {
        configuration.append("aliases: [\(aliases.map(quoted).joined(separator: ", "))]")
    }
    lines.append("    public static let configuration = CommandConfiguration(")
    lines.append("        \(configuration.joined(separator: ",\n        ")))")
    lines.append("    @OptionGroup public var connection: MMCLIOptions")
    lines.append(
        "    @Argument(help: \"Target entity (dotted path)\") public var entity: String")

    var preludes: [String] = []
    var requestArguments: [String] = []

    if requestIsExternalReference {
        let requestType = call.requestSwiftType
        lines.append(
            "    @Option(name: .customLong(\"request\"), help: \"The request payload as JSON\") public var requestJSON: String"
        )
        preludes.append(
            "let requestValue = try MMCLIJSON.decodeRequired(\(requestType).self, from: requestJSON, option: \"request\")"
        )
    } else {
        // Positional fields keep declaration order after the entity; options
        // follow. Emit positionals first so swift-argument-parser assigns
        // them in the declared order.
        let ordered = fields.enumerated().sorted { left, right in
            let leftPositional = isPositional(fields[left.offset])
            let rightPositional = isPositional(fields[right.offset])
            if leftPositional != rightPositional { return leftPositional && !rightPositional }
            return left.offset < right.offset
        }.map { $0.element }
        for field in ordered {
            emitField(
                field, call: call, enumNames: enumNames,
                lines: &lines, preludes: &preludes)
        }
        // Request construction uses declaration order, not emission order.
        for field in fields {
            switch commandFieldForm(field, enumNames: enumNames) {
                case .omitted:
                    requestArguments.append("\(field.name): nil")
                case .direct:
                    requestArguments.append("\(field.name): \(field.name)")
                case .json:
                    requestArguments.append("\(field.name): \(field.name)Value")
            }
        }
    }

    lines.append("    public init() {}")
    lines.append("    public func run() async throws {")
    // Locals only inside the call closure: it is @Sendable, and referencing a
    // property would capture non-Sendable self.
    lines.append("        let entityArgument = entity")
    lines.append("        let target = try MMCLIFailure.entity(entityArgument)")
    for prelude in preludes {
        lines.append("        \(prelude)")
    }
    if requestIsExternalReference {
        lines.append("        let request = requestValue")
    } else {
        let requestType = call.requestSwiftType
        lines.append("        let request = \(requestType)(\(requestArguments.joined(separator: ", ")))")
    }
    lines.append("        let format = connection.output")
    // `verifying:` hands the runner this namespace's compiled contract for
    // the automatic pre-dispatch schema check.
    lines.append(
        "        let response = try await MMCLIRunner.invoke(connection, verifying: \(enclosingType).contract) { client in"
    )
    switch (call.hasRequestStream, call.hasResponseStream) {
        case (false, false):
            lines.append("            try MMCLIFailure.unwrap(")
            lines.append("                await client.call(")
            lines.append(
                "                    Method<\(call.requestSwiftType), \(call.responseSwiftType)>(name: \"\(wireName)\", access: \(call.accessSource)),"
            )
            lines.append("                    on: target, request),")
            lines.append("                method: \"\(wireName)\", entity: entityArgument)")
        case (false, true):
            lines.append("            let handle = await client.call(")
            lines.append(
                "                ServerStreamMethod<\(call.requestSwiftType), \(call.responseElementSwiftType), \(call.responseSwiftType)>(name: \"\(wireName)\", access: \(call.accessSource)),"
            )
            lines.append("                on: target, request)")
            lines.append(
                "            return try await MMCLIStreamDriver.follow(handle, format: format, method: \"\(wireName)\", entity: entityArgument)"
            )
        case (true, false):
            let mapper = lineMapper(
                elementFields: streamElementFields(
                    call.requestStream, payload: call.requestStreamPayload,
                    structsByName: structsByName),
                elementSwiftType: call.requestElementSwiftType)
            lines.append("            let handle = await client.call(")
            lines.append(
                "                ClientStreamMethod<\(call.requestSwiftType), \(call.requestElementSwiftType), \(call.responseSwiftType)>(name: \"\(wireName)\", access: \(call.accessSource)),"
            )
            lines.append("                on: target, request)")
            lines.append(
                "            return try await MMCLIStreamDriver.feed(handle, makeElement: \(mapper), method: \"\(wireName)\", entity: entityArgument)"
            )
        case (true, true):
            let mapper = lineMapper(
                elementFields: streamElementFields(
                    call.requestStream, payload: call.requestStreamPayload,
                    structsByName: structsByName),
                elementSwiftType: call.requestElementSwiftType)
            lines.append("            let handle = await client.call(")
            lines.append(
                "                BidirectionalStreamMethod<\(call.requestSwiftType), \(call.requestElementSwiftType), \(call.responseElementSwiftType), \(call.responseSwiftType)>(name: \"\(wireName)\", access: \(call.accessSource)),"
            )
            lines.append("                on: target, request)")
            lines.append(
                "            return try await MMCLIStreamDriver.duplex(handle, makeElement: \(mapper), format: format, method: \"\(wireName)\", entity: entityArgument)"
            )
    }
    lines.append("        }")
    lines.append("        MMCLIOutput.emit(response, format: format)")
    lines.append("    }")
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// The declared fields of a stream element, when knowable: inline fields, or
/// a local named-type reference's fields. External references return nil
/// (their elements always take JSON lines).
private func streamElementFields(
    _ inline: [ParsedField]?,
    payload: ParsedType?,
    structsByName: [String: [ParsedField]]
) -> [ParsedField]? {
    if let inline { return inline }
    if case .reference(let name) = payload { return structsByName[name] }
    return nil
}

private func isPositional(_ field: ParsedField) -> Bool {
    if case .argument = field.cliHint { return true }
    return false
}

/// Emits the property (and any run() prelude) for one request field.
private func emitField(
    _ field: ParsedField,
    call: ParsedCall,
    enumNames: Set<String>,
    lines: inout [String],
    preludes: inout [String]
) {
    let form = commandFieldForm(field, enumNames: enumNames)
    if case .omitted = form { return }

    let optionName = cliOptionName(field)
    let defaultName = kebabCased(field.name)
    var nameArgument: String?
    var shortName: String?
    if case .option(_, let short?) = field.cliHint { shortName = short }
    if optionName != defaultName || shortName != nil {
        var names = [".customLong(\(quoted(optionName)))"]
        if let shortName {
            names.append(".customShort(\"\(shortName)\")")
        }
        nameArgument = "name: [\(names.joined(separator: ", "))]"
    }
    let helpArgument = field.description.map { "help: \(quoted($0))" }

    func wrapperArguments(_ parts: [String?]) -> String {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? "" : "(\(present.joined(separator: ", ")))"
    }

    switch form {
        case .omitted:
            return
        case .direct(let swift):
            if case .flag = field.cliHint {
                lines.append(
                    "    @Flag\(wrapperArguments([nameArgument, helpArgument])) public var \(field.name): Bool = false"
                )
            } else if isPositional(field) {
                lines.append(
                    "    @Argument\(wrapperArguments([helpArgument])) public var \(field.name): \(swift)"
                )
            } else {
                lines.append(
                    "    @Option\(wrapperArguments([nameArgument, helpArgument])) public var \(field.name): \(swift)"
                )
            }
        case .json(let swift):
            let isOptional = swift.hasSuffix("?")
            let base = isOptional ? String(swift.dropLast()) : swift
            let jsonHelp = field.description.map { "\($0) (JSON)" } ?? "JSON value"
            let property = isOptional ? "String?" : "String"
            lines.append(
                "    @Option\(wrapperArguments([nameArgument, "help: \(quoted(jsonHelp))"])) public var \(field.name): \(property)"
            )
            if isOptional {
                preludes.append(
                    "let \(field.name)Value = try MMCLIJSON.decode(\(base).self, from: \(field.name), option: \(quoted(optionName)))"
                )
            } else {
                preludes.append(
                    "let \(field.name)Value = try MMCLIJSON.decodeRequired(\(base).self, from: \(field.name), option: \(quoted(optionName)))"
                )
            }
    }
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

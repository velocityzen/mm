import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import MMSchemaMacros

private let macros: [String: Macro.Type] = ["schema": SchemaContractMacro.self]

/// One exact expansion golden (the minimal case) plus the diagnostics of the
/// static subset. Exact-text goldens are deliberately kept minimal: the real
/// proof lives in MMSchemaTests.SchemaMacroTests, where a full `#schema`
/// expansion — streams, overrides, pinned keys, nesting — is *compiled*,
/// probed, and verified against its own re-emitted contract.
@Suite("SchemaContractMacro expansion")
struct SchemaContractMacroTests {
    @Test("minimal unary call: structs, descriptor, all, contract")
    func minimalUnary() {
        assertMacroExpansion(
            """
            #schema("box") {
                Call("ping") {
                    Access { .read }
                }
            }
            """,
            expandedSource: """
                public struct PingRequest: Codable, Hashable, Sendable, SchemaDescribable, MMPackCodable, MMConstraintValidating {
                    public static var schema: TypeSchema {
                        .structure(fields: [])
                    }
                    public init() {
                    }
                    public func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {
                        writer.writeMapHeader(count: 0)
                    }
                    public init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {
                        try reader.skipValue(depth: depth)
                    }
                    public func constraintViolation(at path: String) -> SchemaValueError? {
                        return nil
                    }
                }
                public struct PingResponse: Codable, Hashable, Sendable, SchemaDescribable, MMPackCodable, MMConstraintValidating {
                    public static var schema: TypeSchema {
                        .structure(fields: [])
                    }
                    public init() {
                    }
                    public func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {
                        writer.writeMapHeader(count: 0)
                    }
                    public init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {
                        try reader.skipValue(depth: depth)
                    }
                    public func constraintViolation(at path: String) -> SchemaValueError? {
                        return nil
                    }
                }
                /// Whether this namespace's calls check a request's constraints before
                /// sending it: in debug builds of the module that declares them.
                #if DEBUG
                public static let checksConstraintsBeforeSending = true
                #else
                public static let checksConstraintsBeforeSending = false
                #endif
                public static let `ping` = Method<PingRequest, PingResponse>(
                    name: "box.ping", access: .read)
                public static var all: [AnyMethod] {
                    [AnyMethod(Self.`ping`)]
                }
                public static let contract: SchemaDeclaration = MMSchema.Schema("box") {
                    MMSchema.Call("ping") {
                            MMSchema.Access {
                                .read
                            }
                        }
                }
                """,
            macros: macros
        )
    }

    @Test("description: re-emits into the contract and namespaceDescription")
    func namespaceDescription() {
        assertMacroExpansion(
            """
            #schema("box", description: "A box of pings.") {
                Call("ping") {
                    Access { .read }
                }
            }
            """,
            expandedSource: """
                public struct PingRequest: Codable, Hashable, Sendable, SchemaDescribable, MMPackCodable, MMConstraintValidating {
                    public static var schema: TypeSchema {
                        .structure(fields: [])
                    }
                    public init() {
                    }
                    public func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {
                        writer.writeMapHeader(count: 0)
                    }
                    public init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {
                        try reader.skipValue(depth: depth)
                    }
                    public func constraintViolation(at path: String) -> SchemaValueError? {
                        return nil
                    }
                }
                public struct PingResponse: Codable, Hashable, Sendable, SchemaDescribable, MMPackCodable, MMConstraintValidating {
                    public static var schema: TypeSchema {
                        .structure(fields: [])
                    }
                    public init() {
                    }
                    public func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {
                        writer.writeMapHeader(count: 0)
                    }
                    public init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {
                        try reader.skipValue(depth: depth)
                    }
                    public func constraintViolation(at path: String) -> SchemaValueError? {
                        return nil
                    }
                }
                /// Whether this namespace's calls check a request's constraints before
                /// sending it: in debug builds of the module that declares them.
                #if DEBUG
                public static let checksConstraintsBeforeSending = true
                #else
                public static let checksConstraintsBeforeSending = false
                #endif
                public static let `ping` = Method<PingRequest, PingResponse>(
                    name: "box.ping", access: .read)
                public static var all: [AnyMethod] {
                    [AnyMethod(Self.`ping`)]
                }
                public static let contract: SchemaDeclaration = MMSchema.Schema("box", description: "A box of pings.") {
                    MMSchema.Call("ping") {
                            MMSchema.Access {
                                .read
                            }
                        }
                }
                public static let namespaceDescription: String? = "A box of pings."
                """,
            macros: macros
        )
    }

    @Test("diagnostics: the static subset is enforced")
    func diagnostics() {
        // A throwing expansion leaves the source unexpanded and reports the
        // error at the expansion site.
        let missingAccess = """
            #schema("box") {
                Call("ping") {
                    Response { Field("ok", .bool) }
                }
            }
            """
        assertMacroExpansion(
            missingAccess,
            expandedSource: missingAccess,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Call(\"ping\") declares no Access — authorization policy is never defaulted",
                    line: 1, column: 1)
            ],
            macros: macros
        )
        let unsupportedShape = """
            #schema("box") {
                Call("put") {
                    Access(.write)
                    Request { Field("data", .unknown) }
                }
            }
            """
        assertMacroExpansion(
            unsupportedShape,
            expandedSource: unsupportedShape,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "put.Request.data: .unknown has no generated Codable counterpart — declare this method with the runtime DSL and hand-written types",
                    line: 1, column: 1)
            ],
            macros: macros
        )
        let conditional = """
            #schema("box") {
                Call("ping") {
                    Access(.read)
                }
                if flag {
                    Call("extra") {
                        Access(.read)
                    }
                }
            }
            """
        assertMacroExpansion(
            conditional,
            expandedSource: conditional,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "#schema supports only Call, Enum, Union, Type, Alias, Error, Errors, CLI and field group declarations at the top level (the macro form is the DSL's static subset — no conditionals)",
                    line: 1, column: 1)
            ],
            macros: macros
        )
        let duplicatePin = """
            #schema("box") {
                Call("put") {
                    Access(.write)
                    Request {
                        Field(2, "a", .string)
                        Field(2, "b", .string)
                    }
                }
            }
            """
        assertMacroExpansion(
            duplicatePin,
            expandedSource: duplicatePin,
            diagnostics: [
                DiagnosticSpec(message: "duplicate field key 2 (b)", line: 1, column: 1)
            ],
            macros: macros
        )
        // A part can BE a named type, or one `.optional` of one: never `X??`
        // (an absent `X?` and a present nil are the same bytes), and never an
        // optional bare shape.
        let payloadCases: [(String, String)] = [
            (
                #"Response(.optional(.optional(.reference("Note"))))"#,
                #"Call("get"): Response payload must be a named-type reference, or .optional of one"#
            ),
            (
                #"Request(.optional(.optional(Other.Note.self)))"#,
                #"Call("get"): Request payload must be a named-type reference, or .optional of one"#
            ),
            (
                #"Response(.optional(.int))"#,
                #"Call("get"): unsupported Response argument .optional(.int)"#
            ),
        ]
        for (part, message) in payloadCases {
            let source = """
                #schema("box") {
                    Type("Note") { Field("text", .string) }
                    Call("get") {
                        Access(.read)
                        \(part)
                    }
                }
                """
            assertMacroExpansion(
                source,
                expandedSource: source,
                diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
                macros: macros
            )
        }
        // `.input`: a required string, one per call, never with a request
        // stream, and `--input` is taken.
        let inputCases: [(String, String)] = [
            (
                #"Request { Field("n", .optional(.string), cli: .input) }"#,
                #"Call("find"): field "n" is cli: .input but not a required .string"#
            ),
            (
                #"Request { Field("a", .string, cli: .input); Field("b", .string, cli: .input) }"#,
                #"Call("find"): only one field can be cli: .input"#
            ),
            (
                #"Request { Field("a", .string, cli: .input); Field("input", .optional(.string)) }"#,
                #"Call("find"): option --input collides with another option — rename with cli: .option("name")"#
            ),
            (
                #"Request { Field("a", .string, cli: .input); Field("b", .optional(.string), cli: .argument) }"#,
                #"Call("find"): field "b" can't be an optional or array positional next to the cli: .input field "a""#
            ),
            (
                #"CLI { Field("d", .string) }; Request { Field("a", .string) }"#,
                #"Call("find"): CLI options need a cli: .input field — an Input(...) body is what reads them"#
            ),
            (
                #"CLI { Field("d", .string, cli: .argument) }; Request { Field("a", .string, cli: .input) }"#,
                #"Call("find"): CLI option "d" must be an option or a flag"#
            ),
            (
                #"CLI { Field("a", .string) }; Request { Field("a", .string, cli: .input) }"#,
                #"Call("find"): CLI option "a" is declared twice, or shares a request field's name"#
            ),
            (
                #"CLI { Field("d", .map(key: .string, value: .int)) }; Request { Field("a", .string, cli: .input) }"#,
                #"Call("find"): CLI option "d" needs a flat shape: a scalar, a wire enum, a calendar/clock kind, or an array of those"#
            ),
            (
                #"CLI { Field("input", .string) }; Request { Field("a", .string, cli: .input) }"#,
                #"Call("find"): option --input collides with another option — rename with cli: .option("name")"#
            ),
            (
                #"CLI { Field("d", .string, default: 1) }; Request { Field("a", .string, cli: .input) }"#,
                #"Call("find"): field "d" default must be a string literal"#
            ),
            (
                #"Request { Field("a", .string, cli: .input); Field("options", .optional(.string)) }"#,
                #"Call("find"): a call with a cli: .input field can't have a request field named "options" — the command's CLI options take that name"#
            ),
            (
                #"CLI(.command("seek")) { Field("d", .string, cli: .argument) }; Request { Field("a", .string, cli: .input) }"#,
                #"Call("find"): CLI option "d" must be an option or a flag"#
            ),
            (
                #"CLI(.omitted) { Field("d", .string) }; Request { Field("a", .string, cli: .input) }"#,
                #"Call("find"): CLI(.omitted) takes no options — no command is generated"#
            ),
            (
                #"Request { Field("a", .string, cli: .input) }; RequestStream("Line") { Field("l", .string) }"#,
                #"Call("find"): cli: .input needs stdin, which the request stream already reads"#
            ),
        ]
        for (parts, message) in inputCases {
            let source = """
                #schema("box") {
                    Call("find") {
                        Access(.read)
                        \(parts.replacingOccurrences(of: "; ", with: "\n"))
                    }
                }
                """
            assertMacroExpansion(
                source,
                expandedSource: source,
                diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
                macros: macros
            )
        }
    }

    @Test("diagnostics: declared errors are checked at expansion")
    func errorDiagnostics() {
        // Each case: the block's top-level entries, the ping call's errors,
        // and the diagnosis.
        let cases: [(top: String, own: String, message: String)] = [
            (
                #"Errors { Case("late", exitCode: 64) }"#, "",
                #"#schema Errors.Case("late"): exitCode must be an integer literal in 2...63 — 0 and 1 mean success and an undeclared failure, 64 and up are sysexits and the shell's"#
            ),
            (
                "", #"Errors { Case("late", exitCode: code) }"#,
                #"Call("ping") Errors.Case("late"): exitCode must be an integer literal in 2...63 — 0 and 1 mean success and an undeclared failure, 64 and up are sysexits and the shell's"#
            ),
            (
                "", #"Errors { Case("late") }"#,
                #"Call("ping") Errors.Case("late") requires exitCode: — the generated CLI exits with it"#
            ),
            (
                #"Errors { Case("unknown", exitCode: 10) }"#, "",
                #"#schema Errors.Case("unknown"): "unknown" is reserved — generated error enums decode unrecognized cases to it"#
            ),
            (
                #"Error("Unknown", exitCode: 10)"#, #"Errors { Case(.reference("Unknown")) }"#,
                #"Call("ping") Errors: Error("Unknown") becomes the case "unknown", which is reserved"#
            ),
            (
                "", #"Errors { Case("a", exitCode: 10); Case("a", exitCode: 11) }"#,
                #"Call("ping") Errors declares error "a" twice"#
            ),
            (
                #"Errors { Case("busy", exitCode: 10) }"#,
                #"Errors { Case("busy", exitCode: 11) }"#,
                #"Call("ping"): error "busy" is also a namespace error — a call's errors add to the namespace's"#
            ),
            (
                #"Errors { Case("busy", exitCode: 10) }"#,
                #"Errors { Case("late", exitCode: 10) }"#,
                #"Call("ping"): errors "busy" and "late" share exit code 10"#
            ),
            (
                #"Enum("Kind") { Case("a") }"#,
                #"Errors { Case("odd", .reference("Kind"), exitCode: 10) }"#,
                #"Call("ping") Errors.Case("odd"): carries "Kind", an Enum or Union of this block — an error case carries a Type or Error"#
            ),
            (
                "", #"Errors { Case("odd", .reference("Missing"), exitCode: 10) }"#,
                #"Call("ping") Errors.Case("odd"): carries "Missing", no declaration of this block — an error case carries a Type or Error"#
            ),
            (
                "", #"Errors { Case(.reference("Missing")) }"#,
                #"Call("ping") Errors: Case(.reference("Missing")) names no Error declared in this block"#
            ),
            (
                #"Type("Conflict") { Field("x", .int) }"#,
                #"Errors { Case("odd", .reference("Conflict"), exitCode: 10) { Field("y", .int) } }"#,
                #"Call("ping") Errors.Case("odd"): a case carries either a .reference(...) or fields, not both"#
            ),
            (
                "",
                #"Errors { Case("odd", exitCode: 10) { Field("inner") { Field("x", .int) } } }"#,
                #"Call("ping") Errors.Case("odd"): field "inner" declares a nested struct — declare a Type and carry it with Case("name", .reference("Type"), exitCode:)"#
            ),
            (
                "",
                #"Errors { Case("odd", exitCode: 10) { Field("mode", .enumeration(cases: [.init(name: "a")])) } }"#,
                #"Call("ping") Errors.Case("odd"): field "mode" declares an inline .enumeration — declare an Enum and name it: Field("mode", "Name")"#
            ),
            (
                #"Error("Full", exitCode: 12)"#,
                #"Errors { Case("odd", exitCode: 10) { Field("x", "Full") } }"#,
                #"Call("ping") Errors.Case("odd").x: reference "Full" does not resolve to an Enum/Type/Union declared in this block"#
            ),
            (
                #"Error("Error", exitCode: 12)"#, "",
                #"Error("Error"): "Error" is the namespace's generated error enum — name the error after what failed"#
            ),
            (
                #"Error("Full", exitCode: 12); Type("Full") { Field("x", .int) }"#, "",
                #"Error("Full") collides with another declaration — rename the Error or the Type/Enum"#
            ),
            (
                #"Error("Full", exitCode: 12); Error("Full", exitCode: 13)"#, "",
                #"Error("Full") is declared twice"#
            ),
            (
                #"Type("Error") { Field("x", .int) }; Errors { Case("busy", exitCode: 10) }"#, "",
                #"the namespace's generated error enum "Error" collides with another declaration — rename it"#
            ),
            (
                #"Type("PingError") { Field("x", .int) }"#,
                #"Errors { Case("busy", exitCode: 10) }"#,
                #"Call("ping"): generated error enum "PingError" collides with another declaration — rename the Type/Enum/Error"#
            ),
            (
                #"Errors { Case("a", exitCode: 10) }; Errors { Case("b", exitCode: 11) }"#, "",
                "#schema declares Errors twice — the namespace's errors go in one block"
            ),
            (
                "", #"Errors { Case("a", exitCode: 10) }; Errors { Case("b", exitCode: 11) }"#,
                #"Call("ping"): Errors declared twice"#
            ),
        ]
        for (top, own, message) in cases {
            let source = """
                #schema("box") {
                    \(top.replacingOccurrences(of: "; ", with: "\n"))
                    Call("ping") {
                        Access(.read)
                        \(own.replacingOccurrences(of: "; ", with: "\n"))
                    }
                }
                """
            assertMacroExpansion(
                source,
                expandedSource: source,
                diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
                macros: macros
            )
        }
    }

    @Test("diagnostics: constraints and named scalars are checked at expansion")
    func constraintDiagnostics() {
        // Each case: the block's declarations before the call, the put
        // call's request fields, and the diagnosis.
        let cases: [(top: String, fields: String, message: String)] = [
            (
                "", #"Field("limit", .int, constraints: .range(0.5...2.0))"#,
                #"put.Request: Field("limit"): a range on int takes integer bounds"#
            ),
            (
                "", #"Field("name", .string, constraints: .range(1...3))"#,
                #"put.Request: Field("name"): a range applies to int, uint, float or double, not string"#
            ),
            (
                "", #"Field("count", .int, constraints: .length(...3))"#,
                #"put.Request: Field("count"): a length applies to string, bytes, an array or a map, not int"#
            ),
            (
                "", #"Field("count", .int, constraints: .range(5...1))"#,
                #"put.Request: Field("count"): a range's minimum 5 is more than its maximum 1"#
            ),
            (
                "", #"Field("slug", .string, constraints: .pattern("[a-"))"#,
                #"put.Request: Field("slug"): the pattern [a- does not compile"#
            ),
            (
                "", #"Field("tags", .array(.string), constraints: .nonEmpty, .length(...3))"#,
                #"put.Request: Field("tags") declares a length twice"#
            ),
            (
                #"Alias("Slug", .string, constraints: .nonEmpty)"#,
                #"Field("slug", .reference("Slug"), constraints: .length(...8))"#,
                #"put.Request: Field("slug"): a field of the named type Slug takes its constraints from the type"#
            ),
            (
                "", #"Field("owner", constraints: .nonEmpty) { Field("name", .string) }"#,
                #"put.Request: Field("owner") declares a nested block, which takes no constraints — constrain its fields"#
            ),
            (
                #"Alias("Tags", .array(.string))"#, #"Field("tags", .reference("Tags"))"#,
                #"Alias("Tags") names an array: an Alias names a scalar kind"#
            ),
            (
                #"Alias("Level", .int, constraints: .range(0.0...1.0))"#,
                #"Field("level", .reference("Level"))"#,
                #"Alias("Level"): a range on int takes integer bounds"#
            ),
        ]
        for (top, fields, message) in cases {
            let source = """
                #schema("box") {
                    \(top)
                    Call("put") {
                        Access(.write)
                        Request {
                            \(fields)
                        }
                    }
                }
                """
            assertMacroExpansion(
                source,
                expandedSource: source,
                diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
                macros: macros
            )
        }
    }

    @Test("diagnostics: wire defaults, reserved keys and deprecations are checked at expansion")
    func evolutionDiagnostics() {
        // Each case: the block's declarations before the call, the put
        // call's request fields, and the diagnosis.
        let cases: [(top: String, fields: String, message: String)] = [
            (
                "", #"Field("limit", .int, default: 1.5)"#,
                #"Call("put").Request: field "limit": the default 1.5 is no value of int"#
            ),
            (
                "", #"Field("limit", .int, constraints: .range(1...10), default: 20)"#,
                #"Call("put").Request: field "limit": the default 20 is more than the maximum 10"#
            ),
            (
                "", #"Field("count", .uint, default: -1)"#,
                #"Call("put").Request: field "count": the default -1 is no value of uint"#
            ),
            (
                "", #"Field("score", .float, default: 1e39)"#,
                #"Call("put").Request: field "score": the default 1e39 is beyond float"#
            ),
            (
                "", #"Field("at", .timestamp, default: .now)"#,
                #"Call("put").Request: field "at": .now is a CLI default, read when the command runs; a field that is not optional takes a fixed default"#
            ),
            (
                "", #"Field("tags", .array(.string), default: "x")"#,
                #"Call("put").Request: field "tags": a field of an array takes no default"#
            ),
            (
                "", #"Field("slug", .string, constraints: .pattern("[a-z]+"), default: "A")"#,
                #"Call("put").Request: field "slug": the default "A" does not match the pattern [a-z]+"#
            ),
            (
                #"Enum("Level") { Case("low") }"#, #"Field("level", "Level", default: "high")"#,
                #"Call("put").Request: field "level": the default must name a case of Level (low)"#
            ),
            (
                #"Type("Inner") { Field("x", .int) }"#, #"Field("inner", "Inner", default: "x")"#,
                #"Call("put").Request: field "inner": a field of Inner, a structure or union, takes no default"#
            ),
            (
                #"Alias("Ratio", .double, constraints: .range(0...1))"#,
                #"Field("ratio", "Ratio", default: 2)"#,
                #"Call("put").Request: field "ratio" of Ratio: the default 2 is more than the maximum 1.0"#
            ),
            (
                "", #"Field("meta", Other.Meta.self, default: "x")"#,
                #"Call("put").Request: field "meta": Other.Meta is declared in another block, which this one cannot check a default against — a cross-schema reference takes no default"#
            ),
            (
                "", #"Field(1, "a", .int); Reserved(1)"#,
                #"put.Request: field key 1 is reserved (a)"#
            ),
            (
                "", #"Reserved("old"); Field("old", .int)"#,
                #"put.Request: field name "old" is reserved"#
            ),
            (
                "", #"Reserved(-1)"#,
                #"put.Request: Reserved(...) takes non-negative integer literals and non-empty string literals, not -1"#
            ),
            (
                "", #"Field("_a", .int); Field("a", .int, deprecated: "use b")"#,
                #"PutRequest: field "a" is deprecated and keeps its value in "_a", another field's name — rename one"#
            ),
            (
                "", #"Field("text", .string, deprecated: "gone", cli: .input)"#,
                #"Call("put"): field "text" is cli: .input, which the input runner writes, so it cannot be deprecated"#
            ),
        ]
        for (top, fields, message) in cases {
            let source = """
                #schema("box") {
                    \(top)
                    Call("put") {
                        Access(.write)
                        Request {
                            \(fields)
                        }
                    }
                }
                """
            assertMacroExpansion(
                source,
                expandedSource: source,
                diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
                macros: macros
            )
        }
    }
    @Test("diagnostics: inline enumerations are checked at expansion")
    func inlineEnumerationDiagnostics() {
        // Each case: the block's declarations before the call, the put
        // call's request fields, and the diagnosis.
        let one = #".enumeration(cases: [.init(name: "a")])"#
        let rename = "rename the field or declare a named Enum"
        let cases: [(top: String, fields: String, message: String)] = [
            (
                "", #"Field("mode", .enumeration(cases: [Case("a")]))"#,
                #"put.Request.mode: an inline .enumeration case is .init(name: "a", description:, deprecation:) with literal strings, not Case("a") (static subset)"#
            ),
            (
                "", #"Field("mode", .enumeration(cases: modes))"#,
                #"put.Request.mode: an inline .enumeration lists its cases in an array literal: .enumeration(cases: [.init(name: "a")]) (static subset)"#
            ),
            (
                "", #"Field("mode", .enumeration(cases: [.init(name: "a", rank: 1)]))"#,
                "put.Request.mode: unsupported inline .enumeration case argument rank: 1"
            ),
            (
                "", #"Field("mode", .enumeration(cases: [.init(name: "a-b")]))"#,
                #"put.Request.mode: case name "a-b" must be a Swift identifier — it is both the wire value and the generated case"#
            ),
            (
                "", #"Field("mode", .enumeration(cases: [.init(name: "unknown")]))"#,
                #"put.Request.mode: "unknown" is reserved — the macro generates it as the unrecognized-value fallback (house wire-enum rule)"#
            ),
            (
                "", #"Field("mode", .enumeration(cases: [.init(name: "a"), .init(name: "a")]))"#,
                #"put.Request.mode: the inline .enumeration declares case "a" twice"#
            ),
            (
                "", #"Field("mode", .enumeration(cases: []))"#,
                "put.Request.mode: the inline .enumeration declares no cases"
            ),
            (
                "", #"Field("mode", \#(one), default: "b")"#,
                #"Call("put").Request: field "mode": the default must name a case of Mode (a)"#
            ),
            (
                "", #"Field("mode", .optional(\#(one)), default: "a")"#,
                #"Call("put"): field "mode" default: is not supported on enum or alias fields"#
            ),
            (
                "", #"Field("modes", .map(key: \#(one), value: .int))"#,
                "put.Request.modes: map keys must be .string, .int, or .uint"
            ),
            (
                #"Alias("Mode", \#(one))"#, #"Field("x", .int)"#,
                #"Alias("Mode"): an inline .enumeration takes its name from its field, and there is none here — declare a named Enum in this block"#
            ),
            (
                "", #"Field("Mode", .optional(.int), cli: .omitted); Field("mode", \#(one))"#,
                #"PutRequest: field "mode" generates the nested enum Mode, the name of another field — \#(rename)"#
            ),
            (
                "",
                #"Field("inner") { Field("mode") { Field("x", .int) } }; Field("mode", \#(one))"#,
                #"PutRequest: field "mode" generates the nested enum Mode, the name of a nested struct in PutRequest — \#(rename)"#
            ),
            (
                #"Union("U") { Case("a") { Field("mode", \#(one)) }; Case("b") { Field("mode", \#(one)) } }"#,
                #"Field("x", .int)"#,
                #"U: field "mode" generates the nested enum Mode, which another field "mode" generates too — \#(rename)"#
            ),
            (
                "", #"Field("type", \#(one))"#,
                #"PutRequest: field "type" generates the nested enum Type, a name Swift or the generated code keeps — \#(rename)"#
            ),
            (
                "", #"Field("string", \#(one))"#,
                #"PutRequest: field "string" generates the nested enum String, a name Swift or the generated code keeps — \#(rename)"#
            ),
            (
                "", #"Field("codingKeys", \#(one))"#,
                #"PutRequest: field "codingKeys" generates the nested enum CodingKeys, the name of a member PutRequest generates — \#(rename)"#
            ),
            (
                #"Union("U") { Case("a") { Field("aCodingKeys", \#(one)) } }"#,
                #"Field("x", .int)"#,
                #"U: field "aCodingKeys" generates the nested enum ACodingKeys, the name of a member U generates — \#(rename)"#
            ),
            (
                #"Type("Mode") { Field("mode", \#(one)) }"#, #"Field("x", .int)"#,
                #"Mode: field "mode" generates the nested enum Mode, the name of Mode itself — \#(rename)"#
            ),
            (
                #"Enum("Condition") { Case("new") }"#,
                #"Field("condition", \#(one)); Field("previous", "Condition")"#,
                #"PutRequest: field "condition" generates the nested enum Condition, which would hide the type Condition that field "previous" names — \#(rename)"#
            ),
            (
                "", #"Field("other", \#(one)); Field("meta", Other.Meta.self)"#,
                #"PutRequest: field "other" generates the nested enum Other, which would hide the type Other that field "meta" names — \#(rename)"#
            ),
        ]
        for (top, fields, message) in cases {
            let source = """
                #schema("box") {
                    \(top)
                    Call("put") {
                        Access(.write)
                        Request {
                            \(fields)
                        }
                    }
                }
                """
            assertMacroExpansion(
                source,
                expandedSource: source,
                diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
                macros: macros
            )
        }
        // A CLI option is no wire field: there is no type to nest its enum in.
        let option = """
            #schema("box") {
                CLI(.enabled)
                Call("put") {
                    CLI {
                        Field("mode", \(one))
                    }
                    Access(.write)
                    Request {
                        Field("text", .string, cli: .input)
                    }
                }
            }
            """
        assertMacroExpansion(
            option,
            expandedSource: option,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        #"Call("put"): CLI option "mode" declares an inline .enumeration, which has no type to generate into — declare an Enum and name it: Field("mode", "Name")"#,
                    line: 1, column: 1)
            ],
            macros: macros
        )
    }

    @Test("diagnostics: types that hold themselves and field groups are checked at expansion")
    func compositionDiagnostics() {
        // Each case: the block's declarations before the call, the put
        // call's request fields, and the diagnosis.
        let endless =
            "has no finite value: every value of it holds another value of a type on its cycle, without end — make a field on the way optional, or an array"
        let groupsOnly =
            "#schema declares only field groups besides its entries: let name = FieldGroup { ... } (static subset)"
        let cases: [(top: String, fields: String, message: String)] = [
            (#"Type("A") { Field("a", "A") }"#, #"Field("x", .int)"#, #"Type("A") \#(endless)"#),
            (
                #"Type("A") { Field("b", "B") }; Type("B") { Field("a", .array(.reference("A"))); Field("c", "A") }"#,
                #"Field("x", .int)"#, #"Type("A") \#(endless)"#
            ),
            (
                #"Union("U") { Case("a") { Field("u", "U") }; Case("b") { Field("n", "N") } }; Type("N") { Field("u", "U") }"#,
                #"Field("x", .int)"#, #"Union("U") \#(endless)"#
            ),
            (
                #"Type("A") { Field("_a", .int); Field("a", .optional(.reference("A"))) }"#,
                #"Field("x", .int)"#,
                #"A: field "a" holds A and keeps its box in "_a", another field's name — rename one"#
            ),
            (#"var audit = FieldGroup { Field("a", .int) }"#, #"audit"#, groupsOnly),
            (#"let count = 3"#, #"Field("x", .int)"#, groupsOnly),
            (#"let audit = FieldGroup(Field("a", .int))"#, #"audit"#, groupsOnly),
            (
                "", #"audit"#,
                #"put.Request: audit is not a field group the block declares — the macro expands a group declared at the top of the block: let audit = FieldGroup { ... }"#
            ),
        ]
        for (top, fields, message) in cases {
            let source = """
                #schema("box") {
                    \(top)
                    Call("put") {
                        Access(.write)
                        Request {
                            \(fields)
                        }
                    }
                }
                """
            assertMacroExpansion(
                source,
                expandedSource: source,
                diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
                macros: macros
            )
        }
    }
}

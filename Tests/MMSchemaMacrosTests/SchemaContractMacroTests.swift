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
                public struct PingRequest: Codable, Hashable, Sendable, SchemaDescribable {
                    public static var schema: TypeSchema {
                        .structure(fields: [])
                    }
                    public init() {
                    }
                }
                public struct PingResponse: Codable, Hashable, Sendable, SchemaDescribable {
                    public static var schema: TypeSchema {
                        .structure(fields: [])
                    }
                    public init() {
                    }
                }
                public static let `ping` = Method<PingRequest, PingResponse>(
                    name: "box.ping", access: .read)
                public static var all: [AnyMethod] {
                    [AnyMethod(Self.`ping`)]
                }
                public static let contract: SchemaDeclaration = Schema("box") {
                    Call("ping") {
                            Access {
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
                public struct PingRequest: Codable, Hashable, Sendable, SchemaDescribable {
                    public static var schema: TypeSchema {
                        .structure(fields: [])
                    }
                    public init() {
                    }
                }
                public struct PingResponse: Codable, Hashable, Sendable, SchemaDescribable {
                    public static var schema: TypeSchema {
                        .structure(fields: [])
                    }
                    public init() {
                    }
                }
                public static let `ping` = Method<PingRequest, PingResponse>(
                    name: "box.ping", access: .read)
                public static var all: [AnyMethod] {
                    [AnyMethod(Self.`ping`)]
                }
                public static let contract: SchemaDeclaration = Schema("box", description: "A box of pings.") {
                    Call("ping") {
                            Access {
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
                    Request { Field("data", .bytes) }
                }
            }
            """
        assertMacroExpansion(
            unsupportedShape,
            expandedSource: unsupportedShape,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "put.Request.data: .bytes has no generated Codable counterpart — declare this method with the runtime DSL and hand-written types",
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
                        "#schema supports only Call, Enum, Type, and CLI declarations at the top level (the macro form is the DSL's static subset — no conditionals)",
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
}

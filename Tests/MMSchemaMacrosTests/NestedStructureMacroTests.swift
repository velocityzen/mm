import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

import MMSchemaCodeGenerator

@testable import MMSchemaMacros

private let macros: [String: Macro.Type] = ["schema": SchemaContractMacro.self]

/// The dotted path of every struct, enum and union the `#schema` in `source`
/// generates, in declaration order: `T.A.B` for a struct `B` in `A` in `T`.
func generatedTypePaths(_ source: String) throws -> [String] {
    let item = Parser.parse(source: source).statements.first?.item
    let declarations =
        if let declaration = item?.as(MacroExpansionDeclSyntax.self) {
            try SchemaCodeGenerator.expandSchema(declaration).declarations
        } else {
            try SchemaCodeGenerator.expandSchema(
                try #require(item?.as(MacroExpansionExprSyntax.self))
            )
            .declarations
        }
    let collector = TypePathCollector(viewMode: .sourceAccurate)
    for declaration in declarations {
        collector.walk(Parser.parse(source: declaration))
    }
    return collector.paths
}

/// Collects the dotted paths of the struct and enum declarations it walks.
final class TypePathCollector: SyntaxVisitor {
    private(set) var paths: [String] = []
    private var enclosing: [String] = []

    private func enter(_ name: TokenSyntax) -> SyntaxVisitorContinueKind {
        self.enclosing.append(name.text)
        self.paths.append(self.enclosing.joined(separator: "."))
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        self.enter(node.name)
    }
    override func visitPost(_ node: StructDeclSyntax) { self.enclosing.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        self.enter(node.name)
    }
    override func visitPost(_ node: EnumDeclSyntax) { self.enclosing.removeLast() }
}

@Suite("SchemaContractMacro: nested structures")
struct NestedStructureMacroTests {
    @Test("a nested struct is generated once, in the type that holds its field")
    func nestedStructsLiveInTheirHolders() throws {
        let source = """
            #schema("box") {
                Type("T") {
                    Field("a") {
                        Field("b") { Field("x", .int) }
                    }
                    Field("c") {
                        Field("b") { Field("y", .string) }
                    }
                }
                Union("U") {
                    Case("left") {
                        Field("a") {
                            Field("b") { Field("x", .int) }
                        }
                    }
                    Case("right") {
                        Field("c") {
                            Field("b") { Field("y", .string) }
                        }
                    }
                }
                Call("put") {
                    Access(.write)
                    Request {
                        Field("a") {
                            Field("b") {
                                Field("a") { Field("x", .int) }
                            }
                        }
                    }
                }
            }
            """
        let paths = try generatedTypePaths(source)
        let nested = paths.filter { ["T.", "U.", "PutRequest."].contains(where: $0.hasPrefix) }
            .filter { !$0.hasSuffix("CodingKeys") }
        #expect(
            nested == [
                "T.A", "T.A.B", "T.C", "T.C.B",
                "U.A", "U.A.B", "U.C", "U.C.B",
                "PutRequest.A", "PutRequest.A.B", "PutRequest.A.B.A",
            ]
        )
    }

    @Test("diagnostics: union cases share one scope for the structs they nest directly")
    func unionCasesShareTheirScope() {
        let source = """
            #schema("box") {
                Union("U") {
                    Case("left") { Field("b") { Field("x", .int) } }
                    Case("right") { Field("b") { Field("y", .string) } }
                }
                Call("put") {
                    Access(.write)
                    Request { Field("u", "U") }
                }
            }
            """
        assertMacroExpansion(
            source,
            expandedSource: source,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        #"Union("U"): nested struct "B" is declared by two cases — rename one field"#,
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }
}

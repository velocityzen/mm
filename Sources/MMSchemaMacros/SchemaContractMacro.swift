import MMSchemaCodeGenerator
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct MMSchemaPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [SchemaContractMacro.self, SchemaTypesMacro.self]
}

/// `#schema("journal") { Call("append") { ... } }` — expands the declarative
/// contract into the wire types, typed descriptors, namespace lists, and the
/// runtime contract (see `SchemaCodeGenerator.expandSchema` for the full list).
///
/// A `CLI(.enabled)` entry does NOT make the macro emit commands: those come
/// from the MMCLIGeneratorPlugin build-tool plugin applied to the CLI target, so the
/// module holding the schema — shared with the daemon — never depends on
/// MMCLI or swift-argument-parser. The macro still validates every CLI hint
/// (a bad one is an authoring mistake either way) and insists on a named
/// enclosing type, which the generated commands extend.
public struct SchemaContractMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let expansion = try SchemaCodeGenerator.expandSchema(node)
        if expansion.cliEnabled, !hasNamedEnclosingType(context.lexicalContext) {
            throw SchemaMacroError(
                description:
                    "#schema with CLI(.enabled) requires expansion inside a named type declaration"
            )
        }
        return expansion.declarations.map { DeclSyntax("\(raw: $0)") }
    }
}

/// `#schemaTypes("common") { Enum(...) Type(...) }` — the types-only
/// counterpart. See the macro declaration in MMSchema for the full story.
public struct SchemaTypesMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try SchemaCodeGenerator.expandSchemaTypes(node).map { DeclSyntax("\(raw: $0)") }
    }
}

private func hasNamedEnclosingType(_ lexicalContext: [Syntax]) -> Bool {
    lexicalContext.contains { scope in
        scope.is(EnumDeclSyntax.self) || scope.is(StructDeclSyntax.self)
            || scope.is(ActorDeclSyntax.self) || scope.is(ClassDeclSyntax.self)
            || scope.is(ExtensionDeclSyntax.self)
    }
}

import SwiftSyntax

/// The field groups a block declares, `let audit = FieldGroup { ... }`, and
/// their uses: a bare `audit` among a fields block's entries.
///
/// The runtime DSL puts a group's fields where the group is used, as if
/// they were written there, and then keys the block. The macro does the
/// same before it reads the block: each use of a group becomes the group's
/// statements, so every later step sees only literal `Field(...)` and
/// `Reserved(...)` entries, and keys them as the runtime does.
struct FieldGroupExpansion {
    /// Each declared group's statements, its uses of earlier groups already
    /// replaced.
    private var groups: [String: CodeBlockItemListSyntax] = [:]

    /// Reads `declaration`, a top-level statement of the block `context`
    /// names: the one declaration the static subset takes there is
    /// `let name = FieldGroup { ... }`. A group's body may use the groups
    /// declared before it, as Swift requires.
    mutating func declare(_ declaration: VariableDeclSyntax, context: String) throws {
        guard declaration.bindingSpecifier.tokenKind == .keyword(.let),
            declaration.bindings.count == 1,
            let binding = declaration.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            binding.typeAnnotation.map({ $0.type.trimmedDescription == "FieldGroup" }) ?? true,
            let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
            calleeName(call) == "FieldGroup",
            call.arguments.isEmpty,
            call.additionalTrailingClosures.isEmpty,
            let body = call.trailingClosure
        else {
            throw SchemaMacroError(
                description:
                    "\(context) declares only field groups besides its entries: let name = FieldGroup { ... } (static subset)"
            )
        }
        self.groups[pattern.identifier.text] = self.expanding(body.statements)
    }

    /// `node` with each use of a declared group, at any depth, replaced by
    /// the group's statements.
    func expanding<Node: SyntaxProtocol>(_ node: Node) -> Node {
        guard !self.groups.isEmpty else { return node }
        return GroupUseRewriter(groups: self.groups).rewrite(node).cast(Node.self)
    }
}

/// Replaces each statement that is a bare reference to a declared group with
/// the group's statements.
private final class GroupUseRewriter: SyntaxRewriter {
    let groups: [String: CodeBlockItemListSyntax]

    init(groups: [String: CodeBlockItemListSyntax]) {
        self.groups = groups
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        let visited = super.visit(node)
        var items: [CodeBlockItemSyntax] = []
        for item in visited {
            if let reference = item.item.as(DeclReferenceExprSyntax.self),
                reference.argumentNames == nil,
                let group = self.groups[reference.baseName.text]
            {
                items.append(contentsOf: group)
            } else {
                items.append(item)
            }
        }
        return CodeBlockItemListSyntax(items)
    }
}

import MMSchema
import Testing

@Suite("TypeSchema fold")
struct TypeSchemaFoldTests {
    /// A describe-style fold: every walker that used to hand-roll this
    /// recursion is one transform like this now.
    private func describe(_ schema: TypeSchema, resolver: TypeResolver) -> String {
        schema.fold(resolver: resolver) { (step: TypeSchema.FoldStep<String>) in
            switch step {
                case .bool: return "bool"
                case .int: return "int"
                case .uint: return "uint"
                case .float: return "float"
                case .double: return "double"
                case .string: return "string"
                case .bytes: return "bytes"
                case .optional(let wrapped): return "\(wrapped)?"
                case .array(let element): return "[\(element)]"
                case .map(let key, let value): return "[\(key): \(value)]"
                case .structure(let fields):
                    let body = fields.map { "\($0.field.name): \($0.value)" }
                        .joined(separator: ", ")
                    return "{\(body)}"
                case .enumeration(let cases):
                    return "enum(\(cases.map(\.name).joined(separator: "|")))"
                case .unresolvedReference(.unresolved(let name)): return "?\(name)"
                case .unresolvedReference(.cycle(let name)): return "cycle(\(name))"
                case .unknown: return "unknown"
            }
        }
    }

    @Test("one transform describes a nested schema, references resolved")
    func describeFold() {
        let resolver = TypeResolver([
            TypeDefinition(
                name: "box.Priority",
                schema: .enumeration(cases: [.init(name: "low"), .init(name: "high")]))
        ])
        let schema = TypeSchema.structure(fields: [
            .init(key: 0, name: "lines", type: .array(.string)),
            .init(key: 1, name: "priority", type: .optional(.reference("box.Priority"))),
            .init(key: 2, name: "weights", type: .map(key: .string, value: .double)),
        ])
        #expect(
            describe(schema, resolver: resolver)
                == "{lines: [string], priority: enum(low|high)?, weights: [string: double]}")
    }

    @Test("a self-recursive structure surfaces as a cycle step, not a hang")
    func recursiveStructure() {
        let resolver = TypeResolver([
            TypeDefinition(
                name: "tree.Node",
                schema: .structure(fields: [
                    .init(key: 0, name: "value", type: .int),
                    .init(key: 1, name: "child", type: .optional(.reference("tree.Node"))),
                ]))
        ])
        #expect(
            describe(.reference("tree.Node"), resolver: resolver)
                == "{value: int, child: cycle(tree.Node)?}")
    }

    @Test("an unresolved name surfaces as its own step")
    func unresolvedReference() {
        #expect(describe(.reference("no.Such"), resolver: TypeResolver([])) == "?no.Such")
    }
}

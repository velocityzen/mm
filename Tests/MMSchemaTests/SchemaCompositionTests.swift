import Foundation
import Testing

@testable import MMSchema

/// Types that hold themselves, and a field group, declared through
/// `#schema` and compiled into this test target.
private enum Outline: MethodNamespace {
    #schema("outline") {
        let audit = FieldGroup {
            Field("author", .string)
            Field(9, "revision", .int)
        }
        Type("Node") {
            Field("title", .string)
            Field("parent", .optional(.reference("Node")))
            Field("children", .array(.reference("Node")))
            Field("note") {
                Field("next", .optional(.reference("Node")))
            }
            audit
        }
        Type("Ring") {
            Field("link", "Link")
        }
        Type("Link") {
            Field("ring", .optional(.reference("Ring")))
        }
        Union("Expression") {
            Case("number") { Field("value", .int) }
            Case("negated") { Field("operand", "Expression") }
            Case("sum") {
                Field("left", "Expression")
                Field("right", "Expression")
            }
            Case("grouped") {
                Field("inner") {
                    Field("expression", .optional(.reference("Expression")))
                }
            }
        }
        Call("evaluate") {
            Access { .read }
            Request {
                Field("expression", "Expression")
            }
            Response {
                Field("value", .int)
                audit
            }
        }
    }
}

@Suite("Types that hold themselves, and field groups")
struct SchemaCompositionTests {
    @Test("the generated types honor the re-emitted contract")
    func contractFidelity() throws {
        #expect(try Outline.contract.verify(against: Outline.self).get() == [])
    }

    @Test("a struct holds itself through an optional, a nested structure and another type")
    func recursiveStructures() throws {
        let root = Outline.Node(
            title: "root",
            parent: nil,
            children: [],
            note: .init(next: nil),
            author: "ada",
            revision: 1
        )
        let node = Outline.Node(
            title: "leaf",
            parent: root,
            children: [root],
            note: .init(next: root),
            author: "ada",
            revision: 2
        )
        #expect(node.parent == root)
        #expect(node.note.next?.title == "root")
        let ring = Outline.Ring(link: .init(ring: .init(link: .init(ring: nil))))
        #expect(ring.link.ring?.link.ring == nil)
        let coded = try JSONDecoder().decode(
            Outline.Node.self,
            from: JSONEncoder().encode(node)
        )
        #expect(coded == node)
        #expect(coded.hashValue == node.hashValue)
        #expect(
            try JSONDecoder().decode(Outline.Ring.self, from: JSONEncoder().encode(ring)) == ring
        )
    }

    @Test("a change to a copy of a value that holds itself leaves the original as it was")
    func copiesKeepTheirValues() {
        let original = Outline.Node(
            title: "a",
            parent: .init(
                title: "b",
                parent: nil,
                children: [],
                note: .init(next: nil),
                author: "",
                revision: 0
            ),
            children: [],
            note: .init(next: nil),
            author: "",
            revision: 0
        )
        var copy = original
        copy.parent?.title = "changed"
        copy.note.next = original
        #expect(original.parent?.title == "b")
        #expect(original.note.next == nil)
        #expect(copy.parent?.title == "changed")
        #expect(copy.note.next == original)
    }

    @Test("a union case holds the union itself, directly and through a nested structure")
    func recursiveUnions() throws {
        let expression = Outline.Expression.sum(
            left: .negated(operand: .number(value: 2)),
            right: .grouped(inner: .init(expression: .number(value: 3)))
        )
        guard case .sum(let left, _) = expression, case .negated(.number(let value)) = left
        else {
            Issue.record("\(expression)")
            return
        }
        #expect(value == 2)
        #expect(
            try JSONDecoder().decode(
                Outline.Expression.self,
                from: JSONEncoder().encode(expression)
            ) == expression
        )
    }

    @Test("a field group's fields take their keys where the group is used")
    func groupKeys() {
        typealias NodeKeys = Outline.Node.CodingKeys
        #expect(
            [NodeKeys.title, .parent, .children, .note, .author, .revision].map(\.rawValue)
                == [0, 1, 2, 3, 4, 9]
        )
        typealias ResponseKeys = Outline.EvaluateResponse.CodingKeys
        #expect([ResponseKeys.value, .author, .revision].map(\.rawValue) == [0, 1, 9])
        // The contract with the group's fields written in its places.
        let written = Schema("outline") {
            Type("Node") {
                Field("title", .string)
                Field("parent", .optional(.reference("Node")))
                Field("children", .array(.reference("Node")))
                Field("note") {
                    Field("next", .optional(.reference("Node")))
                }
                Field("author", .string)
                Field(9, "revision", .int)
            }
            Type("Ring") {
                Field("link", "Link")
            }
            Type("Link") {
                Field("ring", .optional(.reference("Ring")))
            }
            Union("Expression") {
                Case("number") { Field("value", .int) }
                Case("negated") { Field("operand", "Expression") }
                Case("sum") {
                    Field("left", "Expression")
                    Field("right", "Expression")
                }
                Case("grouped") {
                    Field("inner") {
                        Field("expression", .optional(.reference("Expression")))
                    }
                }
            }
            Call("evaluate") {
                Access { .read }
                Request {
                    Field("expression", "Expression")
                }
                Response {
                    Field("value", .int)
                    Field("author", .string)
                    Field(9, "revision", .int)
                }
            }
        }
        #expect(Outline.contract == written)
    }

    @Test("the runtime DSL takes a group in every fields block, and a group in a group")
    func runtimeGroups() {
        let stamp = FieldGroup {
            Field("at", .timestamp)
        }
        let audit = FieldGroup {
            Field("author", .string)
            Reserved(5)
            stamp
        }
        let grouped = Schema("shelf") {
            Type("Book") {
                Field("title", .string)
                audit
            }
            Union("Change") {
                Case("added") {
                    audit
                    Field("book", "Book")
                }
            }
            Call("put") {
                Access { .write }
                Request {
                    Field("book", "Book")
                    Field("tags", .array(Fields { audit }))
                }
                Response {
                    Field("owner") { audit }
                }
            }
        }
        let written = Schema("shelf") {
            Type("Book") {
                Field("title", .string)
                Field("author", .string)
                Reserved(5)
                Field("at", .timestamp)
            }
            Union("Change") {
                Case("added") {
                    Field("author", .string)
                    Reserved(5)
                    Field("at", .timestamp)
                    Field("book", "Book")
                }
            }
            Call("put") {
                Access { .write }
                Request {
                    Field("book", "Book")
                    Field(
                        "tags",
                        .array(
                            Fields {
                                Field("author", .string)
                                Reserved(5)
                                Field("at", .timestamp)
                            }
                        )
                    )
                }
                Response {
                    Field("owner") {
                        Field("author", .string)
                        Reserved(5)
                        Field("at", .timestamp)
                    }
                }
            }
        }
        #expect(grouped == written)
    }
}

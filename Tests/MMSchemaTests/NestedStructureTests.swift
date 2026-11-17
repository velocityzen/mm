import Foundation
import Testing

@testable import MMSchema

/// Nested structures at several depths, each generated in the type that
/// holds its field: sibling fields that each nest a struct of the same name,
/// in a type, in a union's cases and in a request, and a struct that takes
/// the name of a struct it is nested in.
private enum Nest: MethodNamespace {
    #schema("nest") {
        Type("Holder") {
            Field("a") {
                Field("b") { Field("x", .int) }
            }
            Field("c") {
                Field("b") { Field("y", .string) }
            }
        }
        Union("Choice") {
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
            Access { .write }
            Request {
                Field("a") {
                    Field("b") {
                        Field("a") { Field("x", .int) }
                    }
                }
                Field("c") {
                    Field("b") { Field("y", .string) }
                }
            }
            Response {
                Field("holder", "Holder")
                Field("choice", "Choice")
            }
        }
    }
}

@Suite("#schema macro: nested structures")
struct NestedStructureTests {
    @Test("the generated types honor the re-emitted contract")
    func contractFidelity() throws {
        #expect(try Nest.contract.verify(against: Nest.self).get() == [])
    }

    @Test("structs of one name nested by sibling fields hold their own fields")
    func siblingsHoldTheirOwnFields() throws {
        let request = Nest.PutRequest(
            a: .init(b: .init(a: .init(x: 1))),
            c: .init(b: .init(y: "two"))
        )
        let response = Nest.PutResponse(
            holder: Nest.Holder(a: .init(b: .init(x: 3)), c: .init(b: .init(y: "four"))),
            choice: .right(c: .init(b: .init(y: "five")))
        )
        let requestJSON = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(Nest.PutRequest.self, from: requestJSON) == request)
        let responseJSON = try JSONEncoder().encode(response)
        #expect(try JSONDecoder().decode(Nest.PutResponse.self, from: responseJSON) == response)
    }
}

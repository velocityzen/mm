import Foundation
import Testing

@testable import MMSchema

/// A `#schemaTypes` expansion: shared types belonging to no method namespace.
enum CommonTypes: TypeNamespace {
    #schemaTypes("common") {
        Enum("Priority", description: "How urgent") {
            Case("low")
            Case("high")
        }
        Type("Stamp") {
            Field("author", .string)
            Field("priority", "Priority")
        }
    }
}

/// A hand-written shared-types container: the cross-schema reference target
/// for a `#schema` block **in the same module**. (Macro-generated members of
/// another container cannot be referenced from inside a macro argument in the
/// same module — the compiler does not expand one macro's arbitrary names
/// while type-checking another's arguments. Across modules, or with
/// hand-written types like these, the reference works.)
enum HandTypes: TypeNamespace {
    struct Stamp: Codable, Hashable, Sendable, SchemaDescribable {
        var author: String
        var priority: CommonTypes.Priority

        init(author: String, priority: CommonTypes.Priority) {
            self.author = author
            self.priority = priority
        }

        enum CodingKeys: Int, CodingKey {
            case author = 0
            case priority = 1
        }

        static var schema: TypeSchema { .reference("hand.Stamp") }
    }

    static var types: [TypeDefinition] {
        [
            TypeDefinition(
                name: "hand.Stamp",
                schema: .structure(fields: [
                    .init(key: 0, name: "author", type: .string),
                    .init(key: 1, name: "priority", type: .reference("common.Priority")),
                ])
            )
        ]
    }

    static var probedTypes: [String: Result<TypeSchema, SchemaError>] {
        ["hand.Stamp": TypeSchema.probed(Stamp.self)]
    }
}

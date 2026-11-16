import Testing

@testable import MMSchema

/// The runtime DSL's schema-evolution forms: wire defaults, reserved keys and
/// names, and deprecations. The `#schema` side is in MMWireTests'
/// WireDefaultTests and the macro diagnostics.
@Suite("Schema evolution in the runtime DSL")
struct SchemaEvolutionDeclarationTests {
    @Test(
        "a default on a field that is not optional is a wire default; on an optional, a CLI default"
    )
    func wireDefaults() {
        #expect(
            Fields {
                Field("limit", .int, default: 50)
                Field("ratio", .double, default: 1)
                Field("page", .optional(.int), default: 1)
            }
                == .structure(fields: [
                    .init(key: 0, name: "limit", type: .optional(.int), defaultValue: .integer(50)),
                    .init(
                        key: 1,
                        name: "ratio",
                        type: .optional(.double),
                        defaultValue: .floating(1)
                    ),
                    .init(key: 2, name: "page", type: .optional(.int)),
                ])
        )
    }

    @Test("a named type's default is fitted to its declaration when the block assembles")
    func namedTypeDefaults() throws {
        let declaration = Schema("shop") {
            Enum("Size") {
                Case("small")
                Case("large")
            }
            Alias("Ratio", .double, constraints: .range(0...1))
            Call("order") {
                Access { .write }
                Request {
                    Field("size", "Size", default: "large")
                    Field("ratio", "Ratio", default: 1)
                }
            }
        }
        let request = try #require(declaration.signatures.first).request
        #expect(
            request
                == .structure(fields: [
                    .init(
                        key: 0,
                        name: "size",
                        type: .optional(.reference("shop.Size")),
                        defaultValue: .string("large")
                    ),
                    .init(
                        key: 1,
                        name: "ratio",
                        type: .optional(.reference("shop.Ratio")),
                        defaultValue: .floating(1)
                    ),
                ])
        )
    }

    @Test("Reserved holds keys and names back, and auto keys skip the reserved keys")
    func reserved() {
        #expect(
            Fields {
                Field("text", .string)
                Reserved(1, "author")
                Field("at", .timestamp)
                Field(3, "tag", .string)
                Field("note", .optional(.string))
            }
                == .structure(fields: [
                    .init(key: 0, name: "text", type: .string),
                    .init(key: 2, name: "at", type: .timestamp),
                    .init(key: 3, name: "tag", type: .string),
                    .init(key: 4, name: "note", type: .optional(.string)),
                ])
        )
        #expect(
            fieldKeys(
                for: [(nil, "a"), (1, "b")],
                reservedKeys: [1],
                reservedNames: []
            ) == .failure(.reservedKey(1, field: "b"))
        )
        #expect(
            fieldKeys(
                for: [(nil, "a"), (nil, "old")],
                reservedKeys: [],
                reservedNames: ["old"]
            ) == .failure(.reservedName("old"))
        )
    }

    @Test("deprecations reach the served fields, cases, types and methods")
    func deprecations() throws {
        let declaration = Schema("shop") {
            Enum("Size", deprecated: "use Fit") {
                Case("small")
                Case("huge", deprecated: "use large")
            }
            Union("Pick") {
                Case("first")
                Case("any", deprecated: "")
            }
            Alias("Code", .string, deprecated: "use Slug")
            Type("Line", deprecated: "use Item") {
                Field("name", .string, deprecated: "use title")
            }
            Call("order", deprecated: "use buy") {
                Access { .write }
            }
        }
        let types = Dictionary(uniqueKeysWithValues: declaration.types.map { ($0.name, $0) })
        #expect(types["shop.Size"]?.deprecation == "use Fit")
        #expect(
            types["shop.Size"]?.schema
                == .enumeration(cases: [
                    .init(name: "small"), .init(name: "huge", deprecation: "use large"),
                ])
        )
        #expect(
            types["shop.Pick"]?.schema
                == .union(cases: [.init(name: "first"), .init(name: "any", deprecation: "")])
        )
        #expect(types["shop.Code"]?.deprecation == "use Slug")
        #expect(types["shop.Line"]?.deprecation == "use Item")
        #expect(
            types["shop.Line"]?.schema
                == .structure(fields: [
                    .init(key: 0, name: "name", type: .string, deprecation: "use title")
                ])
        )
        #expect(try #require(declaration.signatures.first).deprecation == "use buy")
    }

    @Test("a default must be a value of the field's kind that keeps its constraints")
    func fitting() {
        let percent = TypeSchema.Constraints(minimum: .integer(0), maximum: .integer(100))
        #expect(
            TypeSchema.Default.integer(50).fitted(to: .int, constraints: percent)
                == .success(.integer(50))
        )
        #expect(
            TypeSchema.Default.integer(150).fitted(to: .int, constraints: percent)
                == .failure(
                    .constraints(.integer(150), problem: "is 150, more than the maximum 100")
                )
        )
        #expect(
            TypeSchema.Default.integer(-1).fitted(to: .uint, constraints: nil)
                == .failure(.mismatch(.integer(-1), kind: "uint"))
        )
        #expect(
            TypeSchema.Default.integer(2).fitted(to: .float, constraints: nil)
                == .success(.floating(2))
        )
        #expect(
            TypeSchema.Default.floating(1e39).fitted(to: .float, constraints: nil)
                == .failure(.mismatch(.floating(1e39), kind: "float"))
        )
        #expect(
            TypeSchema.Default.string("x").fitted(to: .bytes, constraints: nil)
                == .failure(.unsupported(kind: "bytes"))
        )
    }
}

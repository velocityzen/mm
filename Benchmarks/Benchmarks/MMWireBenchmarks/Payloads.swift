import MMSchema
import MMWire
import NIOCore

/// The payload shapes the wire benchmarks encode and decode, declared the way
/// an application declares its contract, so the coders run on generated types.
enum Inventory: MethodNamespace {
    #schema("inventory") {
        Enum("Condition") {
            Case("new")
            Case("used")
        }
        Type("Item") {
            Field("sku", .string)
            Field("name", .string)
            Field("quantity", .int)
            Field("price", .double)
            Field("condition", "Condition")
            Field("tags", .array(.string))
            Field("note", .optional(.string))
        }
        // One integer field: the smallest payload, close to the coders' fixed cost.
        Call("count") {
            Access { .read }
            Request { Field("value", .int) }
            Response { Field("value", .int) }
        }
        // One record of mixed field types: a typical request.
        Call("put") {
            Access { .write }
            Request { Field("item", "Item") }
            Response { Field("count", .int) }
        }
        // A hundred records: a typical listing response.
        Call("list") {
            Access { .read }
            Response { Field("items", .array(.reference("Item"))) }
        }
    }
}

extension Inventory.Item {
    static func sample(_ index: Int) -> Inventory.Item {
        Inventory.Item(
            sku: "SKU-\(100_000 + index)",
            name: "Stainless steel water bottle",
            quantity: index,
            price: 24.5,
            condition: index.isMultiple(of: 3) ? .used : .new,
            tags: ["kitchen", "outdoor", "gift"],
            note: index.isMultiple(of: 2) ? "Restocked on Friday" : nil
        )
    }
}

/// Encodes a fixture. The fixtures are known-good, so a failure here is a
/// broken benchmark, not a measurement.
func encoded<Value: Encodable>(_ value: Value) -> ByteBuffer {
    try! MMPackEncoder().encode(value).get()
}

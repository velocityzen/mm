import Foundation
import Testing

@testable import MMSchema

/// A real `#schema` expansion, compiled into this test target: every shape the
/// macro supports in one namespace — unary with rich fields, server stream,
/// client stream, and bidirectional, with both convention and override type names.
private enum Box: MethodNamespace {
    #schema("box") {
        Call("put") {
            Access { .write }
            Request {
                Field("line", .string)
                Field(4, "note", .optional(.string))
                Field("tags", .array(.string))
                Field("owner") {
                    Field("uid", .uint)
                    Field("gid", .uint)
                }
            }
            Response {
                Field("count", .int)
            }
        }
        Call("follow") {
            Access { .read }
            ResponseStream("BoxEvent") {
                Field("line", .string)
            }
            Response("FollowSummary") {
                Field("delivered", .int)
            }
        }
        Call("import") {
            Access { .write }
            RequestStream {
                Field("line", .string)
            }
            Response {
                Field("imported", .int)
            }
        }
        Call("pipe") {
            Access { .write }
            RequestStream { Field("chunk", .string) }
            ResponseStream { Field("echo", .string) }
        }
    }
}

@Suite("#schema macro: generated namespace behaves")
struct SchemaMacroTests {
    @Test("the generated types honor the re-emitted contract exactly (macro fidelity)")
    func contractFidelity() throws {
        // THE load-bearing assertion: the macro generated the structs AND
        // re-emitted the runtime declaration from one source. If codegen ever
        // diverges from DSL semantics (key assignment, entity injection,
        // type mapping), the probe of the generated types disagrees with the
        // declaration and this fails.
        let breaks = try Box.contract.verify(against: Box.self).get()
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
    }

    @Test("descriptors carry the right shapes and wire names")
    func descriptors() throws {
        let put = try Box.put.signature().get()
        #expect(put.name == "box.put")
        #expect(put.access == .write)
        #expect(put.requestStream == nil)
        #expect(put.responseStream == nil)
        let follow = try Box.follow.signature().get()
        #expect(follow.name == "box.follow")
        #expect(
            follow.responseStream
                == .structure(fields: [
                    .init(key: 0, name: "line", type: .string)
                ]))
        let imported = try Box.`import`.signature().get()
        #expect(imported.requestStream != nil)
        #expect(imported.responseStream == nil)
        let pipe = try Box.pipe.signature().get()
        #expect(pipe.requestStream != nil)
        #expect(pipe.responseStream != nil)
    }

    @Test("generated request: fields key from 0, pinned key honored, auto keys skip pins")
    func requestShape() throws {
        let signature = try Box.put.signature().get()
        #expect(
            signature.request
                == .structure(fields: [
                    .init(key: 0, name: "line", type: .string),
                    .init(key: 4, name: "note", type: .optional(.string)),
                    .init(key: 1, name: "tags", type: .array(.string)),
                    .init(
                        key: 2, name: "owner",
                        type: .structure(fields: [
                            .init(key: 0, name: "uid", type: .uint),
                            .init(key: 1, name: "gid", type: .uint),
                        ])),
                ]))
    }

    @Test("generated structs are ordinary Codable values")
    func structUsability() {
        let request = Box.PutRequest(
            line: "x", note: nil, tags: ["t"], owner: .init(uid: 1, gid: 2))
        #expect(request.owner.uid == 1)
        let summary = Box.FollowSummary(delivered: 3)
        #expect(summary.delivered == 3)
        let event = Box.BoxEvent(line: "y")
        #expect(event.line == "y")
        // Convention names for the parts without overrides:
        let item = Box.ImportRequestItem(line: "z")
        #expect(item.line == "z")
        _ = Box.PipeRequestItem(chunk: "c")
        _ = Box.PipeResponseItem(echo: "e")
    }

    @Test("all lists every generated descriptor in declaration order")
    func allList() {
        #expect(Box.all.map(\.name) == ["box.put", "box.follow", "box.import", "box.pipe"])
    }

    @Test("the contract fingerprints like any hand-written declaration")
    func fingerprint() throws {
        let probed = try Box.all.map { try $0.signature().get() }
        #expect(Box.contract.fingerprint() == SchemaFingerprint.compute(probed))
    }
}

// MARK: - Named types, descriptions, and cross-schema references

/// A `#schema` expansion exercising the types amendment: a named enum and
/// struct, references, and descriptions on every level.
private enum Shop: MethodNamespace {
    #schema("shop") {
        Enum("Size", description: "T-shirt sizing") {
            Case("small")
            Case("large", description: "The big one")
        }
        Type("ItemMeta", description: "Catalog info") {
            Field("label", .string, description: "Display label")
            Field("size", "Size")
        }
        Call("stock", description: "Restocks an item") {
            Access { .write }
            Request(description: "What to stock") {
                Field("meta", "ItemMeta")
                Field("count", .int, description: "How many arrived")
            }
            Response(description: "New totals") {
                Field("total", .int)
            }
        }
        // The response IS the named type: no struct is generated for it, the
        // descriptor's Response is ItemMeta itself.
        Call("lookup", description: "Returns the catalog info for an item") {
            Access { .read }
            Response(.reference("ItemMeta"))
        }
        // Stream elements as a named enum, terminal as a named struct.
        Call("sizes") {
            Access { .read }
            ResponseStream(.reference("Size"))
            Response(.reference("ItemMeta"))
        }
        // Any named type can BE the request — the entity rides the envelope.
        Type("StockPayload", description: "Shared restock request") {
            Field("meta", "ItemMeta")
            Field("count", .int)
        }
        Call("restock") {
            Access { .write }
            Request(.reference("StockPayload"))
            Response(.reference("ItemMeta"))
        }
    }
}

/// A `#schema` block referencing another container's Swift type — the
/// cross-schema form. The target is hand-written (see SharedTypesFixture):
/// same-module references to macro-GENERATED types inside a macro argument
/// are a compiler limitation; across modules both work.
private enum Desk: MethodNamespace {
    #schema("desk") {
        Call("file") {
            Access { .write }
            Request {
                Field("stamp", HandTypes.Stamp.self)
            }
            Response {
                Field("ok", .bool)
            }
        }
    }
}

@Suite("#schema macro: named types and descriptions")
struct SchemaMacroTypesTests {
    @Test("the typed contract verifies clean (macro fidelity incl. types)")
    func contractFidelity() throws {
        let breaks = try Shop.contract.verify(against: Shop.self).get()
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
    }

    @Test("the generated enum decodes case names and falls back to unknown")
    func enumBehavior() throws {
        #expect(Shop.Size(rawValue: "small") == .small)
        let decoded = try JSONDecoder().decode(Shop.Size.self, from: Data("\"large\"".utf8))
        #expect(decoded == .large)
        let unrecognized = try JSONDecoder().decode(Shop.Size.self, from: Data("\"xxl\"".utf8))
        #expect(unrecognized == .unknown)
        let encoded = try JSONEncoder().encode(Shop.Size.small)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"small\"")
    }

    @Test("generated named types self-describe as their qualified reference")
    func namedTypeDescriptions() {
        #expect(TypeSchema.of(Shop.Size.self) == .success(.reference("shop.Size")))
        #expect(TypeSchema.of(Shop.ItemMeta.self) == .success(.reference("shop.ItemMeta")))
        #expect(
            TypeSchema.probed(Shop.ItemMeta.self)
                == .success(
                    .structure(fields: [
                        .init(key: 0, name: "label", type: .string),
                        .init(key: 1, name: "size", type: .reference("shop.Size")),
                    ]))
        )
    }

    @Test("the namespace serves its type table and behavior probes")
    func typeTable() {
        #expect(Shop.types.map(\.name) == ["shop.Size", "shop.ItemMeta", "shop.StockPayload"])
        #expect(Shop.types[0].description == "T-shirt sizing")
        #expect(
            Shop.types[0].schema
                == .enumeration(cases: [
                    .init(name: "small"),
                    .init(name: "large", description: "The big one"),
                ])
        )
        #expect(Set(Shop.probedTypes.keys) == ["shop.Size", "shop.ItemMeta", "shop.StockPayload"])
    }

    @Test("descriptions reach the served signature at every level")
    func servedDescriptions() throws {
        let signature = try Shop.stock.signature().get()
        #expect(signature.description == "Restocks an item")
        #expect(signature.requestDescription == "What to stock")
        #expect(signature.responseDescription == "New totals")
        guard case .structure(let fields) = signature.request else {
            Issue.record("request is not a structure")
            return
        }
        #expect(fields[0].type == .reference("shop.ItemMeta"))
        #expect(fields[1].description == "How many arrived")
    }

    @Test("the typed contract fingerprints signatures plus the type table")
    func typedFingerprint() throws {
        let served = try Shop.all.map { try $0.signature().get() }
        #expect(
            Shop.contract.fingerprint()
                == SchemaFingerprint.compute(served, types: Shop.types)
        )
    }

    @Test("#schemaTypes: generated container verifies against its contract")
    func typesOnlyContainer() {
        #expect(CommonTypes.contract.namespace == "common")
        let breaks = CommonTypes.contract.verify(against: CommonTypes.self)
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
        #expect(CommonTypes.types.map(\.name) == ["common.Priority", "common.Stamp"])
        #expect(TypeSchema.of(CommonTypes.Stamp.self) == .success(.reference("common.Stamp")))
    }

    @Test("a part payload reference makes the named type the payload type")
    func partPayloadReferences() throws {
        // The contract carries the reference in the slot itself...
        let lookup = try Shop.lookup.signature().get()
        #expect(lookup.response == .reference("shop.ItemMeta"))
        let sizes = try Shop.sizes.signature().get()
        #expect(sizes.responseStream == .reference("shop.Size"))
        #expect(sizes.response == .reference("shop.ItemMeta"))
        // ...and the descriptor's generic IS the named Swift type — no
        // LookupResponse/SizesResponseItem structs exist.
        let meta: Shop.ItemMeta = Shop.ItemMeta(label: "shirt", size: .large)
        let _: MMSchema.Method<Shop.LookupRequest, Shop.ItemMeta> = Shop.lookup
        let _: ServerStreamMethod<Shop.SizesRequest, Shop.Size, Shop.ItemMeta> = Shop.sizes
        #expect(meta.size == .large)
    }

    @Test("a named payload IS the request type")
    func namedRequestPayload() throws {
        let signature = try Shop.restock.signature().get()
        #expect(signature.request == .reference("shop.StockPayload"))
        let definition = Shop.types.first { $0.name == "shop.StockPayload" }
        guard case .structure(let fields)? = definition?.schema else {
            Issue.record("shop.StockPayload definition is not a structure")
            return
        }
        #expect(fields[0].type == .reference("shop.ItemMeta"))
        // The descriptor's Request IS the named type itself.
        let _: MMSchema.Method<Shop.StockPayload, Shop.ItemMeta> = Shop.restock
        let payload = Shop.StockPayload(
            meta: Shop.ItemMeta(label: "shirt", size: .small),
            count: 3
        )
        #expect(payload.count == 3)
    }

    @Test("cross-schema references resolve through the Swift type")
    func crossSchemaReference() throws {
        let breaks = try Desk.contract.verify(against: Desk.self).get()
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
        let signature = try Desk.file.signature().get()
        guard case .structure(let fields) = signature.request else {
            Issue.record("request is not a structure")
            return
        }
        #expect(fields[0].type == .reference("hand.Stamp"))
        // The generated property is the real Swift type.
        let request = Desk.FileRequest(
            stamp: HandTypes.Stamp(author: "ada", priority: .high)
        )
        #expect(request.stamp.priority == .high)
    }
}

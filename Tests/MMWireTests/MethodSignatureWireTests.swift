import MMSchema
import MMWire
import NIOCore
import Testing

/// Pins the grouped key layout of `MethodSignature` at the byte level: the
/// method itself in the single digits (0 name, 1 access, 2 description), the
/// request direction in the 10s (10 request, 11 requestDescription,
/// 12 requestStream, 13 requestStreamDescription), the response direction in
/// the 20s (20 response, 21 responseDescription, 22 responseStream,
/// 23 responseStreamDescription) — every slot immediately followed by its doc
/// slot. Optional slots omit their key entirely; unknown keys are skipped —
/// the standard wire-evolution contract.
private struct CoreOnlySignature: Codable, Equatable {
    var name: String
    var access: AccessMode
    var request: TypeSchema
    var response: TypeSchema

    enum CodingKeys: Int, CodingKey {
        case name = 0
        case access = 1
        case request = 10
        case response = 20
    }
}

private let emptyRequest: TypeSchema = .structure(fields: [])

private let summaryResponse: TypeSchema = .structure(fields: [
    .init(key: 0, name: "delivered", type: .uint)
])

private let lineElement: TypeSchema = .structure(fields: [
    .init(key: 0, name: "line", type: .string)
])

private let countElement: TypeSchema = .structure(fields: [
    .init(key: 0, name: "count", type: .int)
])

/// Reads the encoded map's integer keys in wire order, structurally skipping
/// every value — the layout pin that stays honest no matter how `TypeSchema`
/// itself encodes.
private func mapKeys(of bytes: ByteBuffer) throws -> [Int64] {
    var buffer = bytes
    let count = try #require(buffer.readMessagePackMapHeader().mpSuccess)
    var keys: [Int64] = []
    for _ in 0..<count {
        keys.append(try #require(buffer.readMessagePackInt().mpSuccess))
        _ = try #require(buffer.skipMessagePackValue().mpSuccess)
    }
    #expect(buffer.readableBytes == 0)
    return keys
}

@Suite("MethodSignature wire layout (MessagePack)")
struct MethodSignatureWireTests {
    @Test("a fully populated signature round trips through the wire coder")
    func fullRoundTrip() throws {
        let signature = MethodSignature(
            name: "feed.sync",
            access: [.read, .write],
            request: emptyRequest,
            response: summaryResponse,
            requestStream: lineElement,
            responseStream: countElement,
            description: "keeps a feed in sync",
            requestDescription: "opening request",
            responseDescription: "terminal summary",
            requestStreamDescription: "lines going up",
            responseStreamDescription: "counts coming down"
        )
        let bytes = try #require(MMPackEncoder().encode(signature).mpSuccess)
        #expect(MMPackDecoder().decode(MethodSignature.self, from: bytes) == .success(signature))
    }

    @Test("a doc-less unary signature encodes exactly keys 0, 1, 10, 20 in order")
    func unaryKeyLayout() throws {
        let unary = MethodSignature(
            name: "feed.clear",
            access: .write,
            request: emptyRequest,
            response: summaryResponse
        )
        let bytes = try #require(MMPackEncoder().encode(unary).mpSuccess)
        #expect(try mapKeys(of: bytes) == [0, 1, 10, 20])
    }

    @Test("a fully populated signature encodes the grouped key blocks in order")
    func groupedKeyLayout() throws {
        let signature = MethodSignature(
            name: "feed.sync",
            access: [.read, .write],
            request: emptyRequest,
            response: summaryResponse,
            requestStream: lineElement,
            responseStream: countElement,
            description: "keeps a feed in sync",
            requestDescription: "opening request",
            responseDescription: "terminal summary",
            requestStreamDescription: "lines going up",
            responseStreamDescription: "counts coming down"
        )
        let bytes = try #require(MMPackEncoder().encode(signature).mpSuccess)
        #expect(try mapKeys(of: bytes) == [0, 1, 2, 10, 11, 12, 13, 20, 21, 22, 23])
    }

    @Test("core-only bytes decode as a MethodSignature with every optional slot nil")
    func coreBytesDecodeWithNilOptionals() throws {
        let core = CoreOnlySignature(
            name: "feed.clear",
            access: .write,
            request: emptyRequest,
            response: summaryResponse
        )
        let bytes = try #require(MMPackEncoder().encode(core).mpSuccess)
        #expect(
            MMPackDecoder().decode(MethodSignature.self, from: bytes)
                == .success(
                    MethodSignature(
                        name: "feed.clear",
                        access: .write,
                        request: emptyRequest,
                        response: summaryResponse
                    )
                )
        )
    }

    @Test("a reader that only knows the core keys skips the stream and doc slots")
    func fullBytesDecodeOnCoreOnlyReader() throws {
        let streaming = MethodSignature(
            name: "feed.sync",
            access: [.read, .write],
            request: emptyRequest,
            response: summaryResponse,
            requestStream: lineElement,
            responseStream: countElement,
            description: "keeps a feed in sync"
        )
        let bytes = try #require(MMPackEncoder().encode(streaming).mpSuccess)
        #expect(
            MMPackDecoder().decode(CoreOnlySignature.self, from: bytes)
                == .success(
                    CoreOnlySignature(
                        name: "feed.sync",
                        access: [.read, .write],
                        request: emptyRequest,
                        response: summaryResponse
                    )
                )
        )
    }
}

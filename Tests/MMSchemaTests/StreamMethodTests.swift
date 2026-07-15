import Testing

@testable import MMSchema

// MARK: - Codable fixtures for the three stream descriptor shapes

private struct WatchRequest: Codable, Hashable, Sendable {
    var entity: EntityName

    enum CodingKeys: Int, CodingKey {
        case entity = 0
    }
}

private struct ChangeEvent: Codable, Hashable, Sendable {
    var line: String
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case line = 0
        case count = 1
    }
}

private struct WatchSummary: Codable, Hashable, Sendable {
    var delivered: UInt64

    enum CodingKeys: Int, CodingKey {
        case delivered = 0
    }
}

private struct IngestLine: Codable, Hashable, Sendable {
    var line: String

    enum CodingKeys: Int, CodingKey {
        case line = 0
    }
}

private struct IngestSummary: Codable, Hashable, Sendable {
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case count = 0
    }
}

private enum Feed: MethodNamespace {
    static let list = Method<WatchRequest, IngestSummary>(name: "feed.list", access: .read)
    static let watch = ServerStreamMethod<WatchRequest, ChangeEvent, WatchSummary>(
        name: "feed.watch", access: .read)
    static let ingest = ClientStreamMethod<WatchRequest, IngestLine, IngestSummary>(
        name: "feed.ingest", access: .write)
    static let sync = BidirectionalStreamMethod<
        WatchRequest, IngestLine, ChangeEvent, WatchSummary
    >(
        name: "feed.sync", access: [.read, .write])

    @SchemaBuilder static var all: [AnyMethod] {
        list
        watch
        ingest
        sync
    }
}

@Suite("Stream method descriptors")
struct StreamMethodTests {
    static let entityOnlyRequest: TypeSchema = .structure(fields: [
        .init(key: 0, name: "entity", type: .string)
    ])

    static let changeEventSchema: TypeSchema = .structure(fields: [
        .init(key: 0, name: "line", type: .string),
        .init(key: 1, name: "count", type: .int),
    ])

    static let watchSummarySchema: TypeSchema = .structure(fields: [
        .init(key: 0, name: "delivered", type: .uint)
    ])

    static let ingestLineSchema: TypeSchema = .structure(fields: [
        .init(key: 0, name: "line", type: .string)
    ])

    static let ingestSummarySchema: TypeSchema = .structure(fields: [
        .init(key: 0, name: "count", type: .int)
    ])

    @Test("ServerStreamMethod signature fills the response-stream slot only")
    func serverStreamSignature() {
        #expect(
            Feed.watch.signature()
                == .success(
                    MethodSignature(
                        name: "feed.watch",
                        access: .read,
                        request: Self.entityOnlyRequest,
                        response: Self.watchSummarySchema,
                        requestStream: nil,
                        responseStream: Self.changeEventSchema
                    )
                )
        )
    }

    @Test("ClientStreamMethod signature fills the request-stream slot only")
    func clientStreamSignature() {
        #expect(
            Feed.ingest.signature()
                == .success(
                    MethodSignature(
                        name: "feed.ingest",
                        access: .write,
                        request: Self.entityOnlyRequest,
                        response: Self.ingestSummarySchema,
                        requestStream: Self.ingestLineSchema,
                        responseStream: nil
                    )
                )
        )
    }

    @Test("BidirectionalStreamMethod signature fills both stream slots")
    func bidiStreamSignature() {
        #expect(
            Feed.sync.signature()
                == .success(
                    MethodSignature(
                        name: "feed.sync",
                        access: [.read, .write],
                        request: Self.entityOnlyRequest,
                        response: Self.watchSummarySchema,
                        requestStream: Self.ingestLineSchema,
                        responseStream: Self.changeEventSchema
                    )
                )
        )
    }

    @Test("@SchemaBuilder lists a mixed unary + stream namespace in order")
    func mixedNamespace() throws {
        #expect(Feed.all.map(\.name) == ["feed.list", "feed.watch", "feed.ingest", "feed.sync"])
        #expect(Feed.all.map(\.access) == [.read, .read, .write, [.read, .write]])
        let signatures = try Feed.all.map { try $0.signature().get() }
        #expect(
            signatures.map(\.requestStream) == [
                nil, nil, Self.ingestLineSchema, Self.ingestLineSchema,
            ])
        #expect(
            signatures.map(\.responseStream) == [
                nil, Self.changeEventSchema, nil, Self.changeEventSchema,
            ])
    }

    @Test("AnyMethod erasure round-trips every stream descriptor's signature")
    func anyMethodErasure() {
        let watch = AnyMethod(Feed.watch)
        #expect(watch.name == "feed.watch")
        #expect(watch.access == .read)
        #expect(watch.signature() == Feed.watch.signature())

        let ingest = AnyMethod(Feed.ingest)
        #expect(ingest.name == "feed.ingest")
        #expect(ingest.access == .write)
        #expect(ingest.signature() == Feed.ingest.signature())

        let sync = AnyMethod(Feed.sync)
        #expect(sync.name == "feed.sync")
        #expect(sync.access == [.read, .write])
        #expect(sync.signature() == Feed.sync.signature())
    }
}

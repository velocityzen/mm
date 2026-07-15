import Testing

@testable import MMSchema

// MARK: - Codable fixtures the streaming contract is verified against

/// An empty request payload — the target rides the envelope; self-describes
/// because a property-less decoder is unprobeable.
private struct FeedRequest: Codable, Hashable, Sendable, SchemaDescribable {
    static var schema: TypeSchema { .structure(fields: []) }
}

private struct FeedEvent: Codable, Hashable, Sendable {
    var line: String
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case line = 0
        case count = 1
    }
}

private struct FeedSummary: Codable, Hashable, Sendable {
    var delivered: UInt64

    enum CodingKeys: Int, CodingKey {
        case delivered = 0
    }
}

private struct FeedLine: Codable, Hashable, Sendable {
    var line: String

    enum CodingKeys: Int, CodingKey {
        case line = 0
    }
}

private struct FeedCount: Codable, Hashable, Sendable {
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case count = 0
    }
}

private struct ClearResponse: Codable, Hashable, Sendable {
    var ok: Bool

    enum CodingKeys: Int, CodingKey {
        case ok = 0
    }
}

private enum Feed: MethodNamespace {
    static let watch = ServerStreamMethod<FeedRequest, FeedEvent, FeedSummary>(
        name: "feed.watch", access: .read)
    static let ingest = ClientStreamMethod<FeedRequest, FeedLine, FeedCount>(
        name: "feed.ingest", access: .write)
    static let sync = BidirectionalStreamMethod<FeedRequest, FeedLine, FeedEvent, FeedSummary>(
        name: "feed.sync", access: [.read, .write])
    static let clear = Method<FeedRequest, ClearResponse>(name: "feed.clear", access: .write)

    @SchemaBuilder static var all: [AnyMethod] {
        watch
        ingest
        sync
        clear
    }
}

private let feedContract = Schema("feed") {
    Call("watch") {
        Access { .read }
        ResponseStream {
            Field("line", .string)
            Field("count", .int)
        }
        Response {
            Field("delivered", .uint)
        }
    }
    Call("ingest") {
        Access { .write }
        RequestStream {
            Field("line", .string)
        }
        Response {
            Field("count", .int)
        }
    }
    Call("sync") {
        Access { [.read, .write] }
        RequestStream {
            Field("line", .string)
        }
        ResponseStream {
            Field("line", .string)
            Field("count", .int)
        }
        Response {
            Field("delivered", .uint)
        }
    }
    Call("clear") {
        Access { .write }
        Response {
            Field("ok", .bool)
        }
    }
}

@Suite("SchemaDeclaration: stream parts")
struct StreamDeclarationTests {
    static let emptyRequest: TypeSchema = .structure(fields: [])

    /// All 16 presence combinations of the four independent parts.
    static let combinations:
        [(request: Bool, requestStream: Bool, response: Bool, responseStream: Bool)] =
            (0..<16).map { bits in
                (bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0)
            }

    private static func combined(
        request: Bool, requestStream: Bool, response: Bool, responseStream: Bool
    ) -> MethodSignature {
        let contract = Schema("combo") {
            Call("m") {
                Access { .read }
                if request {
                    Request { Field("arg", .string) }
                }
                if requestStream {
                    RequestStream { Field("chunk", .bytes) }
                }
                if response {
                    Response { Field("ok", .bool) }
                }
                if responseStream {
                    ResponseStream { Field("item", .uint) }
                }
            }
        }
        return contract.signatures[0]
    }

    @Test(
        "every request/requestStream x response/responseStream combination is valid",
        arguments: combinations)
    func allCombinations(
        _ combo: (request: Bool, requestStream: Bool, response: Bool, responseStream: Bool)
    ) {
        let signature = Self.combined(
            request: combo.request,
            requestStream: combo.requestStream,
            response: combo.response,
            responseStream: combo.responseStream
        )
        #expect(signature.name == "combo.m")
        #expect(signature.access == .read)
        let expectedRequest: TypeSchema =
            combo.request
            ? .structure(fields: [
                .init(key: 0, name: "arg", type: .string)
            ])
            : Self.emptyRequest
        #expect(signature.request == expectedRequest)
        #expect(
            signature.requestStream
                == (combo.requestStream
                    ? .structure(fields: [.init(key: 0, name: "chunk", type: .bytes)]) : nil)
        )
        #expect(
            signature.response
                == (combo.response
                    ? .structure(fields: [.init(key: 0, name: "ok", type: .bool)])
                    : .structure(fields: []))
        )
        #expect(
            signature.responseStream
                == (combo.responseStream
                    ? .structure(fields: [.init(key: 0, name: "item", type: .uint)]) : nil)
        )
    }

    @Test("stream elements get no injected entity — fields are keyed from 0")
    func noEntityInjection() {
        let watch = feedContract.signatures[0]
        #expect(
            watch.responseStream
                == .structure(fields: [
                    .init(key: 0, name: "line", type: .string),
                    .init(key: 1, name: "count", type: .int),
                ])
        )
        // Key 0 is not reserved in stream elements: pinning it is legal.
        let pinned = Schema("feed") {
            Call("watch") {
                Access { .read }
                ResponseStream {
                    Field(0, "line", .string)
                }
            }
        }
        #expect(
            pinned.signatures[0].responseStream
                == .structure(fields: [.init(key: 0, name: "line", type: .string)])
        )
    }

    @Test("explicit StreamOptions equals the default, and the payload form matches Fields")
    func streamOptions() {
        #expect(StreamOptions() == StreamOptions())
        let defaulted = Schema("feed") {
            Call("ingest") {
                Access { .write }
                RequestStream { Field("line", .string) }
            }
        }
        let explicit = Schema("feed") {
            Call("ingest") {
                Access { .write }
                RequestStream(StreamOptions()) { Field("line", .string) }
            }
        }
        let payload = Schema("feed") {
            Call("ingest") {
                Access { .write }
                RequestStream(payload: Fields { Field("line", .string) })
            }
        }
        #expect(defaulted == explicit)
        #expect(defaulted == payload)
    }

    @Test("a bare payload stream declares a non-structure element")
    func barePayloadStream() {
        let ticks = Schema("feed") {
            Call("ticks") {
                Access { .read }
                ResponseStream(payload: .uint)
            }
        }
        #expect(ticks.signatures[0].responseStream == .uint)
        #expect(ticks.signatures[0].requestStream == nil)
    }

    @Test("duplicate RequestStream is programmer error")
    func duplicateRequestStream() async throws {
        await #expect(processExitsWith: .failure) {
            _ = Schema("feed") {
                Call("ingest") {
                    Access { .write }
                    RequestStream { Field("line", .string) }
                    RequestStream(payload: .bytes)
                }
            }
        }
    }

    @Test("duplicate ResponseStream is programmer error")
    func duplicateResponseStream() async throws {
        await #expect(processExitsWith: .failure) {
            _ = Schema("feed") {
                Call("watch") {
                    Access { .read }
                    ResponseStream { Field("line", .string) }
                    ResponseStream(payload: .uint)
                }
            }
        }
    }

    @Test("the streaming contract matches the stream descriptors exactly")
    func contractHolds() throws {
        #expect(try feedContract.verify(against: Feed.self).get().isEmpty)
    }

    @Test("the declared signatures equal the probed signatures, so fingerprints agree")
    func fingerprintAgreement() throws {
        let probed = try Feed.all.map { try $0.signature().get() }
        #expect(
            feedContract.signatures.sorted(by: { $0.name < $1.name })
                == probed.sorted(by: { $0.name < $1.name })
        )
        #expect(feedContract.fingerprint() == SchemaFingerprint.compute(probed))
    }

    @Test("verify reports a declared stream the implementation lacks")
    func declaredStreamMissing() throws {
        let skewed = Schema("feed") {
            Call("watch") {
                Access { .read }
                ResponseStream {
                    Field("line", .string)
                    Field("count", .int)
                }
                Response { Field("delivered", .uint) }
            }
            Call("ingest") {
                Access { .write }
                RequestStream { Field("line", .string) }
                Response { Field("count", .int) }
            }
            Call("sync") {
                Access { [.read, .write] }
                RequestStream { Field("line", .string) }
                ResponseStream {
                    Field("line", .string)
                    Field("count", .int)
                }
                Response { Field("delivered", .uint) }
            }
            Call("clear") {
                Access { .write }
                RequestStream { Field("line", .string) }  // implementation is unary
                Response { Field("ok", .bool) }
            }
        }
        let breaks = try skewed.verify(against: Feed.self).get()
        #expect(breaks == ["feed.clear: request stream declared but not implemented"])
    }

    @Test("verify reports an implemented stream the contract lacks")
    func implementedStreamUndeclared() throws {
        let skewed = Schema("feed") {
            Call("watch") {
                Access { .read }
                Response { Field("delivered", .uint) }  // no ResponseStream declared
            }
            Call("ingest") {
                Access { .write }
                RequestStream { Field("line", .string) }
                Response { Field("count", .int) }
            }
            Call("sync") {
                Access { [.read, .write] }
                RequestStream { Field("line", .string) }
                ResponseStream {
                    Field("line", .string)
                    Field("count", .int)
                }
                Response { Field("delivered", .uint) }
            }
            Call("clear") {
                Access { .write }
                Response { Field("ok", .bool) }
            }
        }
        let breaks = try skewed.verify(against: Feed.self).get()
        #expect(breaks == ["feed.watch: response stream implemented but not in the contract"])
    }

    @Test("verify reports a diverged stream element shape")
    func streamElementDivergence() throws {
        let skewed = Schema("feed") {
            Call("watch") {
                Access { .read }
                ResponseStream {
                    Field("line", .string)
                    Field("count", .int)
                }
                Response { Field("delivered", .uint) }
            }
            Call("ingest") {
                Access { .write }
                RequestStream { Field("line", .int) }  // implementation says .string
                Response { Field("count", .int) }
            }
            Call("sync") {
                Access { [.read, .write] }
                RequestStream { Field("line", .string) }
                ResponseStream {
                    Field("line", .string)
                    Field("count", .string)  // implementation says .int
                }
                Response { Field("delivered", .uint) }
            }
            Call("clear") {
                Access { .write }
                Response { Field("ok", .bool) }
            }
        }
        let breaks = try skewed.verify(against: Feed.self).get()
        #expect(
            breaks == [
                "feed.ingest: request stream element shape diverges from the contract",
                "feed.sync: response stream element shape diverges from the contract",
            ]
        )
    }
}

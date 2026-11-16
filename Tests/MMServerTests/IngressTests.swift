import Logging
import MMSchema
import MMServer
import MMTestSupport
import MMWire
import Metrics
import NIOCore
import Testing

@testable import MMServer

/// Calls whose requests and request-stream elements are constrained.
private enum Vault: MethodNamespace {
    #schema("vault") {
        Call("put") {
            Access { .write }
            Request {
                Field("limit", .int, constraints: .range(1...100))
                Field("tags", .array(.string), constraints: .length(...2))
            }
            Response {
                Field("count", .int)
            }
        }
        Call("watch") {
            Access { .read }
            Request {
                Field("from", .int, constraints: .range(0...))
            }
            ResponseStream {
                Field("n", .int)
            }
            Response {
                Field("sent", .int)
            }
        }
        Call("fill") {
            Access { .write }
            RequestStream {
                Field("text", .string, constraints: .nonEmpty)
            }
            Response {
                Field("filled", .int)
            }
        }
    }
}

/// A `vault.put` request whose fields are of any wire kind.
private struct LoosePut<Limit: Codable & Sendable, Tags: Codable & Sendable>: Codable, Sendable {
    var limit: Limit
    var tags: Tags

    enum CodingKeys: Int, CodingKey {
        case limit = 0
        case tags = 1
    }
}

/// A `vault.put` request missing its `limit`.
private struct PutWithoutLimit: Codable, Sendable {
    var tags: [String]

    enum CodingKeys: Int, CodingKey {
        case tags = 1
    }
}

@Suite("Ingress: constraints and the failing field's path")
struct IngressTests {
    let invocations = InvocationCounter()

    private func makeRouter() -> Router {
        let invocations = self.invocations
        return Router(aclProvider: InMemoryACLProvider([entity("solo"): acl(0o666)])) {
            Handle(Vault.put) { request, _ in
                invocations.increment()
                return .success(Vault.PutResponse(count: request.limit))
            }
        }
    }

    private func put(_ params: some Encodable & Sendable) async -> MMEnvelope? {
        await self.makeRouter().dispatch(
            envelope: request(msgid: 7, method: "vault.put", entity: entity("solo"), params),
            context: makeContext()
        )
    }

    private func refused(_ message: String) -> MMEnvelope {
        .response(msgid: 7, error: MMError(code: 3, message: message), result: nil)
    }

    @Test("a request that keeps its constraints reaches the handler")
    func accepted() async {
        let reply = await self.put(Vault.PutRequest(limit: 100, tags: ["a", "b"]))
        #expect(errorCode(of: reply) == nil)
        #expect(self.invocations.value == 1)
    }

    @Test("a request that breaks a constraint is refused with its path, before the handler")
    func constraintRefused() async {
        let low = await self.put(Vault.PutRequest(limit: 0, tags: []))
        #expect(low == self.refused("malformed params: limit: is 0, less than the minimum 1"))
        let long = await self.put(Vault.PutRequest(limit: 1, tags: ["a", "b", "c"]))
        #expect(
            long == self.refused("malformed params: tags: has length 3, more than the maximum length 2"))
        #expect(self.invocations.value == 0)
    }

    @Test("a request that does not decode names the first field that does not")
    func undecodableNamed() async {
        let wrongKind = await self.put(LoosePut(limit: "ten", tags: ["a"]))
        #expect(wrongKind == self.refused("malformed params: limit: expected integer, got string"))
        let wrongElement = await self.put(LoosePut(limit: 5, tags: [7]))
        #expect(wrongElement == self.refused("malformed params: tags[0]: expected string, got integer"))
        let missing = await self.put(PutWithoutLimit(tags: []))
        #expect(missing == self.refused("malformed params: limit: missing required field"))
        #expect(self.invocations.value == 0)
    }

    @Test("an open whose request breaks a constraint is refused with its path, no stream")
    func streamOpenRefused() async {
        let funnel = RecordingFunnel()
        let runtime = makeIngressRuntime(funnel: funnel)
        let route = Handle(Vault.watch) { _, _, _ in .success(Vault.WatchResponse(sent: 0)) }
        let params = try! MMPackEncoder().encode(Vault.WatchRequest(from: -1)).get()
        let plan = await runtime.openStream(
            msgid: 5, route: route, params: params, context: makeContext(),
            framesDropped: Counter(label: "mm_test_ingress_frames_dropped_total")
        )
        #expect(plan == nil)
        #expect(
            funnel.terminal(msgid: 5)
                == MMError(code: 3, message: "malformed params: from: is -1, less than the minimum 0"))
    }

    @Test("a request item that breaks a constraint ends the call naming the item and the field")
    func itemRefused() async {
        let funnel = RecordingFunnel()
        let delivered = InvocationCounter()
        let terminal = await fill(
            items: [
                try! MMPackEncoder().encode(Vault.FillRequestItem(text: "a")).get(),
                try! MMPackEncoder().encode(Vault.FillRequestItem(text: "")).get(),
            ],
            funnel: funnel, delivered: delivered)
        #expect(
            terminal
                == MMError(
                    code: 6,
                    message: "stream violation: [1].text: has length 0, less than the minimum length 1"))
        #expect(delivered.value == 1)
    }

    @Test("a request item that does not decode ends the call naming the item and the field")
    func undecodableItem() async {
        let wrongField = await fill(
            items: [try! MMPackEncoder().encode(LoosePut(limit: 5, tags: 6)).get()],
            funnel: RecordingFunnel(), delivered: InvocationCounter())
        #expect(
            wrongField
                == MMError(code: 6, message: "stream violation: [0].text: expected string, got integer"))
        let notAMap = await fill(
            items: [try! MMPackEncoder().encode(9).get()],
            funnel: RecordingFunnel(), delivered: InvocationCounter())
        #expect(notAMap == MMError(code: 6, message: "stream violation: [0]: expected map, got integer"))
    }
}

/// Opens `vault.fill`, sends `items` from seq 0, and returns the call's
/// terminal error.
private func fill(
    items: [ByteBuffer],
    funnel: RecordingFunnel,
    delivered: InvocationCounter
) async -> MMError? {
    let runtime = makeIngressRuntime(funnel: funnel)
    let route = Handle(Vault.fill) { _, elements, _ in
        var count = 0
        for await _ in elements {
            delivered.increment()
            count += 1
        }
        return .success(Vault.FillResponse(filled: count))
    }
    let dropped = Counter(label: "mm_test_ingress_frames_dropped_total")
    guard
        let plan = await runtime.openStream(
            msgid: 9, route: route, params: try! MMPackEncoder().encode(Vault.FillRequest()).get(),
            context: makeContext(), framesDropped: dropped)
    else {
        Issue.record("the open was refused")
        return nil
    }
    await withDiscardingTaskGroup { group in
        group.addTask { await plan.run() }
        group.addTask {
            for (seq, item) in items.enumerated() {
                await runtime.route(
                    .item(msgid: 9, seq: UInt32(seq), item: item), framesDropped: dropped)
            }
        }
    }
    return funnel.terminal(msgid: 9) ?? nil
}

private func makeIngressRuntime(funnel: RecordingFunnel) -> StreamRuntime {
    StreamRuntime(
        writer: funnel,
        metrics: MMStreamMetrics(factory: CapturingMetricsFactory()),
        maxConcurrentStreams: 8,
        logger: Logger(label: "test")
    )
}

extension RecordingFunnel {
    /// The error of the terminal for `msgid`: nil when there is none, `.some(nil)`
    /// for a success.
    func terminal(msgid: UInt32) -> MMError?? {
        for envelope in self.envelopes {
            if case .response(let id, let error, _) = envelope, id == msgid {
                return .some(error)
            }
        }
        return nil
    }
}

import MMSchema
import MMServer
import MMTestSupport
import MMWire
import NIOCore
import Testing

/// The wire error model: unknown method, malformed params in all shapes,
/// handler failures passed verbatim, and exact success round-trips.
@Suite("Error model")
struct ErrorModelTests {
    /// A router with one echo route; the target grants read to everyone.
    private func makeRouter(provider: InMemoryACLProvider? = nil) -> Router {
        Router(aclProvider: provider ?? InMemoryACLProvider([entity("solo"): acl(0o444)])) {
            Handle(Method<EchoRequest, EchoResponse>(name: "test.echo", access: .read)) {
                request, _ in
                .success(EchoResponse(value: request.value * 2))
            }
        }
    }

    @Test("unknown method returns an error response with the same msgid")
    func unknownMethod() async {
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: request(
                msgid: 42, method: "no.such", entity: entity("solo"),
                EchoRequest(entity: entity("solo"), value: 1)),
            context: makeContext()
        )
        #expect(
            reply
                == .response(
                    msgid: 42,
                    error: MMError(code: 1, message: "unknown method"),
                    result: nil
                )
        )
    }

    @Test("params that are not a map are malformedParams")
    func paramsNotAMap() async {
        let router = self.makeRouter()
        var params = ByteBuffer()
        params.writeMessagePackInt(5)
        let reply = await router.dispatch(
            envelope: .request(msgid: 7, method: "test.echo", entity: "solo", params: params),
            context: makeContext()
        )
        #expect(
            reply
                == .response(
                    msgid: 7,
                    error: MMError(code: 3, message: "malformed params"),
                    result: nil
                )
        )
    }

    @Test("params missing a required field fail the full decode as malformedParams")
    func missingRequiredField() async {
        struct NoEntity: Codable {
            var value: Int
            enum CodingKeys: Int, CodingKey {
                case value = 1
            }
        }
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: request(method: "test.echo", entity: entity("solo"), NoEntity(value: 9)),
            context: makeContext()
        )
        #expect(errorCode(of: reply) == MMErrorCode.malformedParams.code)
    }

    @Test("a field of the wrong wire type fails the full decode as malformedParams")
    func wrongFieldType() async {
        struct IntEntity: Codable {
            var entity: Int
            enum CodingKeys: Int, CodingKey {
                case entity = 0
            }
        }
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: request(method: "test.echo", entity: entity("solo"), IntEntity(entity: 12)),
            context: makeContext()
        )
        #expect(errorCode(of: reply) == MMErrorCode.malformedParams.code)
    }

    @Test("an invalid entity path in the open envelope is malformedParams")
    func invalidEnvelopeEntity() async {
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: .request(
                msgid: 1, method: "test.echo", entity: "Not.Valid",
                params: encodedParams(EchoRequest(entity: entity("solo"), value: 1))),
            context: makeContext()
        )
        #expect(errorCode(of: reply) == MMErrorCode.malformedParams.code)
    }

    @Test("a request that authorizes but fails full decode is malformedParams")
    func fullDecodeFailureAfterAuthorization() async {
        // Key 0 holds a valid entity, key 1 holds a string where the handler's
        // request type expects an int: extraction and authorization pass, the
        // full decode fails.
        struct StringValue: Codable {
            var entity: EntityName
            var value: String
            enum CodingKeys: Int, CodingKey {
                case entity = 0
                case value = 1
            }
        }
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: request(
                method: "test.echo", entity: entity("solo"),
                StringValue(entity: entity("solo"), value: "nope")),
            context: makeContext()
        )
        #expect(errorCode(of: reply) == MMErrorCode.malformedParams.code)
    }

    @Test("handler failure Result reaches the peer verbatim, payload included")
    func handlerErrorVerbatim() async {
        var payload = ByteBuffer()
        payload.writeMessagePackInt(99)
        let domainError = MMError(code: 64, message: "domain says no", payload: payload)
        let router = Router(aclProvider: InMemoryACLProvider([entity("solo"): acl(0o444)])) {
            Handle(Method<EchoRequest, EchoResponse>(name: "test.fail", access: .read)) { _, _ in
                .failure(domainError)
            }
        }
        let reply = await router.dispatch(
            envelope: request(
                msgid: 5, method: "test.fail", entity: entity("solo"),
                EchoRequest(entity: entity("solo"), value: 1)),
            context: makeContext()
        )
        #expect(reply == .response(msgid: 5, error: domainError, result: nil))
    }

    @Test("handler success encodes exact response bytes, round-trippable to Response")
    func handlerSuccessRoundTrip() async throws {
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: request(
                msgid: 3, method: "test.echo", entity: entity("solo"),
                EchoRequest(entity: entity("solo"), value: 21)),
            context: makeContext()
        )
        let buffer = try #require(resultBuffer(of: reply))
        #expect(
            MMPackDecoder().decode(EchoResponse.self, from: buffer)
                == .success(EchoResponse(value: 42))
        )
        // The result slot is exactly the encoder's output for the value.
        #expect(buffer == encodedParams(EchoResponse(value: 42)))
    }

    @Test("inbound response envelopes are dropped, not answered")
    func inboundResponseDropped() async {
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: .response(msgid: 1, error: nil, result: nil),
            context: makeContext()
        )
        #expect(reply == nil)
    }
}

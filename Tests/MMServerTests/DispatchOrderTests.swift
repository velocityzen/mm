import MMSchema
import MMServer
import MMWire
import Testing

/// Proves the fixed dispatch order via a lookup-recording provider and a
/// request type whose full decode is observable: ancestors outermost-first,
/// then the target, and never a full params decode before authorization
/// passes.
@Suite("Dispatch order")
struct DispatchOrderTests {
    static let probedMethod = Method<ProbedRequest, EchoResponse>(
        name: "probe.run",
        access: .read
    )

    private func makeRouter(provider: RecordingACLProvider) -> Router {
        Router(aclProvider: provider) {
            Handle(Self.probedMethod) { _, _ in
                .success(EchoResponse(value: 7))
            }
        }
    }

    private func dispatchProbed(
        provider: RecordingACLProvider,
        target: String,
        counter: InvocationCounter
    ) async -> MMEnvelope? {
        let router = self.makeRouter(provider: provider)
        let envelope = request(
            method: "probe.run", entity: entity(target), ProbedRequest(entity: entity(target))
        )
        return await FullDecodeProbe.$counter.withValue(counter) {
            await router.dispatch(envelope: envelope, context: makeContext())
        }
    }

    @Test("ancestors are checked outermost-first, then the target, then decode")
    func traversalOrderThenTarget() async {
        let provider = RecordingACLProvider([
            entity("top"): acl(0o111),
            entity("top.mid"): acl(0o111),
            entity("top.mid.leaf"): acl(0o444),
        ])
        let counter = InvocationCounter()
        let reply = await self.dispatchProbed(
            provider: provider, target: "top.mid.leaf", counter: counter
        )
        #expect(errorCode(of: reply) == nil)
        #expect(
            await provider.lookups == [entity("top"), entity("top.mid"), entity("top.mid.leaf")])
        #expect(counter.value == 1)
    }

    @Test("denial at the first ancestor stops the walk and never decodes params")
    func ancestorDenialShortCircuits() async {
        let provider = RecordingACLProvider([
            entity("top"): acl(0o110),  // no x for the *other* class
            entity("top.mid"): acl(0o111),
            entity("top.mid.leaf"): acl(0o444),
        ])
        let counter = InvocationCounter()
        let reply = await self.dispatchProbed(
            provider: provider, target: "top.mid.leaf", counter: counter
        )
        #expect(errorCode(of: reply) == MMErrorCode.permissionDenied.code)
        #expect(await provider.lookups == [entity("top")])
        #expect(counter.value == 0)
    }

    @Test("denial at the target still never decodes params; all lookups ran")
    func targetDenialAfterFullTraversal() async {
        let provider = RecordingACLProvider([
            entity("top"): acl(0o111),
            entity("top.mid"): acl(0o111),
            entity("top.mid.leaf"): acl(0o440),  // no read for other
        ])
        let counter = InvocationCounter()
        let reply = await self.dispatchProbed(
            provider: provider, target: "top.mid.leaf", counter: counter
        )
        #expect(errorCode(of: reply) == MMErrorCode.permissionDenied.code)
        #expect(
            await provider.lookups == [entity("top"), entity("top.mid"), entity("top.mid.leaf")])
        #expect(counter.value == 0)
    }

    @Test("missing target ACL denies without decoding params")
    func missingTargetACLDenies() async {
        let provider = RecordingACLProvider([
            entity("top"): acl(0o111),
            entity("top.mid"): acl(0o111),
        ])
        let counter = InvocationCounter()
        let reply = await self.dispatchProbed(
            provider: provider, target: "top.mid.leaf", counter: counter
        )
        #expect(errorCode(of: reply) == MMErrorCode.permissionDenied.code)
        #expect(counter.value == 0)
    }

    @Test("provider failure during traversal maps to internalError, no decode")
    func providerFailureIsInternalError() async {
        let provider = RecordingACLProvider(
            [entity("top"): acl(0o111)],
            failing: [entity("top.mid")]
        )
        let counter = InvocationCounter()
        let reply = await self.dispatchProbed(
            provider: provider, target: "top.mid.leaf", counter: counter
        )
        #expect(errorCode(of: reply) == MMErrorCode.internalError.code)
        #expect(await provider.lookups == [entity("top"), entity("top.mid")])
        #expect(counter.value == 0)
    }

    @Test("single-segment target has no traversal: exactly one lookup")
    func singleSegmentTargetSkipsTraversal() async {
        let provider = RecordingACLProvider([entity("solo"): acl(0o444)])
        let counter = InvocationCounter()
        let reply = await self.dispatchProbed(provider: provider, target: "solo", counter: counter)
        #expect(errorCode(of: reply) == nil)
        #expect(await provider.lookups == [entity("solo")])
        #expect(counter.value == 1)
    }
}

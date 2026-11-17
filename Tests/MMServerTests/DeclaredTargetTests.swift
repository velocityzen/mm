import MMSchema
import MMTestSupport
import MMWire
import Testing

@testable import MMServer

/// A call's declared target on the router: a route without `Accepts` takes
/// it, an `Accepts` narrows it, and the boot check finds an `Accepts`
/// pattern outside it.
@Suite("Declared targets on routes")
struct DeclaredTargetTests {
    private let acls: [EntityName: EntityACL] = [
        entity("box"): acl(0o755),
        entity("box.item"): acl(0o755),
        entity("box.other"): acl(0o755),
        entity("shelf"): acl(0o755),
    ]

    private static let get = Method<EchoRequest, EchoResponse>(
        name: "box.get",
        access: .read,
        target: ["box.*"]
    )

    private func code(_ router: Router, _ target: EntityName) async -> Int? {
        let reply = await router.dispatch(
            envelope: request(
                method: "box.get",
                entity: target,
                EchoRequest(entity: target, value: 1)
            ),
            context: makeContext(peer: Peers.owner)
        )
        return errorCode(of: reply)
    }

    @Test("a route without Accepts takes its call's declared target")
    func routeTakesTheTarget() async {
        let router = Router(aclProvider: InMemoryACLProvider(acls)) {
            Handle(Self.get) { request, _ in .success(EchoResponse(value: request.value)) }
        }
        #expect(await code(router, entity("box.item")) == nil)
        #expect(await code(router, entity("box")) == MMErrorCode.permissionDenied.code)
        #expect(await code(router, entity("shelf")) == MMErrorCode.permissionDenied.code)
        #expect(await code(router, .root) == MMErrorCode.permissionDenied.code)
    }

    @Test("an Accepts within the declared target narrows it")
    func acceptsNarrowsTheTarget() async {
        let router = Router(aclProvider: InMemoryACLProvider(acls)) {
            Handle(Self.get, Accepts("box.item")) { request, _ in
                .success(EchoResponse(value: request.value))
            }
        }
        #expect(await code(router, entity("box.item")) == nil)
        #expect(await code(router, entity("box.other")) == MMErrorCode.permissionDenied.code)
    }

    @Test("a target of one entity lets a request omit it")
    func soleEntityTarget() async {
        let router = Router(aclProvider: InMemoryACLProvider(acls)) {
            Handle(
                Method<EchoRequest, EchoResponse>(
                    name: "box.get",
                    access: .read,
                    target: ["box.item"]
                )
            ) { request, context in
                .success(EchoResponse(value: context.entity == entity("box.item") ? 1 : 0))
            }
        }
        #expect(await code(router, .root) == nil)
    }

    @Test("the boot check finds the first Accepts pattern outside the declared target")
    func bootCheck() {
        func route(_ method: Method<EchoRequest, EchoResponse>, _ accepts: Accepts?) -> Route {
            Handle(method, accepts) { request, _ in .success(EchoResponse(value: request.value)) }
        }
        let undeclared = Method<EchoRequest, EchoResponse>(name: "box.get", access: .read)
        #expect(route(Self.get, Accepts("box.item", "box.a.*")).patternOutsideTarget == nil)
        #expect(route(Self.get, Accepts("box.item", "box", "shelf")).patternOutsideTarget == "box")
        #expect(route(Self.get, nil).patternOutsideTarget == nil)
        #expect(route(undeclared, Accepts("shelf")).patternOutsideTarget == nil)
    }
}

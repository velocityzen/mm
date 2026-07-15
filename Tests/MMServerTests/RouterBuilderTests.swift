import MMSchema
import MMServer
import MMWire
import Testing

/// A sealed namespace fixture for the startup cross-checks.
enum PingNamespace: MethodNamespace {
    static let ping = Method<EchoRequest, EchoResponse>(name: "pingns.ping", access: .read)
    static let pong = Method<EchoRequest, EchoResponse>(name: "pingns.pong", access: .read)
    static let all: [AnyMethod] = [AnyMethod(ping), AnyMethod(pong)]
}

/// RouterBuilder shapes and the Router init preconditions.
@Suite("RouterBuilder and startup checks")
struct RouterBuilderTests {
    private func route(_ name: String) -> Route {
        Handle(Method<EchoRequest, EchoResponse>(name: name, access: .read)) { request, _ in
            .success(EchoResponse(value: request.value))
        }
    }

    @Test("plain expressions and array groups register")
    func expressionsAndGroups() {
        let group = [self.route("grouped.one"), self.route("grouped.two")]
        let router = Router(aclProvider: InMemoryACLProvider()) {
            self.route("plain.solo")
            group
        }
        #expect(
            router.signatures.map(\.name) == ["grouped.one", "grouped.two", "plain.solo"]
        )
    }

    @Test("buildOptional includes or omits routes", arguments: [true, false])
    func buildOptional(includeExtra: Bool) {
        let router = Router(aclProvider: InMemoryACLProvider()) {
            self.route("base.run")
            if includeExtra {
                self.route("extra.run")
            }
        }
        let expected = includeExtra ? ["base.run", "extra.run"] : ["base.run"]
        #expect(router.signatures.map(\.name) == expected)
    }

    @Test("buildEither picks one branch", arguments: [true, false])
    func buildEither(modern: Bool) {
        let router = Router(aclProvider: InMemoryACLProvider()) {
            if modern {
                self.route("api.modern")
            } else {
                self.route("api.legacy")
            }
        }
        let expected = modern ? ["api.modern"] : ["api.legacy"]
        #expect(router.signatures.map(\.name) == expected)
    }

    @Test("buildArray registers for-loop routes")
    func buildArray() {
        let router = Router(aclProvider: InMemoryACLProvider()) {
            for verb in ["one", "two", "three"] {
                self.route("loop.\(verb)")
            }
        }
        #expect(router.signatures.map(\.name) == ["loop.one", "loop.three", "loop.two"])
    }

    @Test("fully bound namespace passes the cross-checks and dispatches")
    func namespacePositivePath() async {
        let router = Router(
            namespaces: [PingNamespace.self],
            aclProvider: InMemoryACLProvider([entity("solo"): acl(0o444)])
        ) {
            Handle(PingNamespace.ping) { request, _ in .success(EchoResponse(value: request.value))
            }
            Handle(PingNamespace.pong) { request, _ in .success(EchoResponse(value: request.value))
            }
        }
        let reply = await router.dispatch(
            envelope: request(
                method: "pingns.ping", entity: entity("solo"),
                EchoRequest(entity: entity("solo"), value: 8)),
            context: makeContext()
        )
        #expect(errorCode(of: reply) == nil)
    }

    @Test("duplicate method name is a startup precondition failure")
    func duplicateNameExits() async {
        await #expect(processExitsWith: .failure) {
            _ = Router(aclProvider: InMemoryACLProvider()) {
                Handle(Method<EchoRequest, EchoResponse>(name: "dup.method", access: .read)) {
                    _, _ in .success(EchoResponse(value: 1))
                }
                Handle(Method<EchoRequest, EchoResponse>(name: "dup.method", access: .read)) {
                    _, _ in .success(EchoResponse(value: 2))
                }
            }
        }
    }

    @Test("unbound namespace descriptor is a startup precondition failure")
    func unboundDescriptorExits() async {
        await #expect(processExitsWith: .failure) {
            // PingNamespace.all lists pong, but only ping is registered.
            _ = Router(namespaces: [PingNamespace.self], aclProvider: InMemoryACLProvider()) {
                Handle(PingNamespace.ping) { request, _ in
                    .success(EchoResponse(value: request.value))
                }
            }
        }
    }

    @Test("route under a namespace prefix but missing from its all list exits")
    func foreignRouteInNamespacePrefixExits() async {
        await #expect(processExitsWith: .failure) {
            _ = Router(namespaces: [PingNamespace.self], aclProvider: InMemoryACLProvider()) {
                Handle(PingNamespace.ping) { request, _ in
                    .success(EchoResponse(value: request.value))
                }
                Handle(PingNamespace.pong) { request, _ in
                    .success(EchoResponse(value: request.value))
                }
                // Same "pingns" prefix, not in PingNamespace.all.
                Handle(Method<EchoRequest, EchoResponse>(name: "pingns.rogue", access: .read)) {
                    _, _ in .success(EchoResponse(value: 0))
                }
            }
        }
    }

}

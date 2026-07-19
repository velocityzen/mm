import Logging
import MMSchema
import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import Testing

@testable import MMServer

// MARK: - Fixtures

private enum BuilderMethods: MethodNamespace {
    static let echo = Method<EchoRequest, EchoResponse>(name: "box.echo", access: .read)
    static let bump = Method<EchoRequest, EchoResponse>(name: "box.bump", access: .write)

    @SchemaBuilder static var all: [AnyMethod] {
        echo
        bump
    }
}

/// A reusable group with its own dependency, per the declarative pattern.
private struct BumpHandlers: RouteGroup {
    let increment: Int

    @RouterBuilder var routes: [Route] {
        On(BuilderMethods.bump) { auth, request in
            .success(EchoResponse(value: request.value + increment))
        }
    }
}

private func grantingProvider() -> InMemoryACLProvider {
    InMemoryACLProvider([
        entity("box"): acl(0o777),
        entity("box.item"): acl(0o777),
    ])
}

@Suite("Declarative server builder")
struct ServerBuilderTests {
    @Test("parts assemble into a working service: config, ACL, log, groups")
    func assembly() async throws {
        let service = MMService {
            Configuration(endpoint: .unix(path: "/tmp/builder-test.sock"), maxConnections: 3)
            ACLProvider(grantingProvider())
            Log(label: "test.builder", level: .error)
            OnBind { _ in }
            For(BuilderMethods.self) {
                On(BuilderMethods.echo) { auth, request in
                    .success(EchoResponse(value: request.value))
                }
                BumpHandlers(increment: 10)
            }
        }
        // The namespace cross-check accepted both routes; builtins registered.
        #expect(service.router.signatures.map(\.name).contains("box.echo"))
        #expect(service.router.signatures.map(\.name).contains("box.bump"))
        #expect(service.router.signatures.map(\.name).contains("server.schema"))
        // On(...) puts the CONTEXT first; verify dispatch reaches the handler
        // with the decoded request intact through the reordering shim.
        let reply = await service.router.dispatch(
            envelope: request(
                method: "box.echo", entity: entity("box.item"),
                EchoRequest(entity: entity("box.item"), value: 7)),
            context: makeContext()
        )
        let buffer = try #require(resultBuffer(of: reply))
        let decoded = try MMPackDecoder().decode(EchoResponse.self, from: buffer).get()
        #expect(decoded == EchoResponse(value: 7))
        // The RouteGroup's captured dependency participates.
        let bumped = await service.router.dispatch(
            envelope: request(
                method: "box.bump", entity: entity("box.item"),
                EchoRequest(entity: entity("box.item"), value: 7)),
            context: makeContext()
        )
        let bumpedBuffer = try #require(resultBuffer(of: bumped))
        let bumpedValue = try MMPackDecoder().decode(EchoResponse.self, from: bumpedBuffer).get()
        #expect(bumpedValue == EchoResponse(value: 17))
    }

    @Test("bare routes outside For skip the namespace cross-check")
    func bareRoutes() {
        let service = MMService {
            Configuration(endpoint: .unix(path: "/tmp/builder-bare.sock"))
            ACLProvider(grantingProvider())
            On(Method<EchoRequest, EchoResponse>(name: "free.echo", access: .read)) {
                auth, request in
                .success(EchoResponse(value: request.value))
            }
        }
        #expect(service.router.signatures.map(\.name).contains("free.echo"))
    }

    @Test("conditional parts compose (buildOptional / buildEither)")
    func conditionalParts() {
        func build(verbose: Bool) -> MMService {
            MMService {
                Configuration(endpoint: .unix(path: "/tmp/builder-cond.sock"))
                ACLProvider(grantingProvider())
                if verbose {
                    Log(label: "test.verbose", level: .trace)
                }
                For(BuilderMethods.self) {
                    On(BuilderMethods.echo) { _, request in
                        .success(EchoResponse(value: request.value))
                    }
                    BumpHandlers(increment: 1)
                }
            }
        }
        #expect(
            build(verbose: true).router.signatures.count
                == build(verbose: false).router.signatures.count)
    }

    @Test("the closure Log form routes lines into the sink")
    func closureLog() {
        let lines = NIOLockedValueBox<[String]>([])
        let part = Log { level, message in
            lines.withLockedValue { $0.append("\(level):\(message)") }
        }
        guard case .logger(var logger) = part.kind else {
            Issue.record("Log closure form must produce a logger part")
            return
        }
        logger.logLevel = .debug
        logger.info("hello")
        logger.debug("world")
        #expect(lines.withLockedValue { $0 } == ["info:hello", "debug:world"])
    }

    @Test("missing Configuration is programmer error")
    func missingConfiguration() async throws {
        await #expect(processExitsWith: .failure) {
            _ = MMService {
                ACLProvider(grantingProvider())
            }
        }
    }

    @Test("missing ACLProvider is programmer error — authorization is never defaulted")
    func missingACLProvider() async throws {
        await #expect(processExitsWith: .failure) {
            _ = MMService {
                Configuration(endpoint: .unix(path: "/tmp/builder-noacl.sock"))
            }
        }
    }

    @Test("duplicate parts are programmer error")
    func duplicateConfiguration() async throws {
        await #expect(processExitsWith: .failure) {
            _ = MMService {
                Configuration(endpoint: .unix(path: "/tmp/a.sock"))
                Configuration(endpoint: .unix(path: "/tmp/b.sock"))
                ACLProvider(grantingProvider())
            }
        }
    }

    @Test("declaring the same namespace twice is programmer error")
    func duplicateNamespace() async throws {
        await #expect(processExitsWith: .failure) {
            _ = MMService {
                Configuration(endpoint: .unix(path: "/tmp/builder-dup.sock"))
                ACLProvider(grantingProvider())
                For(BuilderMethods.self) {
                    On(BuilderMethods.echo) { _, request in
                        .success(EchoResponse(value: request.value))
                    }
                    BumpHandlers(increment: 1)
                }
                For(BuilderMethods.self) {
                    BumpHandlers(increment: 2)
                }
            }
        }
    }
}

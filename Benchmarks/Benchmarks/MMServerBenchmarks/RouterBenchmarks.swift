import Benchmark
import MMSchema
import MMServer
import MMWire

enum Store: MethodNamespace {
    #schema("store") {
        // One integer each way, so the coders cost little and dispatch shows.
        Call("put") {
            Access { .write }
            Request { Field("value", .int) }
            Response { Field("value", .int) }
        }
    }
}

private let owner = PeerIdentity(uid: 1000, gid: 1000, supplementaryGroups: [], pid: 101)
private let stranger = PeerIdentity(uid: 2000, gid: 2000, supplementaryGroups: [], pid: 102)

/// The server's work for one call after framing: route lookup, entity parse,
/// the ACL checks, params decode, the handler, and the response encode. The
/// connection and its socket are left out.
func routerBenchmarks() {
    // Owner-only records: the owner may traverse and write each of them; the
    // stranger may do neither.
    let entities = ["store", "store.aisle", "store.aisle.shelf", "store.aisle.shelf.bin"]
    let acls = Dictionary(
        uniqueKeysWithValues: entities.map {
            (
                try! EntityName.parse($0).get(),
                EntityACL(owner: owner.uid, group: owner.gid, mode: 0o700)
            )
        }
    )
    let router = Router(namespaces: [Store.self], aclProvider: InMemoryACLProvider(acls)) {
        Handle(Store.put) { request, _ in
            .success(Store.PutResponse(value: request.value))
        }
    }
    let params = try! MMPackEncoder().encode(Store.PutRequest(value: 42)).get()

    dispatchBenchmark(
        "unary",
        router: router,
        envelope: .request(msgid: 7, method: "store.put", entity: "store", params: params),
        peer: owner,
        expecting: nil
    )
    // Three ancestors to traverse before the target: one ACL lookup each.
    dispatchBenchmark(
        "unaryOnDeepEntity",
        router: router,
        envelope: .request(
            msgid: 7,
            method: "store.put",
            entity: "store.aisle.shelf.bin",
            params: params
        ),
        peer: owner,
        expecting: nil
    )
    // Denied on the target's ACL, before the params are decoded.
    dispatchBenchmark(
        "permissionDenied",
        router: router,
        envelope: .request(msgid: 7, method: "store.put", entity: "store", params: params),
        peer: stranger,
        expecting: .permissionDenied
    )
    // Answered from the route table alone.
    dispatchBenchmark(
        "unknownMethod",
        router: router,
        envelope: .request(msgid: 7, method: "store.remove", entity: "store", params: params),
        peer: owner,
        expecting: .unknownMethod
    )

    // Parsed from the envelope on every call, before any ACL lookup.
    Benchmark("EntityName.parse") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(EntityName.parse("store.aisle.shelf.bin"))
        }
    }
}

/// Registers `Router.dispatch.<name>`. Its setup dispatches once and checks
/// the reply, so a fixture that stops reaching the intended path fails the
/// run instead of measuring something else.
private func dispatchBenchmark(
    _ name: String,
    router: Router,
    envelope: MMEnvelope,
    peer: PeerIdentity,
    expecting expectedError: MMErrorCode?
) {
    let context = MMContext(peer: peer, protocolVersion: 1, connectionID: 1)
    var configuration = Benchmark.defaultConfiguration
    configuration.setup = {
        guard
            case .response(_, let error, _) = await router.dispatch(
                envelope: envelope,
                context: context
            )
        else {
            preconditionFailure("Router.dispatch.\(name): no response")
        }
        let errorCode = error.map { MMErrorCode(code: $0.code) }
        precondition(
            errorCode == expectedError,
            "Router.dispatch.\(name): got \(String(describing: errorCode))"
        )
    }

    Benchmark("Router.dispatch.\(name)", configuration: configuration) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await router.dispatch(envelope: envelope, context: context))
        }
    }
}

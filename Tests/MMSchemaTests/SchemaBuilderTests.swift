import Testing

@testable import MMSchema

private struct ProbeRequest: Codable, Hashable, Sendable {
    var entity: EntityName

    enum CodingKeys: Int, CodingKey {
        case entity = 0
    }
}

private struct ProbeResponse: Codable, Hashable, Sendable {
    var ok: Bool

    enum CodingKeys: Int, CodingKey {
        case ok = 0
    }
}

private let alpha = Method<ProbeRequest, ProbeResponse>(name: "ns.alpha", access: .read)
private let beta = Method<ProbeRequest, ProbeResponse>(name: "ns.beta", access: .write)
private let gamma = Method<ProbeRequest, ProbeResponse>(name: "ns.gamma", access: .execute)

@SchemaBuilder
private func buildList(
    includeBeta: Bool,
    wide: Bool = false,
    extras: [Method<ProbeRequest, ProbeResponse>] = []
) -> [AnyMethod] {
    alpha
    if includeBeta {
        beta
    }
    if wide {
        gamma
    } else {
        AnyMethod(gamma)
    }
    for extra in extras {
        extra
    }
}

@Suite("SchemaBuilder")
struct SchemaBuilderTests {
    @Test("bare Method expressions erase into the list, order preserved")
    func expressions() {
        let list = buildList(includeBeta: true)
        #expect(list.map(\.name) == ["ns.alpha", "ns.beta", "ns.gamma"])
        #expect(list.map(\.access) == [.read, .write, .execute])
    }

    @Test("buildOptional: an if with a false condition contributes nothing")
    func optional() {
        #expect(buildList(includeBeta: false).map(\.name) == ["ns.alpha", "ns.gamma"])
    }

    @Test("buildEither: both branches produce the same erased method here")
    func either() {
        // wide=true goes through the Method branch, wide=false through the
        // pre-erased AnyMethod branch — the list must be identical.
        let first = buildList(includeBeta: false, wide: true).map(\.name)
        let second = buildList(includeBeta: false, wide: false).map(\.name)
        #expect(first == second)
    }

    @Test("buildArray: for-loops splice in dynamic descriptor lists")
    func arrays() {
        let extras = [Method<ProbeRequest, ProbeResponse>(name: "ns.extra", access: .read)]
        let list = buildList(includeBeta: false, extras: extras)
        #expect(list.map(\.name) == ["ns.alpha", "ns.gamma", "ns.extra"])
    }

    @Test("a MethodNamespace built with @SchemaBuilder round-trips through signatures")
    func namespaceConformance() throws {
        enum Probe: MethodNamespace {
            @SchemaBuilder static var all: [AnyMethod] {
                alpha
                beta
            }
        }
        #expect(Probe.all.map(\.name) == ["ns.alpha", "ns.beta"])
        let signature = try Probe.all[0].signature().get()
        #expect(signature.name == "ns.alpha")
        #expect(signature.access == .read)
    }

    @Test("group composition: one namespace's list splices into another")
    func composition() {
        enum Combined: MethodNamespace {
            @SchemaBuilder static var all: [AnyMethod] {
                Builtins.all
                alpha
            }
        }
        #expect(Combined.all.map(\.name) == ["server.schema", "server.entity", "ns.alpha"])
    }

    @Test("Builtins.all itself is builder-built and unchanged")
    func builtinsUnchanged() {
        #expect(Builtins.all.map(\.name) == ["server.schema", "server.entity"])
        #expect(Builtins.all.map(\.access) == [.read, .read])
    }
}

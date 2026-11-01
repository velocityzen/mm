import MMClient
import MMSchema
import MMTestSupport
import Testing

/// Every payload a call carries, in every call shape, goes through the
/// generated MessagePack code on both ends when its type has some: requests,
/// stream items in both directions, and terminals. Each probe reports the
/// paths of the hops it went through (see ``CodingPathProbe``), so one `false`
/// names a hop that fell back to `Codable`.
@Suite("Generated MessagePack code over a real temp-dir unix socket")
struct GeneratedCodingIntegrationTests {
    static let box = entity("box")

    @Test("unary: the request and the response")
    func unary() async throws {
        let response = try await withProbeConnection { connection in
            await connection.call(
                TestMethods.probeUnary,
                on: Self.box,
                CodingPathProbe(observed: [])
            )
        }
        #expect(response.map(\.observedWithThisHop) == .success(generated(hops: 2)))
    }

    @Test("server streaming: the request, the server's items, and the terminal")
    func serverStream() async throws {
        let (elements, terminal) = try await withProbeConnection { connection in
            let handle = await connection.call(
                TestMethods.probeServerStream,
                on: Self.box,
                CodingPathProbe(observed: [])
            )
            var elements: [[Bool]] = []
            for await element in handle {
                elements.append(element.observedWithThisHop)
            }
            return (elements, await handle.result().map(\.observedWithThisHop))
        }
        #expect(elements == [generated(hops: 2)])
        #expect(terminal == .success(generated(hops: 2)))
    }

    @Test("client streaming: the request, the client's items, and the terminal")
    func clientStream() async throws {
        let terminal = try await withProbeConnection { connection in
            let handle = await connection.call(
                TestMethods.probeClientStream,
                on: Self.box,
                CodingPathProbe(observed: [])
            )
            for _ in 0..<2 {
                #expect(await handle.send(CodingPathProbe(observed: [])) == .sent)
            }
            await handle.finish()
            return await handle.result().map(\.observedWithThisHop)
        }
        // The request's hop, each element's, then the terminal's own.
        #expect(terminal == .success(generated(hops: 4)))
    }

    @Test("bidirectional: the request, items both ways, and the terminal")
    func bidirectional() async throws {
        let (elements, terminal) = try await withProbeConnection { connection in
            let handle = await connection.call(
                TestMethods.probeBidirectional,
                on: Self.box,
                CodingPathProbe(observed: [])
            )
            // Two items stay inside both directions' windows, so sending them
            // all before reading the echoes cannot stall.
            for _ in 0..<2 {
                #expect(await handle.outbound.send(CodingPathProbe(observed: [])) == .sent)
            }
            await handle.outbound.finish()
            var elements: [[Bool]] = []
            for await element in handle.inbound {
                elements.append(element.observedWithThisHop)
            }
            return (elements, await handle.inbound.result().map(\.observedWithThisHop))
        }
        #expect(elements == [generated(hops: 2), generated(hops: 2)])
        #expect(terminal == .success(generated(hops: 2)))
    }
}

/// What a probe reports after `hops` hops that all took the generated code:
/// an encode and a decode each.
private func generated(hops: Int) -> [Bool] {
    Array(repeating: true, count: hops * 2)
}

/// Runs `body` on a client connected to a fresh test server, requiring the
/// client's run loop to end cleanly.
private func withProbeConnection<T: Sendable>(
    _ body: @escaping @Sendable (MMClientConnection) async throws -> T
) async throws -> T {
    try await withTempSocketPath { path in
        let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
        return try await withRunningServer(server) { _ in
            let (result, runResult) = try await withConnectedClient(unixPath: path, body)
            #expect(throws: Never.self) { try runResult.get() }
            return result
        }
    }
}

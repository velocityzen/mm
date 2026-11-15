import MMTestSupport
import MMWire
import NIOCore
import Testing

@testable import MMServer

/// Real S3 drop rules, over a real socket: a stream frame addressed to a live
/// *unary* msgid, whose only lifecycle is its own terminal, is logged,
/// counted, and dropped; the call still answers once. (Frames to an
/// unknown/retired msgid, and frames to a live *stream* msgid, which are
/// routed rather than dropped, are the province of `StreamingServerTests`.)
/// This pins the drop-and-count edge that keeps a misbehaving or lagging
/// client from disturbing well-formed calls.
@Suite("Server drops stream frames for a live unary msgid")
struct ServerStreamFrameDropTests {
    @Test("stream frames for a live in-flight msgid do not disturb its terminal")
    func streamFramesDoNotDisturbInFlightCall() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    // Park a call on the gate, pelt its msgid with stream
                    // frames, then release: exactly one terminal, correct value.
                    try await session.send(
                        request(
                            msgid: 21, method: "slow.wait", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item")))
                    )
                    _ = try await withDeadline { try await server.slowStarted.wait() }
                    // A credit or CANCEL for a live UNARY msgid drops: the stream
                    // table's routeCredit/routeCancel return nil for any msgid it
                    // does not own as a stream (the unary call answers with its
                    // own terminal; CANCEL is client→whole-call, not applicable).
                    try await session.send(MMEnvelope.credit(msgid: 21, credits: 2))
                    try await session.send(MMEnvelope.cancel(msgid: 21))  // dropped: CANCEL on a live unary msgid
                    server.slowGate.fire(())
                    let reply = try await session.response(msgid: 21)
                    #expect(reply.error == nil)
                    let result = try decodeResult(EchoResponse.self, from: reply.result)
                    #expect(result == EchoResponse(value: 99))
                }
            }
        }
    }
}

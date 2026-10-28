import MMWire
import Metrics
import NIOCore
import NIOEmbedded
import Testing

@testable import MMServer

@Suite("Connection writer")
struct ConnectionWriterTests {
    @Test("a cancelled sender fails only its own write; the connection stays open")
    func cancelledSenderLeavesWriterOpen() async throws {
        let loop = NIOAsyncTestingEventLoop()
        let channel = NIOAsyncTestingChannel(loop: loop)
        let wrapped = try await loop.executeInContext {
            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
        }
        try await channel.connect(to: SocketAddress(unixDomainSocketPath: "/mm-writer-test")).get()
        try await wrapped.executeThenClose { _, outbound in
            let writer = ConnectionWriter(
                outbound: outbound, framesOut: Counter(label: "mm_test_frames_out"))
            let terminal = MMEnvelope.response(msgid: 7, error: nil, result: nil)

            // A sender whose task is cancelled — a stream handler torn down by a
            // CANCEL or a violation while writing. The NIO writer refuses its
            // frame with CancellationError, without touching the channel.
            let cancelled = await withTaskGroup(of: Result<Void, ServerError>.self) { group in
                group.addTask {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await writer.send(terminal)
                }
                return await group.next() ?? .success(())
            }
            guard case .failure(.cancelled) = cancelled else {
                Issue.record("expected .failure(.cancelled), got \(cancelled)")
                return
            }

            // Every other call's frames still reach the wire.
            guard case .success = await writer.send(terminal) else {
                Issue.record("a cancelled sender must not close the connection's writer")
                return
            }
            let written = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
            guard case .response(let msgid, _, _) = try MMEnvelope.decode(from: written).get()
            else {
                Issue.record("expected the terminal on the wire")
                return
            }
            #expect(msgid == 7)
        }
    }
}

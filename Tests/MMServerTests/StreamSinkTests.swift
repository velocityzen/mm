import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMServer

/// Records `(seq, item)` writes the response sink emits, so the credit tests can
/// prove seq stamping and delivery timing.
private final class ItemRecorder: Sendable {
    private let writes = NIOLockedValueBox<[(seq: UInt32, bytes: Int)]>([])
    func sink(_ seq: UInt32, _ item: ByteBuffer) async -> Bool {
        self.writes.withLockedValue { $0.append((seq, item.readableBytes)) }
        return true
    }
    var seqs: [UInt32] { self.writes.withLockedValue { $0.map(\.seq) } }
    var count: Int { self.writes.withLockedValue { $0.count } }
}

private func encoded(_ value: Int) -> ByteBuffer {
    try! MMPackEncoder().encode(value).get()
}

private func makeSink(
    _ recorder: ItemRecorder
) -> (MMResponseSink<Int>, MMResponseSinkState) {
    let state = MMResponseSinkState(
        msgid: 1,
        itemSink: { seq, item in await recorder.sink(seq, item) },
        metrics: MMStreamMetrics()
    )
    return (MMResponseSink<Int>(state: state), state)
}

@Suite("Response sink credit accounting")
struct StreamSinkTests {
    @Test("the initial window lets 8 sends through, seq-stamped from 0")
    func initialWindow() async {
        let recorder = ItemRecorder()
        let (sink, _) = makeSink(recorder)
        for value in 0..<8 {
            #expect(await sink.send(value) == .sent)
        }
        #expect(recorder.count == 8)
        #expect(recorder.seqs == Array(UInt32(0)..<8))
    }

    @Test("a send at zero credit parks until a grant, then proceeds")
    func parkThenGrant() async {
        let recorder = ItemRecorder()
        let (sink, state) = makeSink(recorder)
        // Drain the initial window.
        for value in 0..<8 { #expect(await sink.send(value) == .sent) }

        // The 9th send has no credit: it parks. Launch it, then grant.
        let parked = Task { await sink.send(99) }
        // Give the parked send a moment to actually suspend, then grant 2.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        state.grant(2)
        #expect(await parked.value == .sent)
        // 9 delivered, seq 8 for the parked send.
        #expect(recorder.count == 9)
        #expect(recorder.seqs.last == 8)

        // One credit remains (granted 2, spent 1 on the parked send): the next
        // send proceeds without parking.
        #expect(await sink.send(100) == .sent)
        #expect(recorder.count == 10)
    }

    @Test("client STOP makes send report .peerStopped; the last credited item is dropped")
    func peerStopped() async {
        let recorder = ItemRecorder()
        let (sink, state) = makeSink(recorder)
        #expect(await sink.send(1) == .sent)
        state.peerStop()
        // Credit remains, but the peer asked us to stop: subsequent sends report
        // .peerStopped and are not delivered.
        #expect(await sink.send(2) == .peerStopped)
        #expect(await sink.send(3) == .peerStopped)
        #expect(recorder.count == 1)
    }

    @Test("a parked send resumes .peerStopped when the client STOPs")
    func parkedResumesPeerStopped() async {
        let recorder = ItemRecorder()
        let (sink, state) = makeSink(recorder)
        for value in 0..<8 { _ = await sink.send(value) }
        let parked = Task { await sink.send(99) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        state.peerStop()
        #expect(await parked.value == .peerStopped)
        #expect(recorder.count == 8)  // the parked item was not delivered
    }

    @Test("end() makes send report .callEnded; a parked send resumes .callEnded")
    func ended() async {
        let recorder = ItemRecorder()
        let (sink, state) = makeSink(recorder)
        for value in 0..<8 { _ = await sink.send(value) }
        let parked = Task { await sink.send(99) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        state.end()
        #expect(await parked.value == .callEnded)
        // After end, every send short-circuits .callEnded.
        #expect(await sink.send(1) == .callEnded)
        #expect(recorder.count == 8)
    }

    @Test("grants are additive across several batches")
    func additiveGrants() async {
        let recorder = ItemRecorder()
        let (sink, state) = makeSink(recorder)
        for value in 0..<8 { _ = await sink.send(value) }
        // No credit. Grant 3 then 2 with no send in between: they add to 5.
        state.grant(3)
        state.grant(2)
        for _ in 0..<5 { #expect(await sink.send(0) == .sent) }
        #expect(recorder.count == 13)
        // Now empty again → the next send parks.
        let parked = Task { await sink.send(0) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        state.grant(1)
        #expect(await parked.value == .sent)
        #expect(recorder.count == 14)
    }
}

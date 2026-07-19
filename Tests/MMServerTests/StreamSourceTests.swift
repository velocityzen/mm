import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMServer

/// Records outbound frames the request-stream source emits (credit grants,
/// STOP), so the inbound-credit tests can prove grant batching.
private final class FrameRecorder: Sendable {
    private let frames = NIOLockedValueBox<[MMEnvelope]>([])
    func sink(_ envelope: MMEnvelope) async -> Bool {
        self.frames.withLockedValue { $0.append(envelope) }
        return true
    }
    var snapshot: [MMEnvelope] { self.frames.withLockedValue { $0 } }
    var grants: [UInt32] {
        self.snapshot.compactMap { if case .credit(_, let c) = $0 { return c } else { return nil } }
    }
}

private func encodedInt(_ value: Int) -> ByteBuffer {
    try! MMPackEncoder().encode(value).get()
}

private func makeSource(
    _ recorder: FrameRecorder
) -> (MMRequestStreamSource<Int>, MMRequestStream<Int>) {
    let source = MMRequestStreamSource<Int>(
        msgid: 1,
        frameSink: { await recorder.sink($0) },
        metrics: MMStreamMetrics()
    )
    let made = MMRequestStream<Int>.Base.makeSequence(
        elementType: Int.self,
        backPressureStrategy: .init(
            lowWatermark: MMStreamFlowControl.lowWatermark,
            highWatermark: Int(MMStreamFlowControl.initialWindow)
        ),
        finishOnDeinit: false,
        delegate: source
    )
    source.adopt(source: made.source)
    return (source, MMRequestStream(base: made.sequence, source: source))
}

@Suite("Request stream source: credit + delivery")
struct StreamSourceTests {
    @Test("the initial window admits 8 items; the 9th has no credit")
    func initialCredit() {
        let recorder = FrameRecorder()
        // Retain the stream: dropping it before iterating would terminate the
        // source (the producer's didTerminate fires on an unconsumed sequence).
        let (source, stream) = makeSource(recorder)
        for _ in 0..<8 {
            #expect(source.hasCreditForItem())
            #expect(source.deliver(encodedInt(1)).isSuccess)
        }
        // Window exhausted; no consumer has drained, so no grant has replenished.
        #expect(!source.hasCreditForItem())
        _ = stream
    }

    @Test("a malformed item surfaces a decode failure (a stream violation)")
    func decodeFailure() {
        let recorder = FrameRecorder()
        let (source, stream) = makeSource(recorder)
        // A MessagePack string where an Int is expected.
        let badItem = try! MMPackEncoder().encode("not an int").get()
        #expect(source.hasCreditForItem())
        if case .success = source.deliver(badItem) {
            Issue.record("decoding a string as Int should fail")
        }
        _ = stream
    }

    @Test("consuming the buffer replenishes credit via a batched grant")
    func consumptionGrantsCredit() async {
        let recorder = FrameRecorder()
        let (source, stream) = makeSource(recorder)
        // Fill the window.
        for _ in 0..<8 { #expect(source.deliver(encodedInt(7)).isSuccess) }
        #expect(!source.hasCreditForItem())

        // Run the grant pump and drain all 8 items; the pump should emit at
        // least one additive grant once the consumer drains below the low
        // watermark, restoring credit.
        let pump = Task { await source.runGrantPump() }
        var received = 0
        for await value in stream {
            #expect(value == 7)
            received += 1
            if received == 8 { break }
        }
        #expect(received == 8)
        // Give the pump a beat to flush its batch, then finish the stream so the
        // pump loop exits.
        try? await Task.sleep(nanoseconds: 30_000_000)
        source.finishFromEnd()
        await pump.value

        // Credit was granted back (the exact batching is watermark-based; the
        // invariant is that grants were additive and non-zero, and never pushed
        // the client past the window).
        let grants = recorder.grants
        #expect(!grants.isEmpty)
        #expect(grants.allSatisfy { $0 > 0 && $0 <= MMStreamFlowControl.initialWindow })
    }

    @Test("client END finishes the sequence cleanly")
    func endFinishes() async {
        let recorder = FrameRecorder()
        let (source, stream) = makeSource(recorder)
        #expect(source.deliver(encodedInt(1)).isSuccess)
        let pump = Task { await source.runGrantPump() }
        source.finishFromEnd()
        var values: [Int] = []
        for await value in stream { values.append(value) }
        #expect(values == [1])  // buffered item drained, then the sequence ended
        await pump.value
    }

    @Test("stop() sends exactly one kind-5 frame, idempotently")
    func stopIsIdempotent() async {
        let recorder = FrameRecorder()
        let (_, stream) = makeSource(recorder)
        await stream.stop()
        await stream.stop()
        let stops = recorder.snapshot.filter {
            if case .stop = $0 { return true } else { return false }
        }
        #expect(stops.count == 1)
        if case .stop(_, let code) = stops.first {
            #expect(code == 0)
        }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

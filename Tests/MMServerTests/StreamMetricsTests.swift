import MMSchema
import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMServer

/// A capturing ``MetricsFactory`` that records counter increments by label into
/// a shared registry, so a test can assert exactly which stream counters
/// advanced and by how much. Injected into ``MMStreamMetrics`` per test (never
/// bootstrapped globally), so it is isolated from every other suite and safe
/// under parallel test execution.
final class CapturingMetricsFactory: MetricsFactory, Sendable {
    private let totals = NIOLockedValueBox<[String: Int64]>([:])

    /// The recorded total for `label` (0 if the counter was never incremented).
    func total(_ label: String) -> Int64 {
        self.totals.withLockedValue { $0[label] ?? 0 }
    }

    private final class Handle: CounterHandler {
        let label: String
        let totals: NIOLockedValueBox<[String: Int64]>
        init(label: String, totals: NIOLockedValueBox<[String: Int64]>) {
            self.label = label
            self.totals = totals
        }
        func increment(by amount: Int64) {
            self.totals.withLockedValue { $0[self.label, default: 0] += amount }
        }
        func reset() { self.totals.withLockedValue { $0[self.label] = 0 } }
    }

    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        Handle(label: label, totals: self.totals)
    }
    func makeFloatingPointCounter(
        label: String, dimensions: [(String, String)]
    ) -> FloatingPointCounterHandler {
        NOOPMetricsHandler.instance
    }
    func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        NOOPMetricsHandler.instance
    }
    func makeRecorder(
        label: String, dimensions: [(String, String)], aggregate: Bool
    ) -> RecorderHandler {
        NOOPMetricsHandler.instance
    }
    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        NOOPMetricsHandler.instance
    }
    func destroyCounter(_ handler: CounterHandler) {}
    func destroyFloatingPointCounter(_ handler: FloatingPointCounterHandler) {}
    func destroyMeter(_ handler: MeterHandler) {}
    func destroyRecorder(_ handler: RecorderHandler) {}
    func destroyTimer(_ handler: TimerHandler) {}
}

private struct MetricsReq: Codable, Sendable {
    var entity: EntityName
    enum CodingKeys: Int, CodingKey { case entity = 0 }
}

private struct MetricsAck: Codable, Sendable {
    var count: Int
    enum CodingKeys: Int, CodingKey { case count = 0 }
}

private func metricsOpenParams() -> ByteBuffer {
    try! MMPackEncoder().encode(MetricsReq(entity: entity("e"))).get()
}

@Suite("Stream metrics counters advance as documented")
struct StreamMetricsTests {
    private func makeRuntime(
        factory: CapturingMetricsFactory, maxStreams: Int = 8
    ) -> StreamRuntime {
        StreamRuntime(
            writer: RecordingFunnel(),
            metrics: MMStreamMetrics(factory: factory),
            maxConcurrentStreams: maxStreams,
            logger: .init(label: "test")
        )
    }

    private func run(_ plan: StreamRuntime.OpenPlan) async {
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
        }
    }

    @Test("a server-stream open, its items, and its graceful end advance opened/itemsOut/ended")
    func serverStreamCounters() async {
        let factory = CapturingMetricsFactory()
        let runtime = self.makeRuntime(factory: factory)
        let route = Handle(
            ServerStreamMethod<MetricsReq, Int, MetricsAck>(name: "m.watch", access: .read)
        ) { _, sink, _ in
            for value in 0..<3 { _ = await sink.send(value) }
            return .success(MetricsAck(count: 3))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 1, route: route, params: metricsOpenParams(), context: makeContext(),
                framesDropped: metricsDropped()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await self.run(plan)
        #expect(factory.total("mm_server_streams_opened_total") == 1)
        #expect(factory.total("mm_server_stream_items_out_total") == 3)
        #expect(factory.total("mm_server_streams_ended_total") == 1)
        #expect(factory.total("mm_server_stream_violations_total") == 0)
    }

    @Test("an over-cap open advances overCap and emits no opened")
    func overCapCounter() async {
        let factory = CapturingMetricsFactory()
        let runtime = self.makeRuntime(factory: factory, maxStreams: 1)
        let release = AsyncRelease()
        let route = Handle(
            ServerStreamMethod<MetricsReq, Int, MetricsAck>(name: "m.hold", access: .read)
        ) { _, _, _ in
            await release.wait()
            return .success(MetricsAck(count: 0))
        }
        guard
            let plan1 = await runtime.openStream(
                msgid: 1, route: route, params: metricsOpenParams(), context: makeContext(),
                framesDropped: metricsDropped()
            )
        else {
            Issue.record("first open accepted")
            return
        }
        let plan2 = await runtime.openStream(
            msgid: 2, route: route, params: metricsOpenParams(), context: makeContext(),
            framesDropped: metricsDropped()
        )
        #expect(plan2 == nil)
        #expect(factory.total("mm_server_streams_over_cap_total") == 1)
        #expect(factory.total("mm_server_streams_opened_total") == 1)  // only the first
        await withDiscardingTaskGroup { group in
            group.addTask { await plan1.run() }
            group.addTask { await release.release() }
        }
    }

    @Test("a seq-gap violation advances the violations counter")
    func violationCounter() async {
        let factory = CapturingMetricsFactory()
        let runtime = self.makeRuntime(factory: factory)
        let route = Handle(
            ClientStreamMethod<MetricsReq, Int, MetricsAck>(name: "m.import", access: .write)
        ) { _, elements, _ in
            var count = 0
            for await _ in elements { count += 1 }
            return .success(MetricsAck(count: count))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 1, route: route, params: metricsOpenParams(), context: makeContext(),
                framesDropped: metricsDropped()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                let item = try! MMPackEncoder().encode(1).get()
                await runtime.route(
                    .item(msgid: 1, seq: 0, item: item), framesDropped: metricsDropped())
                // Gap → violation.
                await runtime.route(
                    .item(msgid: 1, seq: 2, item: item), framesDropped: metricsDropped())
            }
        }
        #expect(factory.total("mm_server_stream_violations_total") == 1)
        #expect(factory.total("mm_server_stream_items_in_total") == 1)  // only seq 0 delivered
    }

    @Test("a client CANCEL advances the cancelled counter")
    func cancelCounter() async {
        let factory = CapturingMetricsFactory()
        let runtime = self.makeRuntime(factory: factory)
        let started = AsyncRelease()
        let route = Handle(
            ClientStreamMethod<MetricsReq, Int, MetricsAck>(name: "m.import", access: .write)
        ) { _, elements, _ in
            await started.release()
            for await _ in elements {}
            return .success(MetricsAck(count: 0))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 1, route: route, params: metricsOpenParams(), context: makeContext(),
                framesDropped: metricsDropped()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                await started.wait()
                await runtime.route(.cancel(msgid: 1), framesDropped: metricsDropped())
            }
        }
        #expect(factory.total("mm_server_streams_cancelled_total") == 1)
    }

    @Test("a response send parking at zero credit advances the credit-stall counter")
    func creditStallCounter() async {
        let factory = CapturingMetricsFactory()
        let runtime = self.makeRuntime(factory: factory)
        let sentNine = AsyncRelease()
        let route = Handle(
            ServerStreamMethod<MetricsReq, Int, MetricsAck>(name: "m.push", access: .read)
        ) { _, sink, _ in
            for value in 0..<9 { _ = await sink.send(value) }  // the 9th parks
            await sentNine.release()
            return .success(MetricsAck(count: 9))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 1, route: route, params: metricsOpenParams(), context: makeContext(),
                framesDropped: metricsDropped()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000)
                await runtime.route(.credit(msgid: 1, credits: 1), framesDropped: metricsDropped())
                await sentNine.wait()
            }
        }
        // The 9th send parked once at zero credit.
        #expect(factory.total("mm_server_stream_credit_stalls_total") == 1)
    }
}

private func metricsDropped() -> Counter {
    Counter(label: "mm_test_metrics_dropped_total")
}

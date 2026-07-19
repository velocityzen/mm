import Logging
import MMTestSupport
import NIOConcurrencyHelpers
import ServiceLifecycle
import Testing

@testable import MMServer

/// A minimal recording service: notes that it ran, then parks until cancelled
/// or shut down (like any long-running daemon component).
private struct RecordingService: Service {
    let started: ServiceReadiness
    let ran: NIOLockedValueBox<Bool>

    func run() async throws {
        ran.withLockedValue { $0 = true }
        started.signalReady()
        try await gracefulShutdown()
    }
}

@Suite("ServiceReadiness: startup ordering on top of ServiceLifecycle")
struct ReadinessTests {
    @Test("signal before wait returns immediately")
    func signalFirst() async throws {
        let readiness = ServiceReadiness()
        readiness.signalReady()
        #expect(readiness.isReady)
        try await readiness.waitUntilReady()  // must not park
    }

    @Test("one signal releases every waiter")
    func multiWaiter() async throws {
        let readiness = ServiceReadiness()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await readiness.waitUntilReady() }
            }
            readiness.signalReady()
            try await group.waitForAll()
        }
    }

    @Test("a cancelled waiter throws CancellationError instead of parking forever")
    func cancelledWaiter() async {
        let readiness = ServiceReadiness()
        let task = Task {
            try await readiness.waitUntilReady()
        }
        task.cancel()
        let outcome = await task.result
        guard case .failure(is CancellationError) = outcome else {
            Issue.record("cancelled waiter must throw CancellationError, got \(outcome)")
            return
        }
        // The signal still works afterwards; no leaked state.
        readiness.signalReady()
        #expect(readiness.isReady)
    }

    @Test("GatedService: the wrapped service cannot start before readiness fires")
    func gateHoldsUntilReady() async throws {
        let gate = ServiceReadiness()
        let started = ServiceReadiness()
        let ran = NIOLockedValueBox(false)
        let gated = GatedService(after: gate, run: RecordingService(started: started, ran: ran))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Runs under a cancellation umbrella so the parked wrapped
                // service can be torn down at test end.
                try? await gated.run()
            }
            // Structurally race-free: the wrapped service can only start
            // after `gate` fires, and nothing has fired it.
            #expect(ran.withLockedValue { $0 } == false)
            gate.signalReady()
            try await started.waitUntilReady()
            #expect(ran.withLockedValue { $0 } == true)
            group.cancelAll()
        }
    }

    @Test("graceful shutdown while gated exits cleanly; the wrapped service never runs")
    func shutdownWhileGated() async throws {
        let gate = ServiceReadiness()  // never fired
        let ran = NIOLockedValueBox(false)
        let gated = GatedService(
            after: gate, run: RecordingService(started: ServiceReadiness(), ran: ran))
        // An ungated sentinel proves the group is actually running before the
        // shutdown trigger fires (trigger-before-run is a different error).
        let groupRunning = ServiceReadiness()
        let sentinel = RecordingService(started: groupRunning, ran: NIOLockedValueBox(false))
        var logger = Logger(label: "test.readiness")
        logger.logLevel = .error
        let group = ServiceGroup(
            configuration: .init(
                services: [.init(service: sentinel), .init(service: gated)], logger: logger)
        )
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            try await groupRunning.waitUntilReady()
            await group.triggerGracefulShutdown()
            // The group's drain must not hang on the gated waiter.
            try await tasks.waitForAll()
        }
        #expect(ran.withLockedValue { $0 } == false)
    }

    @Test("multiple dependencies: the gate opens only after all of them")
    func multipleDependencies() async throws {
        let first = ServiceReadiness()
        let second = ServiceReadiness()
        let started = ServiceReadiness()
        let ran = NIOLockedValueBox(false)
        let gated = GatedService(
            after: first, second, run: RecordingService(started: started, ran: ran))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try? await gated.run() }
            first.signalReady()
            #expect(ran.withLockedValue { $0 } == false)  // still gated on `second`
            second.signalReady()
            try await started.waitUntilReady()
            #expect(ran.withLockedValue { $0 } == true)
            group.cancelAll()
        }
    }

    @Test("the Ready builder part composes with an explicit OnBind")
    func readyPartComposition() {
        let readiness = ServiceReadiness()
        let bindObserved = NIOLockedValueBox(false)
        let service = MMService {
            Configuration(endpoint: .unix(path: "/tmp/readiness-part.sock"))
            ACLProvider(InMemoryACLProvider())
            OnBind { _ in bindObserved.withLockedValue { $0 = true } }
            Ready(readiness)
        }
        _ = service
        // Assembly-level check only (no bind happens here); the end-to-end
        // firing is covered by the integration test over a real socket.
        #expect(!readiness.isReady)
    }
}

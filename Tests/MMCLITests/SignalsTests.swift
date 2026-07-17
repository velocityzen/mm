import Synchronization
import Testing

@testable import MMCLI

@Suite("MMCLISignals: the no-signal path")
struct SignalsTests {
    @Test("body's value comes back and no handler fires without a signal")
    func noSignal() async throws {
        let firstFired = Mutex(false)
        let value = try await MMCLISignals.withGracefulSigint(
            onFirst: { firstFired.withLock { $0 = true } }
        ) {
            42
        }
        #expect(value == 42)
        #expect(firstFired.withLock { $0 } == false)
    }

    @Test("a body error propagates")
    func bodyError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await MMCLISignals.withGracefulSigint(onFirst: {}) {
                throw Boom()
            }
        }
    }
}

import Logging
import MMServer
import MMTestSupport
import Testing

/// The metadata provider that carries connection ids into application handler
/// log lines (the transport binds the task-local around each connection task).
@Suite("Log context metadata provider")
struct LogContextTests {
    @Test("emits the bound connection id, and nothing when unbound")
    func providerFollowsTaskLocal() {
        #expect(MMLogContext.metadataProvider.get().isEmpty)
        let metadata = MMLogContext.$connectionID.withValue(42) {
            MMLogContext.metadataProvider.get()
        }
        #expect(metadata == ["connection": "42"])
        #expect(MMLogContext.metadataProvider.get().isEmpty)
    }
}

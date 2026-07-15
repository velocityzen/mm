import Testing

@testable import MMClient
@testable import MMServer

@Suite("Integration scaffold")
struct IntegrationScaffoldTests {
    @Test("server and client modules link together")
    func scaffold() {
        let router = Router(aclProvider: InMemoryACLProvider()) {}
        #expect(router.signatures.isEmpty)
        #expect(MMClientConfiguration().maxInFlightCalls == 16)
    }
}

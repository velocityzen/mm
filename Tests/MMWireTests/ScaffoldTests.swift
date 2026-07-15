import Testing

@testable import MMWire

@Suite("MMWire scaffold")
struct MMWireScaffoldTests {
    @Test("module compiles and links")
    func scaffold() {
        #expect(MMWireInfo.protocolVersion == 1)
    }
}

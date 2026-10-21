import MMSchema
import MMWire
import NIOCore
import Testing

/// The discovery payload examples of the wire spec (sections 8.2 and 8.3),
/// pinned through the same coder the server and client use.
@Suite("Discovery wire vectors")
struct DiscoveryWireVectorTests {
    @Test("server.entity response {owner 1000, group 100, mode 0o750} (spec 8.2)")
    func entityResponseVector() {
        let vector = "8300cd03e8016402cd01e8"
        let response = StatResponse(owner: 1000, group: 100, mode: 0o750)
        #expect(MMPackEncoder().encode(response).map(mpHex) == .success(vector))
        #expect(MMPackDecoder().decode(StatResponse.self, from: mpBytes(vector)) == .success(response))
    }

    @Test("TypeSchema optional(string) and bare string (spec 8.3)")
    func typeSchemaVectors() {
        let optionalString = TypeSchema.optional(.string)
        #expect(MMPackEncoder().encode(optionalString).map(mpHex) == .success("82000701810005"))
        #expect(
            MMPackDecoder().decode(TypeSchema.self, from: mpBytes("82000701810005"))
                == .success(optionalString))
        #expect(MMPackEncoder().encode(TypeSchema.string).map(mpHex) == .success("810005"))
        #expect(MMPackDecoder().decode(TypeSchema.self, from: mpBytes("810005")) == .success(.string))
    }
}

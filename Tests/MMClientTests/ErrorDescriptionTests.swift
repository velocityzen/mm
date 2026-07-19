import MMWire
import NIOCore
import Testing

@testable import MMClient

/// The three error layers render log-ready one-liners: the wire `MMError`
/// (data both sides exchange), the per-call verdict, and the
/// connection-lifecycle error.
@Suite("Error descriptions")
struct ErrorDescriptionTests {
    @Test("MMError renders code, message, and opaque payload size")
    func error() {
        #expect(
            MMError(code: 64, message: "journal is read-only").description
                == "code 64: journal is read-only"
        )
        #expect(
            MMError(code: 70, message: "busy", payload: ByteBuffer(bytes: [0xc0]))
                .description == "code 70: busy (payload: 1 bytes)"
        )
    }

    @Test("MMCallError renders one-liners; wire objects render through their own description")
    func callError() {
        #expect(MMCallError.denied.description == "permission denied")
        #expect(MMCallError.connectionClosed.description == "connection closed")
        #expect(MMCallError.transport(description: "boom").description == "transport failure: boom")
        #expect(
            MMCallError.remote(MMError(code: 64, message: "nope")).description
                == "remote error (code 64: nope)"
        )
        #expect("\(MMCallError.cancelled)" == "cancelled")
    }

    @Test("MMClientError renders one-liners")
    func clientError() {
        #expect(MMClientError.badHello.description == "server hello was malformed")
        #expect(
            MMClientError.versionUnsupported(serverVersion: 0).description
                == "server protocol version 0 is unsupported"
        )
        #expect(
            MMClientError.protocolViolation(description: "bad frame").description
                == "protocol violation: bad frame"
        )
    }
}

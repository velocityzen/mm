import MMSchema
import NIOCore
import Testing

@testable import MMWire

/// The contract behind the declared-error vectors of the wire protocol's
/// section 6.2.
private enum Shelf: MethodNamespace {
    #schema("shelf") {
        Errors {
            Case("retired", exitCode: 10)
        }
        Error("Full", exitCode: 12) {
            Field("capacity", .int)
        }
        Call("put") {
            Access { .write }
            Errors {
                Case(.reference("Full"))
            }
        }
    }
}

/// The error object's wire form.
private func wireHex(_ error: MMError) throws -> String {
    var buffer = ByteBuffer()
    try #require(error.encode(into: &buffer).mpSuccess != nil)
    return mpHex(buffer)
}

/// A code-64 error whose payload is the given bytes.
private func declared(payload hex: String) -> MMError {
    MMError(code: MMError.declaredErrorCode, message: "x", payload: mpBytes(hex))
}

@Suite("Declared errors on the wire")
struct DeclaredErrorWireTests {
    @Test("the section 6.2 vectors: code 64, the case as message, the union as payload")
    func vectors() throws {
        let full = try #require(
            MMError.declaring(Shelf.PutError.full(Shelf.Full(capacity: 10_000))).mpSuccess
        )
        #expect(try wireHex(full) == "9340a466756c6c8200a466756c6c018100cd2710")
        let retired = try #require(MMError.declaring(Shelf.PutError.retired).mpSuccess)
        #expect(try wireHex(retired) == "9340a7726574697265648100a772657469726564")
    }

    @Test("the vectors decode back to the cases they carry")
    func decodeVectors() throws {
        var full = mpBytes("9340a466756c6c8200a466756c6c018100cd2710")
        let fullError = try #require(MMError.decode(from: &full).mpSuccess)
        #expect(
            fullError.declared(as: Shelf.PutError.self) == .full(Shelf.Full(capacity: 10_000))
        )
        var retired = mpBytes("9340a7726574697265648100a772657469726564")
        let retiredError = try #require(MMError.decode(from: &retired).mpSuccess)
        #expect(retiredError.declared(as: Shelf.PutError.self) == .retired)
        #expect(retiredError.declared(as: Shelf.Error.self) == .retired)
    }

    @Test("cases match by name: key order and a case's place in the contract don't matter")
    func matchedByName() {
        // {1: {0: 5}, 0: "full"}
        #expect(
            declared(payload: "8201810005" + "00a466756c6c").declared(as: Shelf.PutError.self)
                == .full(Shelf.Full(capacity: 5))
        )
    }

    @Test("a case the receiver does not know is unknown, keeping its name")
    func unknownCase() {
        // {0: "melted", 1: {0: 9}}
        let melted = declared(payload: "8200a66d656c74656401810009")
        #expect(melted.declared(as: Shelf.PutError.self) == .unknown("melted"))
        // `full` is put's, not the namespace's.
        let full = declared(payload: "8200a466756c6c018100cd2710")
        #expect(full.declared(as: Shelf.Error.self) == .unknown("full"))
    }

    @Test("another code, no payload, or a payload that is no union is no declared error")
    func notDeclared() {
        let payload = mpBytes("8100a772657469726564")
        #expect(
            MMError(code: 65, message: "retired", payload: payload)
                .declared(as: Shelf.PutError.self) == nil
        )
        #expect(
            MMError(code: MMError.declaredErrorCode, message: "retired")
                .declared(as: Shelf.PutError.self) == nil
        )
        #expect(declared(payload: "a772657469726564").declared(as: Shelf.PutError.self) == nil)
        // {1: {}}: no case name.
        #expect(declared(payload: "810180").declared(as: Shelf.PutError.self) == nil)
    }
}

import Foundation
import MMSchema
import MMWire
import NIOCore
import Testing

/// A union and declared errors whose cases gained fields after a writer
/// whose cases had none, which leaves key 1 out: cases whose fields are all
/// optional or have a default, and cases that still need a field.
private enum Relocation: MethodNamespace {
    #schema("relocation") {
        Type("Room") {
            Field("seats", .optional(.int))
            Field("name", .string, default: "hall")
        }
        Type("Desk") {
            Field("row", .int)
        }
        Error("Late", exitCode: 15) {
            Field("since", .optional(.date))
        }
        Union("Move") {
            Case("moved") {
                Field("to", .optional(.string))
            }
            Case("bumped") {
                Field("by", .int, default: 1)
                Field("note", .optional(.string))
            }
            Case("placed") {
                Field("at", .string)
            }
            Case("mixed") {
                Field("to", .optional(.string))
                Field("at", .string)
            }
            Case("kept")
        }
        Call("shift") {
            Access { .write }
            Request {
                Field("move", "Move")
            }
            Errors {
                Case(.reference("Late"))
                Case("busy", exitCode: 10) {
                    Field("retryAfter", .optional(.duration))
                    Field("tries", .int, default: 3)
                }
                Case("crowded", .reference("Room"), exitCode: 11)
                Case("blocked", .reference("Desk"), exitCode: 12)
                Case("pinned", exitCode: 13) {
                    Field("by", .string)
                }
            }
        }
    }
}

/// A union value that carries only its tag, `{0: tag}`.
private func tagOnly(_ tag: String) -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.writeMessagePackMapHeader(count: 1)
    buffer.writeMessagePackInt(0)
    buffer.writeMessagePackString(tag)
    return buffer
}

private func decodedThroughCodable<T: Decodable>(
    _ type: T.Type,
    from buffer: ByteBuffer
) -> Result<T, MMWireError> {
    MMPackDecoder().decode(type, from: buffer)
}

private func decodedThroughGeneratedCode<T: MMPackDecodable>(
    _ type: T.Type,
    from buffer: ByteBuffer
) -> Result<T, MMWireError> {
    MMPackDecoder().decode(type, from: buffer)
}

/// The declared error a peer sends for the union value in `payload`.
private func declaredError(_ payload: ByteBuffer) -> Relocation.ShiftError? {
    MMError(code: MMError.declaredErrorCode, message: "x", payload: payload)
        .declared(as: Relocation.ShiftError.self)
}

@Suite("Union cases without their fields map")
struct AbsentUnionFieldsTests {
    @Test("the old moved case decodes as moved with no destination, on both paths")
    func movedWithoutFields() throws {
        // {0: "moved"}: what a writer whose `moved` had no fields sends.
        let bytes = mpBytes("8100a56d6f766564")
        #expect(
            try decodedThroughCodable(Relocation.Move.self, from: bytes).get() == .moved(to: nil)
        )
        #expect(
            try decodedThroughGeneratedCode(Relocation.Move.self, from: bytes).get()
                == .moved(to: nil)
        )
    }

    @Test("a field with a default reads it, an optional one reads nil, on both paths")
    func defaultsWithoutFields() throws {
        let bytes = tagOnly("bumped")
        let expected = Relocation.Move.bumped(by: 1, note: nil)
        #expect(try decodedThroughCodable(Relocation.Move.self, from: bytes).get() == expected)
        #expect(
            try decodedThroughGeneratedCode(Relocation.Move.self, from: bytes).get() == expected
        )
    }

    @Test("a case with a required field still fails without the map, on both paths")
    func requiredWithoutFields() {
        for tag in ["placed", "mixed"] {
            let bytes = tagOnly(tag)
            #expect(
                decodedThroughCodable(Relocation.Move.self, from: bytes)
                    == .failure(.keyNotFound(key: "1")),
                "\(tag)"
            )
            #expect(
                decodedThroughGeneratedCode(Relocation.Move.self, from: bytes)
                    == .failure(.keyNotFound(key: "1")),
                "\(tag)"
            )
        }
    }

    @Test("entries a newer writer adds don't stand in for the map")
    func extraEntries() throws {
        // {0: "moved", 2: "later", "at": "x"}.
        var bytes = ByteBuffer()
        bytes.writeMessagePackMapHeader(count: 3)
        bytes.writeMessagePackInt(0)
        bytes.writeMessagePackString("moved")
        bytes.writeMessagePackInt(2)
        bytes.writeMessagePackString("later")
        bytes.writeMessagePackString("at")
        bytes.writeMessagePackString("x")
        #expect(
            try decodedThroughCodable(Relocation.Move.self, from: bytes).get() == .moved(to: nil)
        )
        #expect(
            try decodedThroughGeneratedCode(Relocation.Move.self, from: bytes).get()
                == .moved(to: nil)
        )
    }

    @Test("a map that is there is still read")
    func presentFields() throws {
        // {0: "moved", 1: {0: "hall"}}.
        var bytes = ByteBuffer()
        bytes.writeMessagePackMapHeader(count: 2)
        bytes.writeMessagePackInt(0)
        bytes.writeMessagePackString("moved")
        bytes.writeMessagePackInt(1)
        bytes.writeMessagePackMapHeader(count: 1)
        bytes.writeMessagePackInt(0)
        bytes.writeMessagePackString("hall")
        #expect(
            try decodedThroughCodable(Relocation.Move.self, from: bytes).get() == .moved(to: "hall")
        )
        #expect(
            try decodedThroughGeneratedCode(Relocation.Move.self, from: bytes).get()
                == .moved(to: "hall")
        )
    }

    @Test("JSON without fields reads the same way")
    func json() throws {
        let decoder = JSONDecoder()
        #expect(
            try decoder.decode(Relocation.Move.self, from: Data(#"{"case":"moved"}"#.utf8))
                == .moved(to: nil)
        )
        #expect(
            try decoder.decode(Relocation.Move.self, from: Data(#"{"case":"bumped"}"#.utf8))
                == .bumped(by: 1, note: nil)
        )
        #expect(throws: DecodingError.self) {
            try decoder.decode(Relocation.Move.self, from: Data(#"{"case":"placed"}"#.utf8))
        }
    }

    @Test("a declared error without its fields reads them as absent")
    func declaredErrors() {
        #expect(declaredError(tagOnly("late")) == .late(Relocation.Late(since: nil)))
        #expect(declaredError(tagOnly("busy")) == .busy(retryAfter: nil, tries: 3))
        #expect(
            declaredError(tagOnly("crowded")) == .crowded(Relocation.Room(seats: nil, name: "hall"))
        )
    }

    @Test("a declared error that needs a field is not read without its fields")
    func declaredErrorsWithRequiredFields() {
        #expect(declaredError(tagOnly("blocked")) == nil)
        #expect(declaredError(tagOnly("pinned")) == nil)
    }
}

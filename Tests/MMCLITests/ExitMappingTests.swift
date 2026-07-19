import ArgumentParser
import MMClient
import MMSchema
import MMTestSupport
import MMWire
import Testing

@testable import MMCLI

@Suite("MMCLIFailure: error → exit code mapping")
struct ExitMappingTests {
    @Test(
        "each call error maps to its documented exit code",
        arguments: [
            (MMCallError.denied, Int32(77)),
            (MMCallError.unknownMethod, Int32(64)),
            (MMCallError.malformedParams, Int32(65)),
            (MMCallError.remote(MMError(code: 64, message: "nope")), Int32(1)),
            (MMCallError.remoteInternal, Int32(70)),
            (MMCallError.streamViolation(MMError(code: 6, message: "gap")), Int32(70)),
            (MMCallError.encode(.encodingFailed(description: "x")), Int32(70)),
            (MMCallError.decode(.truncated), Int32(70)),
            (MMCallError.tooManyInFlight, Int32(70)),
            (MMCallError.transport(description: "reset"), Int32(69)),
            (MMCallError.connectionClosed, Int32(69)),
            (MMCallError.cancelled, Int32(130)),
        ]
    )
    func codes(error: MMCallError, expected: Int32) {
        #expect(MMCLIFailure.code(for: error) == ExitCode(expected))
    }

    @Test("unknownMethod message points at discover")
    func unknownMethodMessage() {
        let message = MMCLIFailure.message(
            for: .unknownMethod, method: "journal.zap", entity: "journal.notes")
        #expect(message.contains("journal.zap"))
        #expect(message.contains("try `discover`"))
    }

    @Test("remote errors render code and message")
    func remoteMessage() {
        let message = MMCLIFailure.message(
            for: .remote(MMError(code: 70, message: "boom")),
            method: "journal.append", entity: "journal.notes")
        #expect(message == "error 70: boom")
    }

    @Test("denied names the method and entity")
    func deniedMessage() {
        let message = MMCLIFailure.message(
            for: .denied, method: "journal.append", entity: "journal.system")
        #expect(message == "denied: journal.append on journal.system")
    }

    @Test("unwrap passes a success through untouched")
    func unwrapSuccess() throws {
        let value = try MMCLIFailure.unwrap(
            Result<Int, MMCallError>.success(7), method: "m", entity: "e")
        #expect(value == 7)
    }

    @Test("unwrap throws the mapped ExitCode on failure")
    func unwrapFailure() {
        #expect(throws: ExitCode(77)) {
            try MMCLIFailure.unwrap(
                Result<Int, MMCallError>.failure(.denied),
                method: "journal.append", entity: "journal.system")
        }
    }

    @Test("entity parses a valid dotted name")
    func entityValid() throws {
        let name = try MMCLIFailure.entity("journal.notes")
        #expect(name.rawValue == "journal.notes")
    }

    @Test("entity turns a parse failure into a ValidationError", arguments: ["a..b", "Bad", "a."])
    func entityInvalid(raw: String) {
        #expect(throws: ValidationError.self) {
            try MMCLIFailure.entity(raw)
        }
    }
}

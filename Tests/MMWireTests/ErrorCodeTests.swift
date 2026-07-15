import Testing

@testable import MMWire

@Suite("MMErrorCode wire enum")
struct ErrorCodeTests {
    @Test("known codes round-trip")
    func knownCodes() {
        let known: [(Int, MMErrorCode)] = [
            (1, .unknownMethod), (2, .permissionDenied), (3, .malformedParams),
            (4, .tooManyInFlight), (5, .internalError), (6, .streamViolation),
            (7, .cancelled),
        ]
        for (raw, expected) in known {
            #expect(MMErrorCode(code: raw) == expected)
            #expect(expected.code == raw)
        }
    }

    @Test("unrecognized codes decode as unknown and round-trip the raw value")
    func unknownCodes() {
        for raw in [0, 8, 63, 64, 1000, -1, Int.max] {
            let code = MMErrorCode(code: raw)
            #expect(code == .unknown(code: raw))
            #expect(code.code == raw)
        }
    }
}

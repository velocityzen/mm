import Testing

@testable import MMCLI

/// Shaped exactly like a macro-generated wire enum: String-raw with an
/// `unknown` forward-compatibility fallback.
private enum Priority: String, CaseIterable, MMCLIEnumArgument {
    case low
    case urgent
    case unknown
}

@Suite("MMCLIEnumArgument: the unknown fallback stays out of the CLI")
struct EnumArgumentTests {
    @Test("allValueStrings lists every case except unknown")
    func valueStrings() {
        #expect(Priority.allValueStrings == ["low", "urgent"])
    }

    @Test("unknown is refused as an argument")
    func refusesUnknown() {
        #expect(Priority(argument: "unknown") == nil)
    }

    @Test("real cases parse by raw value")
    func parsesRealCases() {
        #expect(Priority(argument: "low") == .low)
        #expect(Priority(argument: "urgent") == .urgent)
        #expect(Priority(argument: "URGENT") == nil)
        #expect(Priority(argument: "bogus") == nil)
    }
}

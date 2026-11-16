import MMTestSupport
import Testing

@testable import MMCLI

/// Shaped exactly like a macro-generated wire enum: String-raw, with an
/// `unknown(String)` fallback that `allCases` leaves out and
/// `init(rawValue:)` never makes.
private enum Priority: RawRepresentable, Hashable, CaseIterable, MMCLIEnumArgument {
    case low
    case urgent
    case unknown(String)

    init?(rawValue: String) {
        switch rawValue {
            case "low": self = .low
            case "urgent": self = .urgent
            default: return nil
        }
    }

    var rawValue: String {
        switch self {
            case .low: "low"
            case .urgent: "urgent"
            case .unknown(let raw): raw
        }
    }

    static var allCases: [Priority] { [.low, .urgent] }
}

@Suite("MMCLIEnumArgument: the unknown fallback stays out of the CLI")
struct EnumArgumentTests {
    @Test("allValueStrings lists the declared cases")
    func valueStrings() {
        #expect(Priority.allValueStrings == ["low", "urgent"])
    }

    @Test("unknown and other undeclared values are refused as an argument")
    func refusesUnknown() {
        #expect(Priority(argument: "unknown") == nil)
        #expect(Priority(argument: "later") == nil)
    }

    @Test("real cases parse by raw value")
    func parsesRealCases() {
        #expect(Priority(argument: "low") == .low)
        #expect(Priority(argument: "urgent") == .urgent)
        #expect(Priority(argument: "URGENT") == nil)
        #expect(Priority(argument: "bogus") == nil)
    }
}

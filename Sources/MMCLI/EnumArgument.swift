import ArgumentParser
import MMSchema

/// CLI conformance for macro-generated wire enums:
/// `extension Journal.Priority: MMCLIEnumArgument {}` is all a generated
/// command needs to accept the enum as an argument.
///
/// Generated wire enums are `String`-raw (case name = wire value) and carry
/// an `unknown` fallback case for forward compatibility. That case is a
/// decoding artifact, never a value a caller may send, so this protocol's
/// defaults hide it from help/completions and refuse it as input.
/// The calendar/clock kinds as typed command arguments: parsed by the value
/// types' own strict ISO parsers, so a generated `Field("day", .date)`
/// becomes a plain `--day 2026-07-21` option.
extension MMDate: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(argument)
    }
}

extension MMDateTime: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(argument)
    }
}

extension MMTimestamp: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(argument)
    }
}

public protocol MMCLIEnumArgument: ExpressibleByArgument, RawRepresentable, CaseIterable
where RawValue == String {}

extension MMCLIEnumArgument {
    /// Every case except the `unknown` fallback — what help text and shell
    /// completions list.
    public static var allValueStrings: [String] {
        Self.allCases.map(\.rawValue).filter { $0 != "unknown" }
    }

    /// Parses via `init(rawValue:)`, refusing the `unknown` fallback so it
    /// cannot be smuggled onto the wire from the command line.
    public init?(argument: String) {
        guard argument != "unknown" else { return nil }
        self.init(rawValue: argument)
    }
}

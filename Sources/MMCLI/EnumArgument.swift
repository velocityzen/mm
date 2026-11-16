import ArgumentParser
import MMSchema

/// CLI conformance for macro-generated wire enums:
/// `extension Journal.Priority: MMCLIEnumArgument {}` is all a generated
/// command needs to accept the enum as an argument.
///
/// Generated wire enums are `String`-raw (case name = wire value) and carry
/// an `unknown(String)` fallback for values their contract does not declare.
/// It is never in `allCases`, and `init(rawValue:)` returns nil for any value
/// but a declared case's, so help and completions list the declared cases and
/// the command line takes only those.
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

/// Raw bytes as a typed command argument: base64 text, so a generated
/// `Field("blob", .bytes)` becomes a `--blob AAEC` option.
extension MMBytes: ExpressibleByArgument {
    public init?(argument: String) {
        guard let bytes = SchemaValue.decodeBase64(argument) else { return nil }
        self.init(bytes)
    }
}

public protocol MMCLIEnumArgument: ExpressibleByArgument, RawRepresentable, CaseIterable
where RawValue == String {
    /// The deprecated cases' names, each with why it is deprecated (empty
    /// when the contract gives no reason). Parsing one warns.
    static var deprecatedValues: [String: String] { get }
}

extension MMCLIEnumArgument {
    /// No deprecated cases.
    public static var deprecatedValues: [String: String] { [:] }

    /// The declared cases — what help text and shell completions list.
    public static var allValueStrings: [String] {
        Self.allCases.map(\.rawValue)
    }

    /// Parses via `init(rawValue:)`, which takes only a declared case's
    /// name, warning on stderr when the case is deprecated.
    public init?(argument: String) {
        guard let value = Self(rawValue: argument) else { return nil }
        if let deprecation = Self.deprecatedValues[argument] {
            MMCLIOutput.warn(
                deprecation.isEmpty
                    ? "\(argument) is deprecated" : "\(argument) is deprecated: \(deprecation)"
            )
        }
        self = value
    }
}

/// CLI conformance for macro-generated named scalars (`Alias`):
/// `extension Journal.Slug: MMCLIAliasArgument {}` lets a generated command
/// take the alias as a typed argument, parsed as its scalar. Its constraints
/// are checked where a request's are, not while parsing.
public protocol MMCLIAliasArgument: ExpressibleByArgument, RawRepresentable
where RawValue: ExpressibleByArgument {}

extension MMCLIAliasArgument {
    /// Parses the scalar, then wraps it.
    public init?(argument: String) {
        guard let rawValue = RawValue(argument: argument) else { return nil }
        self.init(rawValue: rawValue)
    }
}

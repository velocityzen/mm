/// The CLI presentation overlay: how a declared method surfaces as a
/// command-line subcommand when a top-level `CLI(.enabled)` entry makes
/// `#schema` generate a CLI.
///
/// Presentation only, by construction: the overlay is stored on
/// ``MethodDeclaration`` and consumed by the `#schema` macro at expansion —
/// it is never forwarded into ``MethodSignature``, never served by discovery,
/// and can never affect the fingerprint or compatibility. A CLI rename is not
/// schema drift; the wire method name is untouched.
///
/// ```swift
/// Call("append", description: "Appends one line") {
///     CLI(.command("add", aliases: ["append"]))   // `mm journal add`
///     Access { .write }
///     Request { Field("line", .string, cli: .argument) }
///     Response { Field("count", .int) }
/// }
/// Call("compact") {
///     CLI(.omitted)                               // no command generated
///     ...
/// }
/// ```
public struct CLIOverlay: Sendable, Hashable {
    /// Command name override; `nil` uses the kebab-cased call name.
    public let commandName: String?
    /// Additional names the command answers to (swift-argument-parser aliases).
    public let aliases: [String]
    /// When true, no command is generated for this method.
    public let omitted: Bool
}

/// The argument to a ``CLI(_:)`` part — built from the static factories so the
/// declaration reads as data: `CLI(.omitted)`, `CLI(.command("add"))`.
public struct CLISpec: Sendable, Hashable {
    let overlay: CLIOverlay

    /// Generate no command for this method.
    public static let omitted = CLISpec(
        overlay: CLIOverlay(commandName: nil, aliases: [], omitted: true))

    /// Rename the generated command (and optionally add aliases). The wire
    /// method name is not affected.
    public static func command(_ name: String, aliases: [String] = []) -> CLISpec {
        precondition(!name.isEmpty, "CLI command names cannot be empty")
        return CLISpec(overlay: CLIOverlay(commandName: name, aliases: aliases, omitted: false))
    }
}

/// Declares the CLI presentation of the enclosing `Call`. At most one per
/// method; omit it entirely for the defaults (a command named after the call,
/// kebab-cased, every request field an option named after the field).
public func CLI(_ spec: CLISpec) -> MethodPart {
    MethodPart(kind: .cli(spec.overlay))
}

/// How one request field surfaces on the generated command. Passed as the
/// `cli:` argument of any ``Field`` form; `nil` (the default) is a `--name`
/// option, `--name <value>` styled by the field's wire type.
///
/// Like the ``CLIOverlay``, this is presentation metadata: it rides the DSL
/// `Field` value for the macro to read and is never part of the wire contract.
public struct CLIArgument: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case option(name: String?, short: CLIShort?)
        case argument
        case flag
        case omitted
    }

    let kind: Kind

    /// A positional argument, in field-declaration order after the entity.
    public static let argument = CLIArgument(kind: .argument)

    /// A `--flag` (the field must be `.bool`; the macro diagnoses otherwise).
    public static let flag = CLIArgument(kind: .flag)

    /// Excluded from the command (the field must be optional — the request
    /// still has to be constructible; the macro diagnoses otherwise).
    public static let omitted = CLIArgument(kind: .omitted)

    /// A renamed option, optionally with a single-character short form:
    /// `cli: .option("text", short: "t")` → `--text` / `-t`, or
    /// `cli: .option(short: .auto)` to derive the short from the long name's
    /// first character (ArgumentParser's `.shortAndLong`).
    public static func option(_ name: String? = nil, short: CLIShort? = nil) -> CLIArgument {
        CLIArgument(kind: .option(name: name, short: short))
    }
}

/// The short form of an option: a character literal (`short: "t"`) or
/// ``auto``, which derives the long name's first character — the equivalent
/// of swift-argument-parser's `.shortAndLong`.
public struct CLIShort: Sendable, Hashable, ExpressibleByExtendedGraphemeClusterLiteral {
    enum Kind: Sendable, Hashable {
        case character(Character)
        case derived
    }

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// Derive the short from the effective long name's first character:
    /// `--text` / `-t` without spelling the `t`.
    public static let auto = CLIShort(kind: .derived)

    public init(extendedGraphemeClusterLiteral value: Character) {
        self.kind = .character(value)
    }
}

/// Whether `#schema` generates a swift-argument-parser CLI alongside the
/// contract, declared as a top-level entry in the schema block:
/// `#schema("journal") { CLI(.enabled); ... }`. Off when the entry is
/// absent; enabling requires the expanding file to import `ArgumentParser`
/// and `MMCLI` (the generated commands reference both).
public struct SchemaCLIMode: Sendable, Hashable {
    let enabled: Bool
    /// Namespace command-name override; `nil` uses the schema prefix.
    let commandName: String?

    /// No CLI generation (the default).
    public static let disabled = SchemaCLIMode(enabled: false, commandName: nil)

    /// Generate a command group named after the schema prefix.
    public static let enabled = SchemaCLIMode(enabled: true, commandName: nil)

    /// Generate a command group with an overridden name.
    public static func enabled(command: String) -> SchemaCLIMode {
        precondition(!command.isEmpty, "CLI command names cannot be empty")
        return SchemaCLIMode(enabled: true, commandName: command)
    }
}

/// Declares the CLI generation mode of the enclosing schema — `CLI(.enabled)`
/// or `CLI(.enabled(command: "name"))` as a top-level entry next to `Call` /
/// `Enum` / `Type`. At most one per schema; omit it entirely (or pass
/// `.disabled`) for no CLI. Presentation-only, like the per-call overlay:
/// ignored by the runtime declaration, never served or fingerprinted.
public func CLI(_ mode: SchemaCLIMode) -> SchemaEntry {
    SchemaEntry(kind: .cli(mode))
}

/// The CLI presentation overlay: how a declared method surfaces as a
/// command-line subcommand when a top-level `CLI(.enabled)` entry marks the
/// `#schema` for CLI generation (by the `MMCLIGeneratorPlugin`).
///
/// Presentation only, by construction: the overlay is stored on
/// ``MethodDeclaration`` and consumed at build time (the `#schema` macro
/// validates it, the `MMCLIGeneratorPlugin` generates commands from it) —
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

/// ``CLI(_:)`` with options the generated command takes that never reach
/// the server: settings an `Input(...)` body reads its input with, such as a
/// delimiter or a column. They are declared like request fields, and the
/// body gets them as a typed `Options` value. Only on a call with a
/// `cli: .input` field (the macro diagnoses otherwise).
///
/// ```swift
/// Call("append") {
///     CLI(.command("add")) {
///         Field("urgentPrefix", .string, description: "Lines starting with this go urgent", default: "!")
///     }
///     Access { .write }
///     Request { Field("line", .string, cli: .input) }
/// }
/// ```
///
/// Each field is an option (renamed or short with `cli: .option(...)`) or,
/// for `.bool`, a flag (`cli: .flag`), with a flat shape: a scalar, a wire
/// enum, a calendar/clock kind, or an array of those. A required field is a
/// required option, unless it has a `default:`, which is its value when the
/// option is absent. An optional field's `default:` works as on a request
/// field: a bare `--name` means the default, and absent is nil.
///
/// Presentation only, like the spec: never served, fingerprinted, or
/// compared. An omitted command has no options to take.
public func CLI(_ spec: CLISpec, @SchemaFieldsBuilder _ options: () -> [Field]) -> MethodPart {
    precondition(!spec.overlay.omitted, "CLI(.omitted) takes no options: no command is generated")
    return CLI(spec)
}

/// ``CLI(_:_:)`` for a command that keeps its default name: only the options.
///
/// ```swift
/// CLI {
///     Field("column", .int, description: "Which column holds the query", default: 0)
/// }
/// ```
public func CLI(@SchemaFieldsBuilder _ options: () -> [Field]) -> MethodPart {
    MethodPart(kind: .cli(CLIOverlay(commandName: nil, aliases: [], omitted: false)))
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
        case input
        case flag
        case omitted
    }

    let kind: Kind

    /// A positional argument, in field-declaration order after the entity.
    public static let argument = CLIArgument(kind: .argument)

    /// A positional argument whose values can also come from an input: a
    /// file (`--input <path>`) or stdin (`--input -`), read as a byte stream.
    /// By default the command makes one call per line, with every other
    /// argument shared. An `Input(...)` entry in the tool's `MMCLI { }`
    /// block takes the stream and the call instead, and decides the work.
    /// One field per call at most, a required `.string`, and the call must
    /// not stream requests (stdin is theirs); the macro diagnoses otherwise.
    public static let input = CLIArgument(kind: .input)

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

/// Whether the schema gets a swift-argument-parser CLI, declared as a
/// top-level entry in the schema block:
/// `#schema("journal") { CLI(.enabled); ... }`. Off when the entry is
/// absent. The commands are generated by the `MMCLIGeneratorPlugin` build-tool
/// plugin applied to the command-line target (which depends on `MMCLI` and
/// `ArgumentParser`); the module declaring the schema needs neither.
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

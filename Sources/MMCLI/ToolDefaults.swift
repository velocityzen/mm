import ArgumentParser
import MMSchema
import MMWire

/// The tool's build-time defaults — the companion server's completeness
/// claim, its well-known endpoint, the default output format, and the
/// per-type text renderers. The declarative face is the
/// ``MMCLI(isolation:_:)`` block (``Contract(_:)``, ``Endpoint(_:)``, ...);
/// this type and ``withCLI(_:_:)`` are the value level underneath.
///
/// A task-local, not a process-global: both values are build-time knowledge
/// (a folded contract, a compiled-in socket path), so there is nothing to
/// mutate and nothing to lock. Reads anywhere in the command's task tree see
/// the binding, tests bind their own scopes without interfering, and an
/// unbound tool simply has no defaults — explicit `--socket`/`--tcp`, and
/// per-namespace scoped-diff verification.
public struct MMCLIDefaults: Sendable {
    /// The build-time completeness claim ``MMCLIRunner`` verifies against on
    /// every invocation; see ``MMCLIServerContract``.
    public var serverContract: MMCLIServerContract?
    /// The daemon's well-known endpoint, applied when a command omits
    /// `--socket`/`--tcp`. Explicit flags always win.
    public var endpoint: MMEndpoint?
    /// The tool's default output format, applied when a command omits
    /// `--output`. The explicit flag always wins; unbound tools default to
    /// ``OutputFormat/json``. Set ``OutputFormat/text`` for a human-first
    /// tool whose scripts opt into JSON with `--output json`.
    public var output: OutputFormat?
    /// The tool's per-type renderers for ``OutputFormat/text`` — built from
    /// ``Format(_:_:)`` entries, keyed by the rendered value's type (which
    /// is per-command: every response and stream element has its own
    /// generated type). Types without an entry render as compact JSON.
    public var formatters: MMCLIFormatters

    /// The binding commands read; empty unless the tool declared one via
    /// the ``MMCLI(isolation:_:)`` block (or bound it with ``withCLI(_:_:)``).
    @TaskLocal public static var current = MMCLIDefaults()

    public init(
        serverContract: MMCLIServerContract? = nil,
        endpoint: MMEndpoint? = nil,
        output: OutputFormat? = nil,
        formatters: MMCLIFormatters = MMCLIFormatters()
    ) {
        self.serverContract = serverContract
        self.endpoint = endpoint
        self.output = output
        self.formatters = formatters
    }
}

/// The tool's per-type text renderers, collected from ``Format(_:_:)``
/// entries (array-literal friendly):
///
/// ```swift
/// MMCLIDefaults(formatters: [
///     Format(ChangeEvent.self) { "\($0.count)\t\($0.line)" },
///     Format(Journal.ReadResponse.self) { $0.lines.joined(separator: "\n") },
/// ])
/// ```
///
/// Keying by value type is what makes formatting **per command**: every
/// generated response and stream element has its own type, so one entry
/// addresses exactly one command's output (or one stream's elements).
public struct MMCLIFormatters: Sendable, ExpressibleByArrayLiteral {
    var renderers: [ObjectIdentifier: @Sendable (Any) -> String?]

    public init() {
        self.renderers = [:]
    }

    public init(arrayLiteral elements: MMCLIFormatEntry...) {
        self.init(entries: elements)
    }

    init(entries: [MMCLIFormatEntry]) {
        self.renderers = Dictionary(
            entries.map { ($0.key, $0.render) },
            uniquingKeysWith: { _, second in second }
        )
    }

    /// The registered rendering of `value`, or nil when its type has no
    /// entry (the caller falls back to JSON).
    func render<T: Encodable>(_ value: T) -> String? {
        self.renderers[ObjectIdentifier(T.self)]?(value)
    }
}

/// One per-type text renderer; see ``MMCLIFormatters``.
public struct MMCLIFormatEntry: Sendable {
    let key: ObjectIdentifier
    let render: @Sendable (Any) -> String?
}

/// Declares how one type renders under `--output text`: the typed twin of a
/// row in ``MMCLIFormatters`` — no downcasting in user code, the erasure
/// lives here.
public func Format<T: Encodable>(
    _ type: T.Type,
    _ render: @Sendable @escaping (T) -> String
) -> MMCLIFormatEntry {
    MMCLIFormatEntry(
        key: ObjectIdentifier(T.self),
        render: { value in (value as? T).map(render) }
    )
}

/// ``Format(_:_:)`` with the rendered type inferred from the closure's
/// parameter — no metatype spelling, at the cost of naming and annotating
/// the parameter (there is nothing else to pin the type):
///
/// ```swift
/// Format { (event: ChangeEvent) in "\(event.count)\t\(event.line)" }
/// ```
public func Format<T: Encodable>(
    _ render: @Sendable @escaping (T) -> String
) -> MMCLIFormatEntry {
    Format(T.self, render)
}

// MARK: - The declarative entry point

/// One declaration in an ``MMCLI(isolation:_:)`` block: the root command's
/// shape, the claim, the endpoint, the default output, or a per-type text
/// renderer. Constructed by ``Configuration(_:)``, ``Contract(_:)``,
/// ``Endpoint(_:)``, ``Output(_:)``, and ``Format(_:_:)``.
public struct MMCLIPart: Sendable {
    enum Kind: Sendable {
        case configuration(CommandConfiguration)
        case name(String)
        case abstract(String)
        case commands([any ParsableCommand.Type])
        case version(String)
        case contract(MMCLIServerContract)
        case endpoint(MMEndpoint)
        case output(OutputFormat)
        case format(MMCLIFormatEntry)
    }

    let kind: Kind
}

/// Declares the root command's full `CommandConfiguration` — the escape
/// hatch for fields the sugar parts don't cover (`defaultSubcommand`,
/// `discussion`, aliases, ...). ``Name(_:)``, ``Abstract(_:)``,
/// ``Commands(_:)``, and ``Version(_:)`` merge onto it; declaring the same
/// field both ways is a programmer error. With any root-shape part present,
/// ``MMCLI(isolation:_:)`` synthesizes and runs the root itself — the whole
/// tool becomes one declaration, no `AsyncParsableCommand` root to write.
/// Root-shape parts are only meaningful in the `run:`-less form.
public func Configuration(_ configuration: CommandConfiguration) -> MMCLIPart {
    MMCLIPart(kind: .configuration(configuration))
}

/// Declares the tool's command name (omitted: the executable's name).
public func Name(_ name: String) -> MMCLIPart {
    MMCLIPart(kind: .name(name))
}

/// Declares the one-line abstract shown at the top of `--help`.
public func Abstract(_ text: String) -> MMCLIPart {
    MMCLIPart(kind: .abstract(text))
}

/// Declares the root's subcommands — generated groups (`Journal.Command`),
/// the schema-driven generics (``MMCLIDiscover``, ``MMCLIRawCall``), and any
/// hand-written commands alike.
public func Commands(_ commands: [any ParsableCommand.Type]) -> MMCLIPart {
    MMCLIPart(kind: .commands(commands))
}

/// Declares the tool's version — rendered by ArgumentParser's `--version`.
public func Version(_ version: String) -> MMCLIPart {
    MMCLIPart(kind: .version(version))
}

/// Declares the companion server's completeness claim; see
/// ``MMCLIServerContract``.
public func Contract(_ claim: MMCLIServerContract) -> MMCLIPart {
    MMCLIPart(kind: .contract(claim))
}

/// Declares the daemon's well-known endpoint — `--socket`/`--tcp` become
/// optional; explicit flags always win.
public func Endpoint(_ endpoint: MMEndpoint) -> MMCLIPart {
    MMCLIPart(kind: .endpoint(endpoint))
}

/// Declares the tool's default output format, applied when a command omits
/// `--output`.
public func Output(_ format: OutputFormat) -> MMCLIPart {
    MMCLIPart(kind: .output(format))
}

@resultBuilder
public enum MMCLIBuilder: MMListBuilding {
    public typealias Element = MMCLIPart

    public static func buildExpression(_ part: MMCLIPart) -> [MMCLIPart] {
        [part]
    }

    /// `Format(_:_:)` entries drop straight into the block.
    public static func buildExpression(_ entry: MMCLIFormatEntry) -> [MMCLIPart] {
        [MMCLIPart(kind: .format(entry))]
    }
}

/// The whole entry point of a companion CLI, declared as data — the CLI twin
/// of `MMService { ... }`. The block assembles the tool's build-time
/// defaults; `run:` executes inside their task-local binding (typically the
/// root command's own `main()`, with `@main` on a plain entry struct so
/// ArgumentParser's parse/dispatch/exit runs unchanged):
///
/// ```swift
/// @main
/// struct Main {
///     static func main() async {
///         await MMCLI {
///             Contract(.complete([journalContract]))
///             Endpoint(.unix(path: "/tmp/mm-example.sock"))
///             Format(ChangeEvent.self) { "\($0.count)\t\($0.line)" }
///         } run: {
///             await MMExampleCLI.main()
///         }
///     }
/// }
/// ```
///
/// Declaring ``Contract(_:)``, ``Endpoint(_:)``, or ``Output(_:)`` twice is a
/// programmer error caught at startup; a repeated ``Format(_:_:)`` type keeps
/// the last entry. ``withCLI(_:_:)`` and ``MMCLIDefaults`` remain the
/// value-level spelling underneath.
@discardableResult
public func MMCLI<Value>(
    isolation: isolated (any Actor)? = #isolation,
    @MMCLIBuilder _ parts: () -> [MMCLIPart],
    run body: () async throws -> Value
) async rethrows -> Value {
    let (defaults, configuration) = assembleParts(parts())
    precondition(
        configuration == nil,
        "Configuration(...) belongs to the run:-less MMCLI form — with run:, the root command type carries its own configuration"
    )
    return try await MMCLIDefaults.$current.withValue(
        defaults,
        operation: body,
        isolation: isolation
    )
}

/// The fully synthesized form: declare the root command's shape —
/// ``Name(_:)``, ``Abstract(_:)``, ``Commands(_:)``, ``Version(_:)``, or a
/// full ``Configuration(_:)`` they merge onto — and `MMCLI` builds and runs
/// the root itself: parse, async dispatch, help, and exit codes all through
/// ArgumentParser, so the entire tool is one declaration (see
/// ``MMCLI(isolation:_:run:)`` for the custom-root form):
///
/// ```swift
/// @main
/// struct Main {
///     static func main() async {
///         await MMCLI {
///             Name("mm")
///             Abstract("Talks to mmd over its Unix socket.")
///             Version("1.0.0")
///             Commands([Journal.Command.self, MMCLIDiscover.self, MMCLIRawCall.self])
///             Contract(.complete([journalContract]))
///             Endpoint(.unix(path: "/var/run/mmd/rpc.sock"))
///         }
///     }
/// }
/// ```
public func MMCLI(
    isolation: isolated (any Actor)? = #isolation,
    @MMCLIBuilder _ parts: () -> [MMCLIPart]
) async {
    let (defaults, configuration) = assembleParts(parts())
    guard let configuration else {
        preconditionFailure(
            "MMCLI without run: requires the root command's shape — Commands(...) (plus Name/Abstract/Version) or Configuration(...) — or run your own root via MMCLI { ... } run: { await MyRoot.main() }"
        )
    }
    await MMCLIDefaults.$current.withValue(
        defaults,
        operation: { await dispatchSynthesizedRoot(configuration, arguments: nil) },
        isolation: isolation
    )
}

func assembleParts(
    _ parts: [MMCLIPart]
) -> (defaults: MMCLIDefaults, configuration: CommandConfiguration?) {
    var defaults = MMCLIDefaults()
    var configuration: CommandConfiguration?
    var name: String?
    var abstract: String?
    var commands: [any ParsableCommand.Type]?
    var version: String?
    var formatters: [MMCLIFormatEntry] = []
    for part in parts {
        switch part.kind {
            case .configuration(let value):
                precondition(
                    configuration == nil,
                    "MMCLI declares Configuration(...) twice"
                )
                configuration = value
            case .name(let value):
                precondition(name == nil, "MMCLI declares Name(...) twice")
                name = value
            case .abstract(let value):
                precondition(abstract == nil, "MMCLI declares Abstract(...) twice")
                abstract = value
            case .commands(let value):
                precondition(commands == nil, "MMCLI declares Commands(...) twice")
                commands = value
            case .version(let value):
                precondition(version == nil, "MMCLI declares Version(...) twice")
                version = value
            case .contract(let claim):
                precondition(
                    defaults.serverContract == nil,
                    "MMCLI declares Contract(...) twice"
                )
                defaults.serverContract = claim
            case .endpoint(let endpoint):
                precondition(defaults.endpoint == nil, "MMCLI declares Endpoint(...) twice")
                defaults.endpoint = endpoint
            case .output(let format):
                precondition(defaults.output == nil, "MMCLI declares Output(...) twice")
                defaults.output = format
            case .format(let entry):
                formatters.append(entry)
        }
    }
    defaults.formatters = MMCLIFormatters(entries: formatters)

    // The sugar parts merge onto Configuration(...) when both appear; the
    // same field declared both ways is a programmer error, not an override.
    guard
        configuration != nil || name != nil || abstract != nil
            || commands != nil || version != nil
    else {
        return (defaults, nil)
    }
    var merged = configuration ?? CommandConfiguration()
    if let name {
        precondition(
            merged.commandName == nil,
            "MMCLI declares the command name twice — Configuration(commandName:) and Name(...)"
        )
        merged.commandName = name
    }
    if let abstract {
        precondition(
            merged.abstract.isEmpty,
            "MMCLI declares the abstract twice — Configuration(abstract:) and Abstract(...)"
        )
        merged.abstract = abstract
    }
    if let commands {
        precondition(
            merged.subcommands.isEmpty,
            "MMCLI declares subcommands twice — Configuration(subcommands:) and Commands(...)"
        )
        merged.subcommands = commands
    }
    if let version {
        precondition(
            merged.version.isEmpty,
            "MMCLI declares the version twice — Configuration(version:) and Version(...)"
        )
        merged.version = version
    }
    return (defaults, merged)
}

/// The synthesized root: a group command whose static configuration reads
/// the task-local binding (ArgumentParser roots are types, so injection has
/// to happen through a computed static). No `run` of its own — like any
/// generated namespace group, a bare invocation renders help.
struct MMCLIRoot: ParsableCommand {
    @TaskLocal static var boundConfiguration: CommandConfiguration?

    static var configuration: CommandConfiguration {
        Self.boundConfiguration ?? CommandConfiguration()
    }

    init() {}
}

/// Parse/dispatch/exit for the synthesized root — the same choreography a
/// hand-written custom `main()` would contain, kept in exactly one place.
/// `arguments` is a test seam; nil parses the process arguments.
func dispatchSynthesizedRoot(
    _ configuration: CommandConfiguration,
    arguments: [String]?
) async {
    await MMCLIRoot.$boundConfiguration.withValue(configuration) {
        do {
            var command = try MMCLIRoot.parseAsRoot(arguments)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            MMCLIRoot.exit(withError: error)
        }
    }
}

/// The value-level binding under the ``MMCLI(isolation:_:)`` block: binds
/// already-assembled ``MMCLIDefaults`` around `body`. Reach for it when the
/// defaults are computed rather than declared — or in tests, which bind
/// defaults around a single parse the same way. The binding is scoped,
/// never installed: nothing outside `body` observes it.
public func withCLI<Value>(
    _ defaults: MMCLIDefaults,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Value
) async rethrows -> Value {
    try await MMCLIDefaults.$current.withValue(
        defaults,
        operation: body,
        isolation: isolation
    )
}

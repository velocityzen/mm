import ArgumentParser
import MMWire

/// The tool's build-time defaults — the companion server's completeness
/// claim and its well-known endpoint. Bind them around the root command's
/// run with ``withCLI(_:_:)``; see there for the entry-point shape.
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

    /// The binding commands read; empty unless the tool bound one via
    /// ``withCLI(_:_:)``.
    @TaskLocal public static var current = MMCLIDefaults()

    public init(
        serverContract: MMCLIServerContract? = nil,
        endpoint: MMEndpoint? = nil
    ) {
        self.serverContract = serverContract
        self.endpoint = endpoint
    }
}

/// Binds the tool's build-time defaults around `body` — the whole entry
/// point of a companion CLI. Put `@main` on a plain entry struct and let the
/// body be the root command's own `main()`, so ArgumentParser's
/// parse/dispatch/exit choreography runs unchanged inside the binding:
///
/// ```swift
/// @main
/// struct Main {
///     static func main() async {
///         await withCLI(
///             MMCLIDefaults(
///                 serverContract: .complete([journalContract]),
///                 endpoint: .unix(path: "/tmp/mm-example.sock")
///             )
///         ) {
///             await MMExampleCLI.main()   // the AsyncParsableCommand root
///         }
///     }
/// }
/// ```
///
/// The body is arbitrary async work — a test can bind defaults around a
/// single parse the same way — and the binding is scoped, never installed:
/// nothing outside `body` observes it.
public func withCLI<Value>(
    _ defaults: MMCLIDefaults,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Value
) async rethrows -> Value {
    try await MMCLIDefaults.$current.withValue(
        defaults, operation: body, isolation: isolation)
}

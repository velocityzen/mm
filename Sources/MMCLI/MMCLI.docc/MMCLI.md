# ``MMCLI``

The runtime behind schema-generated command-line tools: connection options, exit-code mapping, output rendering, stream drivers, and schema-driven generic commands.

## Overview

A top-level `CLI(.enabled)` entry in the `#schema("journal")` block makes the macro emit one swift-argument-parser command per non-omitted call plus a namespace group (`Journal.Command`) — names, `--help` text, and argument shapes all derived from the contract declaration, reshaped by `CLI(...)` parts and `Field(..., cli:)` hints. A `Field(..., default:)` literal automatically makes its option hybrid (ArgumentParser's `defaultAsFlag`): bare `--format` means the default, `--format yaml` parses the value, absent stays nil. A `description:` on the schema becomes the group's abstract (falling back to a "Commands for the … namespace." template without one). Those generated commands are thin: everything with runtime behavior lives here.

- ``MMCLIOptions`` is the shared `@OptionGroup` every command embeds: `--socket`/`--tcp` (exactly one — or neither, when the tool declared its daemon's well-known address via ``Endpoint(_:)``; explicit flags always win), connect/hello timeouts, `--output` (``OutputFormat``: `json`, `json-pretty`, `raw`, `text`), and `--no-verify`.
- ``MMCLIRunner`` owns the connection lifecycle for a one-shot process: connect, run the inbound loop as a structured child, execute the command body, close — connect failures render "is the daemon running?" and exit 69. Schema verification is automatic and never manual: a matching build-time completeness claim proves the whole composition from the hello, and otherwise the command's namespace is confirmed with one scoped discovery diff before dispatch (drift exits 76).
- ``MMCLIVerify`` backs the generated per-namespace `verify` subcommand: a discovery diff of the compiled contract against what the server serves, scoped to the namespace — the build-time-derived compatibility check (the hello fingerprint covers the whole server and can't be computed from one namespace). "In sync" exits 0; any difference prints its buckets and exits 1, like `diff`.
- Verification also runs **automatically**: every generated command hands the runner its contract (`invoke(_:verifying:_:)`), which confirms the namespace before dispatch — drift exits 76, `--no-verify` opts out, denied discovery skips with a note. ``MMCLIServerContract`` upgrades this to a free check for purpose-built tools — declared via ``Contract(_:)``: `.complete([...])` folds the expected whole-server hello fingerprint at startup (builtins and any `sharedTypes:` declarations included — a server registering shared `Types(...)` containers can never match a claim that omits them), a matching hello proves the entire composition with no discovery round-trip, and a mismatch falls back to the scoped diff.
- ``MMCLIFailure`` maps `MMCallError` to sysexits-flavored codes (denied → 77, unknown method → 64, malformed params → 65, transport → 69, SIGINT → 130, application `MMError`s → 1 with `error <code>: <message>` on stderr) and validates entity arguments. The `<entity>` positional is optional on every command: omitting it sends an entity-less (root-targeted) request, which the daemon accepts only when the route's `Accepts` names exactly one concrete entity and infers it — any other route answers with an ordinary denial.
- ``MMCLIOutput`` renders responses as JSON — generated payload structs carry field names in their `CodingKeys`' `stringValue`, so `JSONEncoder` prints named keys with zero schema plumbing. All stdout/stderr writing lives in this one type. `--output text` adds per-command human rendering, resolved in order: a ``Format(_:_:)`` declaration in the ``MMCLI(isolation:_:)`` block (also spellable metatype-free as ``Format(_:)`` — `Format { (event: ChangeEvent) in ... }`, the type inferred from the closure parameter; keyed by the generated response/element *type*, so one entry addresses exactly one command's output or one stream's elements); the type's own `CustomStringConvertible` conformance (`extension Journal.ReadResponse: CustomStringConvertible { ... }` — the registry-free way, conformance travels with the type); else compact JSON; `json`/`json-pretty` always bypass the formatters, so scripts stay stable. ``Output(_:)`` sets the tool's default format for human-first tools.
- ``MMCLIStreamDriver`` drives the three stream shapes: `follow` prints elements as JSON lines with SIGINT mapped to a graceful STOP (second SIGINT cancels); `feed` pumps stdin lines through the credit-gated writer (single-string-field elements take plain lines, everything else JSON lines; EOF is END); `duplex` does both at once. ``MMCLISignals`` provides the structured SIGINT primitive underneath.
- ``MMCLIEnumArgument`` makes generated wire enums typed command arguments whose `unknown` fallback is hidden from help and refused as input; ``MMCLIJSON`` decodes JSON-literal options for fields with no flat command-line shape.

Two generic commands need no code generation and mount alongside generated groups: ``MMCLIDiscover`` (`discover` — the schema a server actually serves, with the hello verdict on stderr) and ``MMCLIRawCall`` (`call` — any unary method by wire name, `--params` JSON validated and encoded against the *discovered* signature via ``MMCLIDynamicRequest``, the response decoded through ``MMCLIDynamicResponse``'s task-local schema and rendered with field names).

The whole tool is one declaration — the CLI twin of `MMService { ... }`. The root-shape parts (``Name(_:)``, ``Abstract(_:)``, ``Commands(_:)``, ``Version(_:)`` — or a full ``Configuration(_:)`` they merge onto, for fields like `defaultSubcommand`) make ``MMCLI(isolation:_:)`` synthesize and run the root command itself (parse, async dispatch, help, exit codes — all through ArgumentParser), and the other parts bind as the invocation's task-local defaults:

```swift
@main
struct Main {
    static func main() async {
        await MMCLI {
            Name("mm")
            Abstract("Talks to mmd over its Unix socket.")
            Version("1.0.0")
            Commands([Journal.Command.self, MMCLIDiscover.self, MMCLIRawCall.self])
            Contract(.complete([journalContract]))
            Endpoint(.unix(path: "/var/run/mmd/rpc.sock"))
            Format(ChangeEvent.self) { "\($0.count)\t\($0.line)" }
        }
    }
}
```

A tool with its own hand-written root keeps it and uses the `run:` form instead — `await MMCLI { Contract(...) } run: { await MM.main() }` (no `Configuration` part there; the root type carries its own). ``withCLI(_:_:)`` and ``MMCLIDefaults`` remain the value-level spelling underneath.

## Topics

### Shared command surface

- ``MMCLIOptions``
- ``MMCLI(isolation:_:)``
- ``MMCLI(isolation:_:run:)``
- ``Configuration(_:)``
- ``Name(_:)``
- ``Abstract(_:)``
- ``Commands(_:)``
- ``Version(_:)``
- ``Contract(_:)``
- ``Endpoint(_:)``
- ``Output(_:)``
- ``MMCLIBuilder``
- ``MMCLIPart``
- ``MMCLIDefaults``
- ``withCLI(_:_:)``
- ``OutputFormat``
- ``MMCLIFormatters``
- ``Format(_:_:)``
- ``Format(_:)``

### Running a command

- ``MMCLIRunner``
- ``MMCLIFailure``
- ``MMCLIOutput``
- ``MMCLISignals``
- ``MMCLIVerify``
- ``MMCLIServerContract``

### Argument bridging

- ``MMCLIEnumArgument``
- ``MMCLIJSON``

### Stream drivers

- ``MMCLIStreamDriver``

### Generic commands

- ``MMCLIDiscover``
- ``MMCLIRawCall``

### Schema-driven dynamic values

- ``MMCLIDynamicTree``
- ``MMCLIDynamicRequest``
- ``MMCLIDynamicResponse``
- ``MMCLIDynamicJSONText(_:pretty:)``

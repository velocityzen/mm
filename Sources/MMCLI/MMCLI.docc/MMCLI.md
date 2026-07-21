# ``MMCLI``

The runtime behind schema-generated command-line tools: connection options, exit-code mapping, output rendering, stream drivers, and schema-driven generic commands.

## Overview

`#schema("journal", cli: .enabled)` makes the macro emit one swift-argument-parser command per non-omitted call plus a namespace group (`Journal.Command`) — names, `--help` text, and argument shapes all derived from the contract declaration, reshaped by `CLI(...)` parts and `Field(..., cli:)` hints. Those generated commands are thin: everything with runtime behavior lives here.

- ``MMCLIOptions`` is the shared `@OptionGroup` every command embeds: `--socket`/`--tcp` (exactly one — or neither, when the tool bound its daemon's well-known address via ``MMCLIDefaults``; explicit flags always win), connect/hello timeouts, `--output` (``OutputFormat``: `json`, `json-pretty`, `raw`), and `--no-verify`.
- ``MMCLIRunner`` owns the connection lifecycle for a one-shot process: connect, run the inbound loop as a structured child, execute the command body, close — connect failures render "is the daemon running?" and exit 69. Schema verification is automatic and never manual: a matching build-time completeness claim proves the whole composition from the hello, and otherwise the command's namespace is confirmed with one scoped discovery diff before dispatch (drift exits 76).
- ``MMCLIVerify`` backs the generated per-namespace `verify` subcommand: a discovery diff of the compiled contract against what the server serves, scoped to the namespace — the build-time-derived compatibility check (the hello fingerprint covers the whole server and can't be computed from one namespace). "In sync" exits 0; any difference prints its buckets and exits 1, like `diff`.
- Verification also runs **automatically**: every generated command hands the runner its contract (`invoke(_:verifying:_:)`), which confirms the namespace before dispatch — drift exits 76, `--no-verify` opts out, denied discovery skips with a note. ``MMCLIServerContract`` upgrades this to a free check for purpose-built tools: `.complete([...])` folds the expected whole-server hello fingerprint at startup (builtins and any `sharedTypes:` declarations included — a server registering shared `Types(...)` containers can never match a claim that omits them), a matching hello proves the entire composition with no discovery round-trip, and a mismatch falls back to the scoped diff.
- ``MMCLIFailure`` maps `MMCallError` to sysexits-flavored codes (denied → 77, unknown method → 64, malformed params → 65, transport → 69, SIGINT → 130, application `MMError`s → 1 with `error <code>: <message>` on stderr) and validates entity arguments. The `<entity>` positional is optional on every command: omitting it sends an entity-less (root-targeted) request, which the daemon accepts only when the route's `Accepts` names exactly one concrete entity and infers it — any other route answers with an ordinary denial.
- ``MMCLIOutput`` renders responses as JSON — generated payload structs carry field names in their `CodingKeys`' `stringValue`, so `JSONEncoder` prints named keys with zero schema plumbing. All stdout/stderr writing lives in this one type.
- ``MMCLIStreamDriver`` drives the three stream shapes: `follow` prints elements as JSON lines with SIGINT mapped to a graceful STOP (second SIGINT cancels); `feed` pumps stdin lines through the credit-gated writer (single-string-field elements take plain lines, everything else JSON lines; EOF is END); `duplex` does both at once. ``MMCLISignals`` provides the structured SIGINT primitive underneath.
- ``MMCLIEnumArgument`` makes generated wire enums typed command arguments whose `unknown` fallback is hidden from help and refused as input; ``MMCLIJSON`` decodes JSON-literal options for fields with no flat command-line shape.

Two generic commands need no code generation and mount alongside generated groups: ``MMCLIDiscover`` (`discover` — the schema a server actually serves, with the hello verdict on stderr) and ``MMCLIRawCall`` (`call` — any unary method by wire name, `--params` JSON validated and encoded against the *discovered* signature via ``MMCLIDynamicRequest``, the response decoded through ``MMCLIDynamicResponse``'s task-local schema and rendered with field names).

Assemble a tool by mounting groups in a root command (the root must be `AsyncParsableCommand` for async dispatch):

```swift
@main
struct MM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mm",
        subcommands: [Journal.Command.self, MMCLIDiscover.self, MMCLIRawCall.self])
}
```

## Topics

### Shared command surface

- ``MMCLIOptions``
- ``MMCLIDefaults``
- ``withCLI(_:_:)``
- ``OutputFormat``

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

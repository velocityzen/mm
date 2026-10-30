# ``MMCLI``

The runtime for schema-generated command-line tools: connection options, exit-code mapping, output rendering, stream drivers, and schema-driven generic commands.

## Overview

A top-level `CLI(.enabled)` entry in the `#schema("journal")` block turns on CLI generation. The `MMCLIGeneratorPlugin` build-tool plugin, applied to the command-line target, generates one swift-argument-parser command per non-omitted call and a namespace group (`Journal.Command`), as an extension of the namespace type. The API module that declares the schema, shared with the daemon, depends only on MMSchema. Names, `--help` text, and argument shapes come from the contract, adjusted by `CLI(...)` parts and `Field(..., cli:)` hints.

- A `Field(..., default:)` literal makes its option hybrid (ArgumentParser's `defaultAsFlag`). Bare `--format` uses the default, `--format yaml` parses the value, and an absent option stays nil.
- On calendar and clock fields, `default: .now` uses the time of invocation.
- A `description:` on the schema becomes the group's abstract. Without it, the abstract is "Commands for the … namespace."

The generated commands contain little code. All runtime behavior lives in this module:

- ``MMCLIOptions`` is the shared `@OptionGroup` in every command:
  - `--socket`/`--tcp`: exactly one, or neither when the tool declares its daemon's address with ``Endpoint(_:)``. Explicit flags always win.
  - Connect and hello timeouts.
  - `--output` (``OutputFormat``: `json`, `json-pretty`, `raw`, `text`).
  - `--no-verify`.
- ``MMCLIRunner`` runs the command body inside an `MMClient` bracket: acquire connects and starts the inbound loop, dispose closes the connection and joins the loop. A connect failure prints "is the daemon running?" and exits 69.
- ``MMCLIVerify`` implements the generated `verify` subcommand of each namespace. It diffs the compiled contract against what the server serves, for that namespace only. This is the compatibility check you can derive at build time. (The hello fingerprint covers the whole server, so one namespace cannot produce it.) In sync exits 0. A difference prints its buckets and exits 1, like `diff`.
- Verification also runs **automatically**, never manually. Every generated command passes its contract to the runner (`invoke(_:verifying:_:)`). The runner confirms the namespace with one scoped discovery diff before dispatch. Drift exits 76. `--no-verify` turns it off. Denied discovery skips the check with a note. Purpose-built tools can declare ``MMCLIServerContract`` with ``Contract(_:)``. `.complete([...])` computes the expected whole-server hello fingerprint at startup, including builtins and any `sharedTypes:` declarations. (A server that registers shared `Types(...)` containers never matches a claim that omits them.) A matching hello then proves the whole composition with no discovery round-trip. A mismatch falls back to the scoped diff.
- ``MMCLIFailure`` maps `MMCallError` to sysexits-style exit codes: denied 77, unknown method 64, malformed params 65, transport 69, SIGINT 130. Application `MMError`s exit 1 and print `error <code>: <message>` on stderr. It also validates entity arguments. The `<entity>` positional is optional on every command. Without it, the request is root-targeted. The daemon accepts that only when the route's `Accepts` names exactly one concrete entity, which it infers. Other routes return an ordinary denial.
- ``MMCLIOutput`` renders responses as JSON. Generated payload structs keep field names in their `CodingKeys`' `stringValue`, so `JSONEncoder` prints named keys with no schema code. This type does all stdout and stderr writing. `--output text` uses the first match:
  1. A ``Format(_:_:)-(_,(T)->String)`` entry in the ``MMCLI(_:)`` block, or ``Format(_:)`` without the metatype: `Format { (event: ChangeEvent) in ... }` infers the type from the closure parameter. Text that doesn't depend on the value takes a closure with no parameter, ``Format(_:_:)-(_,()->String)``: `Format(Journal.AppendResponse.self) { "appended" }`. A stream element's entry can carry a header, ``Format(_:header:_:)``, printed once above the stream's first element (column titles for a table of rows). Entries are keyed by the generated response or element *type*: one entry matches one command's output or one stream's elements.
  2. The type's `CustomStringConvertible` conformance (`extension Journal.ReadResponse: CustomStringConvertible { ... }`), which needs no registry.
  3. Compact JSON.

  `json` and `json-pretty` always skip the formatters, so script output stays stable. ``Output(_:)`` sets the default format for tools used mainly by people.
- ``MMCLIStreamDriver`` runs the three stream shapes. ``MMCLISignals`` provides its structured SIGINT primitive.
  - `inbound` (server stream) prints elements as JSON lines. SIGINT sends a graceful STOP, and a second SIGINT cancels.
  - `outbound` (client stream) sends stdin lines through the credit-gated writer. Single-string-field elements take plain lines, others JSON lines. EOF sends END.
  - `bidirectional` does both.
- ``MMCLIInputRunner`` runs a command whose request field is `cli: .input`. The value comes from the positional, or as a byte stream (``MMCLIInput``, with `lines` for text) from `--input <path>` (`-` for stdin). An ``Input(_:_:)`` entry in the `MMCLI { }` block gets the stream, the parsed arguments as the request (input field empty), the call's CLI options (`CLI(...) { Field(...) }`) when its body takes four parameters, and the call (``MMCLIInputCall``, which takes a whole request or just the input value), and returns its results as an `AsyncSequence` of `Result`s, such as an FPPipe `Pipe`. Without one, the command makes one call per non-blank line, with a `==> line <==` heading above each under text output. Failures of one value (exit 1 or 65) are reported and the run continues; other failures end it. The first Ctrl-C ends the input, the work in flight finishes, and the command exits 130.
- ``MMCLIEnumArgument`` makes generated wire enums typed command arguments. Their `unknown` fallback is hidden from help and rejected as input.
- ``MMCLIJSON`` decodes JSON-literal options for fields with no flat command-line shape.

Two generic commands need no code generation. Mount them next to the generated groups:

- ``MMCLIDiscover`` (`discover`) prints the schema the server actually serves, with the hello verdict on stderr.
- ``MMCLIRawCall`` (`call`) calls any unary method by wire name. ``MMCLIDynamicRequest`` validates and encodes `--params` JSON against the *discovered* signature. The response is decoded with the task-local schema of ``MMCLIDynamicResponse`` and printed with field names.

The whole tool is one declaration, like `MMService { ... }`. With the root-shape parts (``Name(_:)``, ``Abstract(_:)``, ``Commands(_:)``, ``Version(_:)``), ``MMCLI(_:)`` builds and runs the root command through ArgumentParser (parsing, async dispatch, help, exit codes). For fields like `defaultSubcommand`, add a full ``Configuration(_:)``; the parts merge onto it. Other parts become task-local defaults for the invocation:

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

A tool with a hand-written root uses the `run:` form: `await MMCLI { Contract(...) } run: { await MM.main() }`. It takes no `Configuration` part, because the root type has its own. ``withCLI(_:_:)`` and ``MMCLIDefaults`` are the value-level API underneath.

## Topics

### Shared command surface

- ``MMCLIOptions``
- ``MMCLI(_:)``
- ``MMCLI(_:run:)``
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
- ``Format(_:_:)-(_,(T)->String)``
- ``Format(_:)``
- ``Format(_:_:)-(_,()->String)``
- ``Format(_:header:_:)``

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

### Input commands

- ``Input(_:_:)``
- ``MMCLIInputCommand``
- ``MMCLIInputCall``
- ``MMCLIInput``
- ``MMCLIInputLines``
- ``MMCLIInputSource``
- ``MMCLIInputRunner``
- ``MMCLIError``

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

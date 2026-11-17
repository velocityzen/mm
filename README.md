# matter-in-motion

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Fmm%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/velocityzen/mm)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Fmm%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/velocityzen/mm)
[![Documentation](https://img.shields.io/badge/documentation-DocC-blue)](https://swiftpackageindex.com/velocityzen/mm/documentation)

A Swift library for binary RPC over Unix domain sockets and TCP:

- Declarative schemas as plain Swift values, with runtime discovery.
- Filesystem-style (rwx, user/group/other) authorization, enforced by a router using kernel peer credentials.
- Length-prefix framing with a compact tagged-array MessagePack envelope for calls, terminals, and stream frames.

SwiftNIO is the async runtime. The public API uses structured concurrency and typed `Result` errors. The server (`MMService { ... }`) and the client (`MMClient { ... }`) are both [fp-swift-bracket](https://github.com/velocityzen/fp-swift-bracket) resources, declared the same way: you compose them with your own and run the result with any lifecycle, such as [fp-swift-service](https://github.com/velocityzen/fp-swift-service).

## Modules

One package, `MatterInMotion`, with five library products and one build-tool plugin:

- `MMWire`: MessagePack coder over `ByteBuffer`, `[u32 LE length][payload]` framing, the RPC envelope, the hello preamble. Depends only on NIOCore and `MMSchema`.
- `MMSchema`: method descriptors, `TypeSchema` and the schema fingerprint, `EntityACL`, `PeerIdentity`. Pure values: no NIO import, no IO.
- `MMServer`: `Router` with a result-builder DSL, authorization, peer-credential capture, streaming handlers, and `MMService`, the server as a `BracketAsync`.
- `MMClient`: `MMClient`, the client as a `BracketAsync`, and the `MMClientConnection` it yields, with typed unary and streaming calls, msgid multiplexing, credit-based flow control, and schema discovery.
- `MMCLI`: runtime for schema-generated command-line tools (swift-argument-parser): connection options, exit-code mapping, stream drivers, `discover` and raw `call` commands.
- `MMCLIGeneratorPlugin`: generates a `#schema`'s `CLI(.enabled)` commands into the command-line target, so the shared API module (and the daemon) does not depend on MMCLI or swift-argument-parser.

`MMSchema` has no internal dependencies. `MMWire` depends on `MMSchema` (the binary codecs for wire time kinds live there). `MMServer` and `MMClient` depend on both. `MMCLI` depends on `MMClient`. Client-only processes can import `MMSchema`.

## Design principles

- **The declaration is the source of truth.** One `#schema` block defines the wire contract. Payload structs, typed descriptors, the discovery response, and the fingerprint come from it. At boot, the daemon checks it against its compiled types and refuses to listen on a mismatch. The client checks and diffs it against a live server.
- **Authorization before payload.** The target entity is envelope metadata, not payload. The router checks traversal on every ancestor, then the method's access class, before it decodes any params byte.
- **POSIX, not tokens.** Identity is kernel peer credentials on Unix sockets. No identity data crosses the wire. Permissions are owner/group/other rwx bits on an entity tree. See [Authorization model](#authorization-model).
- **Bounded everything.** Frame length, connections, in-flight calls, and per-direction stream windows are capped. Counts from the wire never size allocations. A slow consumer pauses the producer, so memory does not grow.
- **Termination is graceful and typed.** See [Streaming](#streaming).
- **Evolution without version bumps.** The protocol version is 1 and stays 1. See [Versioning](#versioning).
- **Resources, not services.** The server and the client connection are brackets: acquire starts one, dispose stops it, and whatever runs in between is owned by that scope. The host composes them with its own resources and owns the lifecycle. No GCD, no free-floating tasks, no automatic reconnection. The application sets the retry policy, using `stateUpdates()` and the retry hint every close carries.
- **Caller isolation.** Like the fp-swift packages, the library targets build with `NonisolatedNonsendingByDefault`: async APIs run on the caller's actor, so a `@MainActor` app uses the client without sending anything across. What mm runs in tasks of its own (handlers, ACL providers, `withStream`'s `each`) is `@concurrent`.

## Quick start

You write the wire contract once. `#schema` generates:

- the request, response, and element structs (integer-keyed MessagePack maps; the target entity travels in the open envelope, so payloads are plain values),
- the typed descriptors and the namespace list,
- a runtime contract to verify and to diff against a live server.

```swift
import MMSchema

public enum Echo: MethodNamespace {
    #schema("echo", description: "Echoes values back, loudly on request.") {
        // Named types are part of the contract: string-valued wire enums
        // (with a generated `unknown` case that keeps any value the
        // contract does not declare) and referenceable
        // structs. Descriptions are served by discovery. The contract
        // documents itself. Descriptions never affect compatibility.
        Enum("Mode", description: "How the echo responds") {
            Case("plain")
            Case("shouted", description: "Upper-cased on the way back")
        }
        Call("run", description: "Echoes a value back") {
            Access { .write }
            Request {
                Field("value", .int)
                Field("mode", "Mode")
            }
            Response { Field("value", .int) }
        }
        // A server-streaming method: the server pushes elements (correlated,
        // authorized at open, flow-controlled), then a terminal.
        Call("watch") {
            Access { .read }
            Request { Field("count", .int) }
            ResponseStream { Field("value", .int) }
            Response { Field("count", .int) }
        }
    }
}
// Generated: Echo.Mode (a String-raw enum), Echo.RunRequest / RunResponse /
// WatchRequest / WatchResponseItem / WatchResponse, the typed descriptors
// Echo.run and Echo.watch, Echo.all, Echo.types, and Echo.contract (verify it
// against Echo.self at boot; diff it against a live server after discovery).
// Hand-written Codable types and the runtime Schema DSL remain available for
// shapes outside the macro's static subset; #schemaTypes hosts shared types.
```

### Server

Declare the whole server (configuration, ACL table, handlers), then run its bracket:

```swift
import FPService
import Foundation
import MMServer

let server = MMService {
    Configuration(endpoint: .unix(path: "/tmp/echo.sock"))
    ACLProvider {
        // The entity tree, filesystem-style: children take relative paths and
        // inherit the parent's owner/group; mode defaults to 0o750.
        Entity("echo", owner: getuid(), group: getgid(), mode: 0o700) {
            Entity("main")
        }
    }
    // For(...) enrolls the startup cross-check: every Echo method needs a
    // handler here, or the daemon refuses to boot.
    For(Echo.self) {
        On(Echo.run) { auth, request in
            // auth.entity is the call's already-authorized target.
            .success(Echo.RunResponse(value: request.value))
        }
        // A streaming handler gets a credit-gated sink: push elements, then
        // return the terminal. `sink.send` reports `.peerStopped` when the
        // client STOPs.
        On(Echo.watch) { auth, request, sink in
            for value in 0..<request.count {
                guard case .sent = await sink.send(Echo.WatchResponseItem(value: value)) else {
                    break  // .peerStopped / .callEnded: wrap up
                }
            }
            return .success(Echo.WatchResponse(count: request.count))
        }
    }
}

// server is a BracketAsync<MMServiceHandle, MMServiceError>: acquire binds and
// starts accepting, dispose drains in-flight calls and removes the socket.
// fp-swift-service runs it: the first SIGTERM or SIGINT drains, a second
// cancels the drain.
let daemon = Service(
  server, 
  shutdownSignals: [SIGTERM, SIGINT], 
  shutdownTimeout: .seconds(30)
)

let result = await daemon()
```

Because the server is a bracket, it composes with the rest of your daemon. With `BracketAsyncDo`, resources start in order and stop in reverse. A resource bound after the server starts only once the socket accepts connections, and stops before the server drains. The bracket's resource is the running server, an `MMServiceHandle`: its `addresses` are the bound addresses, one per endpoint, such as the port of a `.tcp(host:port: 0)` endpoint. One server can listen on several endpoints at once: `Configuration(endpoints: [.unix(path: socketPath), .tcp(host: "127.0.0.1", port: 7000)])` serves both with one router, one connection cap and one drain.

#### Connections you already hold

A server can also serve sockets it never accepted — the parent end of a `socketpair` handed to a child process, say. Declare `SocketInbox()` (with or without endpoints), then, while the server runs, hand each connected descriptor to the running server with the identity *you* attest for it. The server owns the descriptor from then on, and closes it if the adoption fails:

```swift
let server = MMService {
    Configuration(endpoints: [], idleTimeout: nil, helloTimeout: .seconds(5))
    ACLProvider(provider)
    SocketInbox()
    // For { ... } as above
}

await server { running in
    // per spawned child, any time while serving:
    let identity = PeerIdentity(uid: getuid(), gid: getgid(), supplementaryGroups: [], pid: childPID, label: "worker#\(childPID)")
    let adopted = await running.adopt(descriptor: parentEnd, peer: identity)
    ...
}
```

Handlers see the attested identity on `context.peer`, including its free-form `label`. On the other side, the child connects over the inherited descriptor with `MMClient(endpoint: .fd(3))`.

`helloTimeout` reaps a connection that never completes the hello, independently of `idleTimeout`; set `idleTimeout: nil` for peers that may legitimately sit quiet on a long stream.

You can also put handlers in reusable `RouteGroup` types (with their own files and dependencies) and add them to the `For` block. Every server registers two builtins: `server.schema` (discovery, filtered by the caller's traversal rights) and `server.entity` (an entity's ACL record).

### Client

Declare the client the same way, then call its bracket. Acquire connects and starts the inbound loop, the body makes the calls, and dispose closes and waits for the loop: there is no connection outside the bracket.

```swift
import MMClient

let echo = MMClient {
    Configuration(endpoint: .unix(path: "/tmp/echo.sock"))
    // The contracts this build was compiled against: the connection verifies
    // itself (a matching hello proves the whole composition).
    Schema(.complete([Echo.contract]))
}

let main = try! EntityName.parse("echo.main").get()
let outcome = await echo { connection in
    // A failed call (denied, a remote error) leaves the connection up:
    // handle it here, where the call was made.
    switch await connection.call(Echo.run, on: main, Echo.RunRequest(value: 42, mode: .shouted)) {
        case .success(let response):
            print("echoed \(response.value)")
        case .failure(let error):
            print("echo.run failed: \(error)")
    }
    return .success(())
}
// Result<Void, MMClientError>: .failure only when the connection failed.
// Either connect failed, or the connection did not survive the scope (a
// transport error or protocol violation while the body ran). A clean EOF or
// the bracket's own close releases successfully.
```

One connection carries many concurrent calls, correlated by msgid and limited by `maxInFlightCalls`. Open one connection per unit of work, not per call.

For concurrent streams or staged teardown, run structured child tasks *inside* the bracket. To consume a stream while making other calls, use `withStream(_:each:_:)`. `each` runs as a structured sibling and grants credit as it consumes. The trailing closure is your main flow and can use the connection. `withStream` returns after the stream ends.

```swift
let outcome = await echo { connection in
    let main = try! EntityName.parse("echo.main").get()

    // Server-streaming call: a typed, backpressured AsyncSequence of elements
    // plus a terminal result. `stop()` asks the server to wrap up gracefully,
    // `cancel()` aborts.
    let watch = await connection.call(Echo.watch, on: main, Echo.WatchRequest(count: 5))
    let reply = await withStream(watch, each: { event in
        print(event.value)              // ends on server END, terminal, or close
    }) {
        // Typed call on the same connection while events flow.
        await connection.call(Echo.run, on: main, Echo.RunRequest(value: 42, mode: .shouted))
    }
    // Call failures stay in the body; the bracket reports only the connection.
    if case .failure(let error) = reply {
        print("echo.run failed: \(error)")
    }
    if case .failure(let error) = await watch.result() {
        print("echo.watch ended: \(error)")
    }
    return .success(())
}
```

Daemons compose the client into their own bracket, next to their other resources, exactly like the server. The library never reconnects: a closed connection stays closed. The application owns retry policy, using `stateUpdates()`: every close carries a retry hint (`.now`, `.later` or `.never`) so the policy never parses error text.

### CLI

A top-level `CLI(.enabled)` entry generates one swift-argument-parser command per call, plus a namespace group. Names, `--help` text, and argument shapes come from the contract. The `MMCLIGeneratorPlugin` build-tool plugin writes the commands into the CLI target. The API module shared with the daemon depends only on `MMSchema`, so the daemon never links MMCLI or swift-argument-parser:

```swift
.executableTarget(
    name: "JournalCLI",
    dependencies: [
        "JournalAPI",
        .product(name: "MMCLI", package: "mm"),
        .product(name: "MMSchema", package: "mm"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ],
    plugins: [.plugin(name: "MMCLIGeneratorPlugin", package: "mm")]
)
```

To adjust commands:

- A per-call `CLI(...)` part renames or omits a command.
- `Field(..., cli:)` makes an argument positional, a flag, short (explicit, or `short: .auto` to derive `-x` from the long name), renamed, or omitted.
- A `Field(..., default:)` literal makes the option hybrid: a bare `--format` means the default. `default: .now` on date/time fields uses the invocation time.

These settings are never served, fingerprinted, or compared. They do not affect the wire.

```swift
Call("append", description: "Appends one line to a journal") {
    CLI(.command("add", aliases: ["append"]))      // wire: journal.append. CLI: journal add
    Access { .write }
    Request {
        Field("line", .string, description: "The line text")
    }
    Response { Field("count", .int) }
}
```

The whole tool is one declaration. `MMCLI` builds and runs the root command from `Configuration(...)`. The other parts set invocation defaults (`Contract` is explained under verification below).

```swift
@main
struct Main {
    static func main() async {
        await MMCLI {
            Name("mm")
            Commands([Journal.Command.self, MMCLIDiscover.self, MMCLIRawCall.self])
            Contract(.complete([journalContract]))
            Endpoint(.unix(path: "/tmp/mm.sock"))
        }
    }
}
```

```sh
$ mm journal add journal.notes --line "hello"       # Endpoint(...) supplied the socket
{"count":1}
$ mm journal add journal.system --line "nope"
denied: journal.append on journal.system            # exit code 77
```

**What `journal.notes` is, and why it is not in the schema.** Every call applies a verb to a noun. The schema declares verbs and payloads: `journal.append` needs `-w-` on its target and carries `{line}`. The nouns are **entities**: the runtime tree the daemon manages, declared server-side with ACLs (`Entity("journal") { Entity("notes"); Entity("system", owner: 0, mode: 0o700) }`, see [Authorization model](#authorization-model)). Compare syscalls and file paths: `/etc/passwd` is not in the syscall table, but `cat` needs a path. Adding or removing entities does not change the schema or the fingerprint. A contract can still say which nouns a verb takes, as a pattern, never as the entities themselves: the example's `Target("journal.*")` (see [Authorization model](#authorization-model)) keeps journal verbs on journals, and the CLI refuses an entity like `notes` before connecting, naming `journal.*`. The same verb can be denied on another entity, as `journal.system` shows. In `mm journal add journal.notes`, the first `journal` is the command group (the method namespace). The entity path uses the same prefix only by convention (discovery filters methods by their prefix entity).

Every command takes the entity as an optional positional, after any required or optional single-value positional fields (ArgumentParser fills positionals greedily, so `retry <id>` binds the id). Request fields default to `--field-name` options. Positional style is opt-in: `Field("line", .string, cli: .argument)` gives `mm journal add "hello" journal.notes`, as in the runnable example in `Examples/`.

`cli: .input` lets that value come from an input too. `Field("query", .string, cli: .input)` gives both `tool search "one"` and `tool search --input queries.txt --limit 5` (`--input -` reads stdin). With `--input`, a lone positional is the entity. The input arrives as a byte stream, `MMCLIInput`, with `.lines` for text. By default the command makes one call per non-blank line, with every other argument shared. Under `--output text`, each call's output follows a `==> line <==` heading. To decide the work yourself, add an `Input(...)` entry to the `MMCLI { }` block. It gets the stream, the parsed arguments, and the call, and returns the results as an `AsyncSequence` of `Result`s, such as an [FPPipe](https://github.com/velocityzen/fp-swift-pipe) `Pipe`. The arguments are the request the command line describes, with the input field empty, so the body can read the input with them. The call takes a whole request (`search(request)`), or just the input field's value (`search(query)`), which keeps the other arguments as they are:

```swift
Input(Search.RootCommand.self) { input, arguments, search in
    Pipe<Search.RootResponse, MMCLIError> {
        FromResult(input.lines)
        Filter { (query: String) in !query.isEmpty && !query.hasPrefix("#") }
        Map { (query: String) in Search.RootRequest(query: query, limit: arguments.limit) }
        AsyncFlatMap(concurrency: 4, ordered: true) { (request: Search.RootRequest) in await search(request) }
    }
}
```

The command prints each success in its output format. A failure that belongs to one value (an application error, malformed params, or the body's own error) is reported and the run goes on, then the command exits with that failure's code. Any other failure, such as a denial, ends the run. The first Ctrl-C ends the input: the calls in flight finish, and the command exits 130. The field must be a required `.string`, no other positional may be optional or an array, and the call must not stream requests, since stdin belongs to the request stream.

Settings for reading the input that the server never sees, such as a delimiter or a column, go in a block on the call's `CLI(...)` part, or a bare `CLI { }` to keep the command's name. They are declared like request fields and parse like them, but a required one may take a `default:`, which is its value when the option is absent. A body that takes four parameters gets them as a typed `options` value:

```swift
Call("@", description: "Searches the index") {
    CLI {
        Field("column", .int, description: "Which tab-separated column holds the query", default: 0)
    }
    Access { .read }
    Request {
        Field("query", .string, cli: .input)
        Field("limit", .optional(.int))
    }
    Response { Field("hits", .array(.string)) }
}
```

```swift
Input(Search.RootCommand.self) { input, arguments, options, search in
    Pipe<Search.RootResponse, MMCLIError> {
        FromResult(input.lines)
        CompactMap { (line: String) in column(options.column, of: line) }
        AsyncFlatMap { (query: String) in await search(query) }
    }
}
```

Like the rest of the CLI overlay, these options are never served, fingerprinted, or compared. It needs a `cli: .input` field, and its fields are options or flags with a flat shape (scalars, wire enums, calendar/clock kinds, or arrays of those).

Output:

- Unary calls print the response as JSON (`--output json-pretty` for indented output).
- Server-stream commands print elements as JSON lines. SIGINT sends a graceful STOP.
- Client-stream commands read stdin.
- `--output text` uses a `Format(SomeResponse.self) { ... }` declaration in the `MMCLI { }` block, else the type's `CustomStringConvertible`, else JSON. The json formats ignore both, so scripts stay stable.

`MMCLI` also has generic commands: `discover` (what the server serves) and `call` (call any method by wire name with `--params` JSON).

**Schema verification is automatic, never manual.** Before dispatch, each generated command checks its namespace against the server with one scoped discovery diff. On drift, it prints the difference and exits 76. `--no-verify` skips the check once.

A purpose-built CLI avoids this round-trip. `await MMCLI { Name("mm"); Commands([...]); Contract(.complete([journalContract])); Endpoint(.unix(path: socketPath)) }` runs the root command, binds the declarations as a task-local (no process-global state), and makes `--socket`/`--tcp` optional. At build time, the expected whole-server hello fingerprint is computed from the declarations the daemon compiled (builtins included). A matching hello proves the whole composition with no extra round-trips. On mismatch, commands fall back to the scoped diff. If the server registers shared `Types(...)` containers, pass the same declarations (`sharedTypes:`) to the claim, or it never matches.

Embedding clients set `configuration.schema = .complete([journalContract])`, or `.partial` to use part of the server (both take `sharedTypes:` for shared `Types(...)` containers). The connection verifies itself after connect. `await connection.verify()` returns `.ok` (whole composition proven), `.partial` (your contracts match; something else changed), or `.difference(differences)`. It never disconnects.

Each group also has a `verify` subcommand. You never type a fingerprint: it is computed from contracts at build time.

## Streaming

A method has four independent, combinable parts: an opening `Request`, a client-push `RequestStream`, a server-push `ResponseStream`, and a terminal `Response`. A unary call has no stream parts. Server push is a normal method with a `ResponseStream`: correlated to a msgid, authorized once at open, fingerprinted, and discoverable. There is no separate notification mechanism.

- **Descriptors:** `ServerStreamMethod` (server → client), `ClientStreamMethod` (client → server), `BidirectionalStreamMethod` (both). Handlers get a credit-gated `MMResponseSink` to push elements and/or an `MMRequestStream` AsyncSequence of inbound elements. Clients get an `InboundStreamHandle` (an element `AsyncSequence` plus `result()`/`stop()`/`cancel()`), an `OutboundStreamHandle` (`send()`/`finish()`/`result()`), or a `BidirectionalStreamHandle` with two halves.
- **Credit-based flow control:** each direction starts with 8 items of credit. The receiver grants more in watermark batches as it consumes. A sender with zero credit suspends, so memory stays bounded. One stream never blocks sibling streams.
- **Graceful termination:** END finishes your direction. STOP asks the peer to finish theirs (a typed `.peerStopped`, never an error). CANCEL aborts the whole call. Every call, unary or streaming, ends with exactly one terminal response. It tells the client whether the call ended gracefully or failed. A handler relaying a quiet source sees STOP at once via `sink.stopRequested()`, before its next send.

## Declared errors

The errors a call can fail with are part of its contract. A top-level `Errors` block declares the namespace's errors, which every call can return. An `Errors` part in a `Call` adds the call's own. `Error("Full")` declares a named error the way `Type` declares a named type, and `Case(.reference("Full"))` lists it:

```swift
#schema("journal") {
    Errors {
        Case("retired", exitCode: 10, description: "The journal is retired")
    }
    Error("Full", exitCode: 12) { Field("capacity", .int) }
    Call("append") {
        Access { .write }
        Errors {
            Case("emptyLine", exitCode: 11)
            Case(.reference("Full"))
        }
        Request { Field("line", .string) }
    }
}
```

`#schema` generates one flat enum per call, `Journal.AppendError` with the cases `retired`, `emptyLine`, and `full(Journal.Full)`, plus `unknown(String)` for a case this build does not know. The namespace's errors also get `Journal.Error`, which `Journal.AppendError(_:)` lifts into the call's enum. A case can carry inline fields (`Case("tooLong", exitCode: 13) { Field("limit", .int) }`) or a named `Type` (`Case("conflict", .reference("Conflict"), exitCode: 14)`).

- **Handlers** return the call's enum: `On(Journal.append) { auth, request in .failure(.emptyLine) }`.
- **Clients** get it typed: `call(Journal.append, ...)` fails with `.declared(.emptyLine)`, and with `.undeclared(MMCallError)` for anything the contract does not declare (a denial, a dropped connection).
- **The generated CLI** exits with the case's `exitCode` (2 to 63, unique within a call) and prints the case, its description, and its fields on stderr: `full: ... {"capacity":10000}`.
- **On the wire** every declared error is error code 64 with the case name as the message and the union value as the payload. The case name is the identity, so reordering errors is safe. Discovery serves each method's errors (`MethodSignature` key 30), the fingerprint covers them, and `verify(against:)` checks them. See WireProtocol.md, section 6.2.

A namespace with errors has a type named `Error`, which shadows `Swift.Error` inside it: write `Swift.Error` there. Importing MMSchema also makes a bare `Error.self` ambiguous with the `Error(...)` DSL function; write `(any Error).self`.

## Constraints

A contract can say more about a value than its shape. A field takes a `constraints:` list, and `Alias` names a scalar kind with rules every value of it keeps:

```swift
#schema("shelf") {
    Alias("Slug", .string, constraints: .length(1...64), .pattern("[a-z0-9-]+"))
    Call("put") {
        Access { .write }
        Request {
            Field("slug", "Slug")
            Field("limit", .optional(.int), constraints: .range(1...1000))
            Field("ratio", .double, constraints: .range(0.0...1.0))
            Field("tags", .array(.string), constraints: .nonEmpty)
        }
        Response { Field("ok", .bool) }
    }
}
```

- **Rules.** A range is inclusive, either end may be open (`.range(1...)`), and takes integer bounds on `int`/`uint`, floating ones on `float`/`double`, and `Duration` literals with an integer count on `duration` (`.range(.seconds(1)...(.seconds(300)))`, compared to the attosecond). A length is inclusive and counts a string's Unicode scalars, a byte string's bytes, an array's elements, or a map's entries; `.nonEmpty` is `.length(1...)`. A pattern is a regular expression the whole string matches, kept to the syntax ECMAScript and PCRE share. `#schema` refuses, at compile time, a rule on a kind that does not take it, bounds that cross, and a pattern that does not compile.
- **Named scalars.** `Alias` generates a wrapper struct (`Shelf.Slug("books")`, `.rawValue`) that travels as the bare scalar. A field of the type takes its rules from the type.
- **The server checks at ingress**, in every build, after decoding and before the handler. A violating request gets `malformedParams` (code 3) naming the failing field: `malformed params: limit: is 0, less than the minimum 1`. A violating request-stream item ends the call with code 6: `stream violation: [3].slug: does not match the pattern [a-z0-9-]+`. A request that does not decode gets the same treatment: `malformed params: limit: expected integer, got string`.
- **A debug client checks before sending.** In debug builds of the module that declares the contract, the generated descriptors refuse a violating request with `MMCallError.invalidRequest(path:problem:)` and send nothing; the generated CLI exits 65. Release clients send what they are given and let the server answer.
- **On the wire** constraints are Field key 4 and TypeDefinition key 3. Discovery serves them and the fingerprint covers them. See WireProtocol.md, section 8.4.

## Schema evolution

A contract changes without a version bump. Add fields with `.optional(...)` or a `default:`, retire removed ones with `Reserved`, and mark what is on its way out with `deprecated:`:

```swift
#schema("shelf") {
    Enum("Size") {
        Case("small")
        Case("large")
        Case("huge", deprecated: "use large")
    }
    Call("list", deprecated: "use search") {
        Access { .read }
        Request {
            Field("query", .string)
            Reserved(1, "author")
            Field("limit", .int, constraints: .range(1...100), default: 50)
            Field("size", "Size", default: "small")
            Field("legacy", .optional(.string), deprecated: "ignored")
        }
        Response { Field("count", .uint) }
    }
}
```

- **A default on a field that is not optional is a wire default.** The field travels as an optional, so a peer that knows nothing of defaults reads it as one. The generated type holds the bare value (`limit: Int = 50`), reads an absent key or a `nil` as the default, and always writes the field. A default is a literal of the field's kind: a boolean, an integer, a floating number, a string, an enum case's name, or a duration's ISO 8601 text (`default: "PT30S"`, held as an `MMDuration`). It keeps the field's constraints; `#schema` refuses one that does not, and one on a kind that takes no default (`bytes`, a date, an array, a structure). On an `.optional(...)` field, `default:` stays what it was: a CLI default that never reaches the wire.
- **`Reserved` retires keys and names.** `Reserved(1, "author")` takes any mix of integer keys and string names. A later field may not pin a reserved key or take a reserved name, and unpinned fields skip reserved keys, so reserving a removed field keeps the keys after it where they were. Reservations are a declaration rule: never served, hashed or compared.
- **`deprecated:` is documentation.** It goes on a field, an enum or union case, a type, or a call, with a reason or `""`. A deprecated generated struct field is `@available(*, deprecated)`, and the generated memberwise initializer still takes it. Everywhere else it is a doc-comment note. Discovery serves every deprecation (WireProtocol.md, section 8). The generated CLI marks deprecated calls and options in its help, and warns on stderr when a deprecated call runs or a deprecated option or enum value is given.
- **The fingerprint** covers a default (a changed default is a contract change) and never a deprecation or a reservation. See WireProtocol.md, section 9.1.

## Schema composition

A named type can hold itself, and fields shared by several blocks are declared once:

```swift
#schema("outline") {
    let audit = FieldGroup {
        Field("author", .string)
        Field("written", .timestamp)
    }
    Type("Node") {
        Field("title", .string)
        Field("parent", .optional(.reference("Node")))
        Field("children", .array(.reference("Node")))
        audit
    }
    Union("Expression") {
        Case("number") { Field("value", .int) }
        Case("sum") {
            Field("left", "Expression")
            Field("right", "Expression")
        }
    }
    Call("evaluate") {
        Access { .read }
        Request {
            Field("expression", "Expression")
            Field(
                "rounding",
                .enumeration(cases: [.init(name: "down"), .init(name: "nearest")]),
                default: "nearest"
            )
        }
        Response {
            Field("value", .int)
            audit
        }
    }
}
```

- **Recursive types.** A type may hold itself directly or through other named types, through an optional, a nested `Field("x") { ... }` structure, a union case, an array or a map. On the wire a value nests only as deep as it does. Swift lays out a struct's properties inline, so `#schema` keeps a field that holds its own type through an optional or a nested structure in an `MMIndirect` box (`@MMIndirect public var parent: Node?`), and makes a union case that holds its union `indirect`. The property types, the initializers, equality and the wire bytes are what they would be without the box. A type whose every value would hold another value of its cycle without end (`Field("next", "Node")` with no optional on the way) is refused at compile time.
- **Field groups.** `let audit = FieldGroup { ... }` declares fields once; a bare `audit` among a block's fields (a `Type`'s, a union case's, a call part's, a nested structure's) puts them there. Their keys are assigned as if they were written in that place: an unpinned field takes the smallest key the block has not used, a pinned one keeps its pin. So a field added to a group moves the keys of the unpinned fields after the group, in every block that uses it: use groups after a block's own fields, or pin keys, where keys have to stay. The wire, discovery and the fingerprint see only the fields. `#schema` expands a group declared with `let` at the top of its block; the runtime DSL takes one declared anywhere.
- **Inline enumerations.** A field may list its cases in place: `.enumeration(cases: [...])`, inside an optional, an array or a map's values too. `#schema` generates a nested enum named after the field (`EvaluateRequest.Rounding`) with the same `unknown` case and coding as a named `Enum`, and the contract keeps the inline enumeration, so the wire and the fingerprint are what the runtime DSL gives. A default names one of its cases. The enum's name must be free in the type that holds it: `#schema` refuses one that another field, a nested type, a generated member, or a type a field names already takes. An error case's fields and a call's CLI options name a declared `Enum` instead.
- **One block at a time.** A macro reads only its own block. A type from another container is a Swift type (`Field("meta", CommonTypes.LineMeta.self)`) whose shape `#schema` never sees: it can't check a default against one, or box a field on a cycle that runs through one. And the compiler doesn't let a macro's arguments use what another macro generated in the same module, so a shared `#schemaTypes` container goes in a module of its own.
- **Two spellings of one reference.** The runtime DSL names another container's type by its qualified wire name, a dotted reference; `#schema` names it by its Swift type, whose `schema` is that same qualified reference. Both declare one contract:

  | Runtime DSL (`Schema`) | `#schema` |
  | --- | --- |
  | `Field("meta", "common.LineMeta")` | `Field("meta", CommonTypes.LineMeta.self)` |
  | `Response(.reference("common.LineMeta"))` | `Response(CommonTypes.LineMeta.self)` |

  `#schema` refuses the dotted form: it can't know the Swift type behind a wire name, and it has to name that type in the code it generates.

## Authorization model

Entities are dotted paths (`box.item`) in a tree. Each has an `EntityACL`, like a file: owner uid, group gid, and a 9-bit rwx/ugo mode.

- Peer identity comes from kernel credentials on Unix sockets. In v1, TCP peers are `anonymous` and match only the _other_ class. uid 0 is not special.
- **The first matching class wins.** If the owner matches, only owner bits count, even if group or other bits grant more.
- Dispatch needs `.execute` on **every ancestor prefix** of the target, outermost first (like directory x bits). Then it needs the method's access class (r, w, or x) on the target.
- An entity with no ACL record gives `permissionDenied`, so existence is never revealed. Calls on the root are denied unless the call's target, or the route, accepts the `.root` pattern.
- Grants are per entity and mode, never per method (a file's read bit applies to every program). When one tree serves several method families, declare what each call targets with `Target` in its contract, once for a namespace or per call (a call's own replaces the namespace's):
  - `Target("journal.*")`: a subtree.
  - `Target("system.log", "system.audit")`: exact entities.
  - `Target("tenants.*.journal.*")`: `*` matches exactly one segment; a trailing `.*` matches any depth.
  - `Target(.root, .all)`: root plus everything, for tree-wide methods like discovery.

  A target is contract: discovery serves it, the fingerprint hashes it, and a changed target is drift. The generated CLI shows it in help, completes its literal prefix, and refuses an entity outside it before connecting. A route without `Accepts` takes its call's target. `On(Journal.read, Accepts("journal.notes")) { ... }` narrows it for one deployment, never widens it: an `Accepts` outside the target stops the daemon at startup. With no target, `Accepts` alone decides, in the same patterns.

  Other targets are denied before the ACL check, with the usual denial. A target naming one concrete entity also accepts calls without an entity (no `on:` in the client, no `<entity>` in the CLI). The server uses that entity and authorizes it normally.

The target entity is in the open envelope, so no params byte is read until every check passes.

## Observability

Server and client emit [swift-metrics](https://github.com/apple/swift-metrics) instruments with stable `mm_server_*` / `mm_client_*` labels: connection lifecycle, frames, denials, dispatch latency, per-direction stream items, and credit stalls. The library never opens a metrics port. Bootstrap your backend (Prometheus, StatsD, OTel) once in the host process. Otherwise the built-in no-op handler discards everything at almost no cost. The integration guide's Observability section lists all labels, shows the wiring, and covers exposure security.

## Terminal status

A daemon or a CLI can tell the terminal what it is doing with the [Program Status Protocol](https://github.com/velocityzen/ProgramStatus) (OSC 7501), so a terminal that supports it shows each tab's state and can notify when it changes. It is opt-in, one part in the declaration:

```swift
MMService {
    Configuration(endpoint: .unix(path: socketPath))
    ACLProvider(provider)
    ProgramStatusReporting(app: "journald")
    For(Journal.self) { JournalHandlers(store: store) }
}

await MMCLI {
    Name("journal")
    Commands([Journal.Command.self])
    ProgramStatusReporting(app: "journal") {
        // Every event `journal follow` receives becomes a report the terminal can notify on.
        On(ChangeEvent.self) { event in .done(event.line, title: event.entity) }
    }
}
```

- The daemon reports `idle` "Listening on ..." once its endpoints are bound, `working` while it drains, then `idle` "Stopped". A bind that fails reports `error` with the reason.
- A command reports `working` with its call (`journal.read on journal.notes`), and `blocked` while it waits for lines typed into a terminal stdin. It ends with `done`, `error` with the line it wrote to stderr, or `idle` after Ctrl-C.
- An `On(...)` entry in the `ProgramStatusReporting { }` block turns each value a command prints, such as each element of a stream, into a report. Return nil to leave the record as it is. It is keyed by the value's type, as `Format` is, and only valid inside that block. The server's `On` takes a method instead.

Reports go to the controlling terminal, so they arrive even when stdout is piped. A process without one (launchd, systemd, CI) writes nothing, and terminals ignore sequences they do not know.

## Requirements

- Swift 6.4+ (strict concurrency). Everything runs on macOS 27+, Linux and Android. The client (`MMClient`, `MMSchema`, `MMWire`) also runs on iOS, iPadOS, tvOS, watchOS and visionOS 27+.
- Runtime dependencies (complete list): [swift-nio](https://github.com/apple/swift-nio), [swift-log](https://github.com/apple/swift-log), [swift-metrics](https://github.com/apple/swift-metrics), [fp-swift](https://github.com/velocityzen/fp-swift), [fp-swift-bracket](https://github.com/velocityzen/fp-swift-bracket), [fp-swift-service](https://github.com/velocityzen/fp-swift-service) (`FPService` for the server's shutdown fan-out, `ProcessSignals` for `MMCLI`), and [ProgramStatus](https://github.com/velocityzen/ProgramStatus) (terminal status for `MMServer` and `MMCLI`). The CLI example and tests also use [fp-swift-pipe](https://github.com/velocityzen/fp-swift-pipe). MessagePack is implemented in this repository. [swift-syntax](https://github.com/swiftlang/swift-syntax) is a compile-time-only dependency of the `#schema` macro and the `MMCLIGeneratorPlugin`. It is never linked into products.

## Installation

Add the package and choose your products. Clients need only `MMClient` + `MMSchema`. A daemon also needs a lifecycle to run the server's bracket; the examples use fp-swift-service:

```swift
dependencies: [
    .package(url: "https://github.com/velocityzen/mm.git", from: "1.0.0"),
    .package(url: "https://github.com/velocityzen/fp-swift-service.git", branch: "main"),
],
targets: [
    .target(name: "MyDaemon", dependencies: [
        .product(name: "MMServer", package: "mm"),
        .product(name: "MMSchema", package: "mm"),
        .product(name: "FPService", package: "fp-swift-service"),
    ])
]
```

## Documentation

The DocC API reference is built from `Sources/<Target>/<Target>.docc` and hosted on the [Swift Package Index](https://swiftpackageindex.com/velocityzen/mm). [.spi.yml](.spi.yml) builds every library target.

- [MMWire](https://swiftpackageindex.com/velocityzen/mm/documentation/mmwire): MessagePack coding, framing, the envelope, the hello preamble.
- [MMSchema](https://swiftpackageindex.com/velocityzen/mm/documentation/mmschema): method descriptors, the contract DSL and `#schema` macro, ACLs, the fingerprint.
- [MMServer](https://swiftpackageindex.com/velocityzen/mm/documentation/mmserver): router, authorization, streaming handlers, service bootstrap.
- [MMClient](https://swiftpackageindex.com/velocityzen/mm/documentation/mmclient): typed calls, streaming handles, discovery.
- [MMCLI](https://swiftpackageindex.com/velocityzen/mm/documentation/mmcli): the schema-generated CLI runtime.

Long-form guides are DocC articles in the same catalogs (also readable in the repository):

- [Wire protocol specification](Sources/MMWire/MMWire.docc/WireProtocol.md) (MMWire): the normative byte-level spec: framing, hello, envelope, ACL semantics, fingerprint, conformance vectors.
- [VPTS specification](Sources/MMWire/MMWire.docc/VPTS.md) (MMWire): the variable-precision timestamp codec used by the wire's calendar and clock kinds.
- [Duration specification](Sources/MMWire/MMWire.docc/Duration.md) (MMWire): the binary form of the wire's duration kind.
- [Integration guide](Sources/MMServer/MMServer.docc/IntegrationGuide.md) (MMServer): embedding the router and an `EntityACLProvider` in a host daemon.
- [Remote access](Sources/MMServer/MMServer.docc/RemoteAccess.md) (MMServer): SSH Unix-socket forwarding, socket permissions, systemd/launchd recipes, troubleshooting.
- [Examples](Examples/README.md): a runnable daemon and client pair covering the whole library.

### For AI agents

[agents/mm/SKILL.md](agents/mm/SKILL.md) is a short guide for coding agents: the contract → server → client workflow, the authorization model, common pitfalls, and project rules, with links to deeper docs. Add it to the agent's context. For Claude Code auto-discovery, copy or symlink it to `.claude/skills/mm/SKILL.md` in your project.

## Build and test

```sh
swift build
swift test                         # full suite
swift test --filter MMWireTests    # one test target
```

Tests use Swift Testing (`import Testing`) in three tiers: `EmbeddedChannel` for channel handlers, plain unit tests for domain logic, and integration tests over real Unix sockets in a temp directory.

### Benchmarks

`Benchmarks/` is a separate package, built on [benchmark](https://github.com/ordo-one/benchmark), so library users never resolve it. It counts allocations and syscalls rather than timing: those come out the same on every run, so a change in them is a change in the code. `MMWireBenchmarks` covers the envelopes, the MessagePack coders on `#schema` types, and the framing. `MMServerBenchmarks` covers `Router.dispatch` for unary calls, deep entities, denials and unknown methods.

```sh
swift package --package-path Benchmarks benchmark                                  # all of them
swift package --package-path Benchmarks benchmark --filter 'Router.*'              # a subset
swift package --package-path Benchmarks benchmark --metric wallClock               # timing instead
swift package --package-path Benchmarks benchmark --filter MMPackEncoder.item --allocation-stacks
```

CI holds the counts to `Benchmarks/Thresholds/linux`, measured on x86_64 Linux (macOS counts differ). A count that moves either way fails the job, which then prints the measured counts as a diff and uploads them as the `benchmark-thresholds` artifact, to commit with the change. On macOS, compare against a baseline of your own:

```sh
swift package --package-path Benchmarks --allow-writing-to-package-directory benchmark baseline update main
swift package --package-path Benchmarks benchmark baseline compare main
```

## Versioning

The wire protocol version is a single `u8`, currently **1**, independent of the package version. Packages follow semantic versioning. The protocol version changes only on wire-level breaks. Hello negotiation picks the lower version. A fingerprint mismatch triggers discovery, never a disconnect. Schemas evolve without version bumps: payloads are int-keyed maps, unknown keys are skipped, new fields must be optional or have a default, removed fields' keys and names are reserved, and an enum value or union case a peer does not declare is kept and written back unchanged. See [Schema evolution](#schema-evolution).

A contract lock, a committed file that a build or test compares the current contract against to catch an accidental breaking change, is pending the contract diff it builds on (MM-72).

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

`MMSchema` has no internal dependencies. `MMWire` depends on `MMSchema` (the VPTS codec for wire time kinds lives there). `MMServer` and `MMClient` depend on both. `MMCLI` depends on `MMClient`. Client-only processes can import `MMSchema`.

## Design principles

- **The declaration is the source of truth.** One `#schema` block defines the wire contract. Payload structs, typed descriptors, the discovery response, and the fingerprint come from it. At boot, the daemon checks it against its compiled types and refuses to listen on a mismatch. The client checks and diffs it against a live server.
- **Authorization before payload.** The target entity is envelope metadata, not payload. The router checks traversal on every ancestor, then the method's access class, before it decodes any params byte.
- **POSIX, not tokens.** Identity is kernel peer credentials on Unix sockets. No identity data crosses the wire. Permissions are owner/group/other rwx bits on an entity tree. See [Authorization model](#authorization-model).
- **Bounded everything.** Frame length, connections, in-flight calls, and per-direction stream windows are capped. Counts from the wire never size allocations. A slow consumer pauses the producer, so memory does not grow.
- **Termination is graceful and typed.** See [Streaming](#streaming).
- **Evolution without version bumps.** The protocol version is 1 and stays 1. See [Versioning](#versioning).
- **Resources, not services.** The server and the client connection are brackets: acquire starts one, dispose stops it, and whatever runs in between is owned by that scope. The host composes them with its own resources and owns the lifecycle. No GCD, no free-floating tasks, no automatic reconnection. The application sets the retry policy, using `stateUpdates()`.
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
        // (with a generated `unknown` fallback case) and referenceable
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

// server is a BracketAsync<SocketAddress, MMServiceError>: acquire binds and
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

Because the server is a bracket, it composes with the rest of your daemon. With `BracketAsyncDo`, resources start in order and stop in reverse. A resource bound after the server starts only once the socket accepts connections, and stops before the server drains. The bracket's resource is the bound address, such as the port of a `.tcp(host:port: 0)` endpoint.

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

Daemons compose the client into their own bracket, next to their other resources, exactly like the server. The library never reconnects: a closed connection stays closed. The application owns retry policy, using `stateUpdates()`.

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

**What `journal.notes` is, and why it is not in the schema.** Every call applies a verb to a noun. The schema declares verbs and payloads: `journal.append` needs `-w-` on its target and carries `{line}`. The nouns are **entities**: the runtime tree the daemon manages, declared server-side with ACLs (`Entity("journal") { Entity("notes"); Entity("system", owner: 0, mode: 0o700) }`, see [Authorization model](#authorization-model)). Compare syscalls and file paths: `/etc/passwd` is not in the syscall table, but `cat` needs a path. Adding or removing entities does not change the schema or the fingerprint. The same verb can be denied on another entity, as `journal.system` shows. In `mm journal add journal.notes`, the first `journal` is the command group (the method namespace). The entity path uses the same prefix only by convention (discovery filters methods by their prefix entity).

Every command takes the entity as an optional positional, after any required positional fields (ArgumentParser fills positionals greedily). Request fields default to `--field-name` options. Positional style is opt-in: `Field("line", .string, cli: .argument)` gives `mm journal add "hello" journal.notes`, as in the runnable example in `Examples/`.

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

## Authorization model

Entities are dotted paths (`box.item`) in a tree. Each has an `EntityACL`, like a file: owner uid, group gid, and a 9-bit rwx/ugo mode.

- Peer identity comes from kernel credentials on Unix sockets. In v1, TCP peers are `anonymous` and match only the _other_ class. uid 0 is not special.
- **The first matching class wins.** If the owner matches, only owner bits count, even if group or other bits grant more.
- Dispatch needs `.execute` on **every ancestor prefix** of the target, outermost first (like directory x bits). Then it needs the method's access class (r, w, or x) on the target.
- An entity with no ACL record gives `permissionDenied`, so existence is never revealed. Calls on the root are denied unless the route accepts the `.root` pattern.
- Grants are per entity and mode, never per method (a file's read bit applies to every program). When one tree serves several method families, declare what each route accepts:
  - `On(Journal.read, Accepts("journal.*")) { ... }`: a subtree.
  - `Accepts("system.log", "system.audit")`: exact entities.
  - `Accepts("tenants.*.journal.*")`: `*` matches exactly one segment; a trailing `.*` matches any depth.
  - `Accepts(.root, .all)`: root plus everything, for tree-wide methods like discovery.

  Other targets are denied before the ACL check, with the usual denial. A route naming one concrete entity also accepts calls without an entity (no `on:` in the client, no `<entity>` in the CLI). The server uses that entity and authorizes it normally.

The target entity is in the open envelope, so no params byte is read until every check passes.

## Observability

Server and client emit [swift-metrics](https://github.com/apple/swift-metrics) instruments with stable `mm_server_*` / `mm_client_*` labels: connection lifecycle, frames, denials, dispatch latency, per-direction stream items, and credit stalls. The library never opens a metrics port. Bootstrap your backend (Prometheus, StatsD, OTel) once in the host process. Otherwise the built-in no-op handler discards everything at almost no cost. The integration guide's Observability section lists all labels, shows the wiring, and covers exposure security.

## Requirements

- Swift 6.4+ (strict concurrency), macOS 26+ or Linux.
- Runtime dependencies (complete list): [swift-nio](https://github.com/apple/swift-nio), [swift-log](https://github.com/apple/swift-log), [swift-metrics](https://github.com/apple/swift-metrics), [fp-swift](https://github.com/velocityzen/fp-swift), [fp-swift-bracket](https://github.com/velocityzen/fp-swift-bracket), and [fp-swift-service](https://github.com/velocityzen/fp-swift-service) (`FPService` for the server's shutdown fan-out, `ProcessSignals` for `MMCLI`). MessagePack is implemented in this repository. [swift-syntax](https://github.com/swiftlang/swift-syntax) is a compile-time-only dependency of the `#schema` macro and the `MMCLIGeneratorPlugin`. It is never linked into products.

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
- [VPTS specification](Sources/MMWire/MMWire.docc/VPTS.md) (MMWire): the variable-precision timestamp codec used by the wire time kinds.
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

## Versioning

The wire protocol version is a single `u8`, currently **1**, independent of the package version. Packages follow semantic versioning. The protocol version changes only on wire-level breaks. Hello negotiation picks the lower version. A fingerprint mismatch triggers discovery, never a disconnect. Schemas evolve without version bumps: payloads are int-keyed maps, unknown keys are skipped, and new fields must be optional.

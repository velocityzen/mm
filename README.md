# matter-in-motion

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Fmm%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/velocityzen/mm)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Fmm%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/velocityzen/mm)
[![Documentation](https://img.shields.io/badge/documentation-DocC-blue)](https://swiftpackageindex.com/velocityzen/mm/documentation)

A Swift library implementing a binary RPC protocol over Unix domain sockets and TCP: length-prefix framing with a compact tagged-array MessagePack envelope (calls, terminals, and stream frames), schemas expressed as plain Swift values with runtime discovery, and filesystem-style (rwx / user-group-other) authorization enforced by a message router backed by kernel peer credentials. SwiftNIO is the async runtime; the public API is structured concurrency with typed `Result` errors, lifecycle-managed by swift-service-lifecycle.

## Modules

One package, `MatterInMotion`, four library products:

- `MMWire` — MessagePack coder over `ByteBuffer`, `[u32 LE length][payload]` framing, the RPC envelope, the hello preamble. Depends on NIOCore only.
- `MMSchema` — Method descriptors, `TypeSchema` and the schema fingerprint, `EntityACL`, `PeerIdentity`. Pure values: no NIO import, no IO.
- `MMServer` — `Router` with a result-builder DSL, authorization, peer-credential capture, streaming handlers, `MMService` bootstrap.
- `MMClient` — `MMClientConnection`: typed unary and streaming calls with msgid multiplexing, credit-based flow control, schema discovery.
- `MMCLI` — the runtime behind schema-generated command-line tools (swift-argument-parser): connection options, exit-code mapping, stream drivers, `discover` and raw `call` commands.

Dependency direction: `MMWire` and `MMSchema` depend on nothing internal; `MMServer` and `MMClient` depend on both; `MMCLI` sits on `MMClient`. `MMSchema` stays importable by client-only processes.

## Design principles

- **The declaration is the source of truth.** A wire contract is written exactly once — one `#schema` block — and everything else derives from it: payload structs, typed descriptors, the discovery response, the fingerprint. Both sides hold themselves to it: the daemon verifies the contract against its own compiled types at boot (and refuses to listen on drift), the client verifies and diffs it against a live server.
- **Authorization before payload.** The call's target entity is envelope metadata, not payload. The router authorizes the envelope's entity slot — traversal on every ancestor, then the method's access class — before a single params byte is decoded.
- **POSIX, not tokens.** Identity is kernel-attested peer credentials on Unix sockets; nothing identity-shaped ever crosses the wire. Permissions are owner/group/other rwx bits on an entity tree with directory-style traversal, resolved first-matching-class-wins. uid 0 is not special, and everything fails closed: a missing ACL record denies without leaking existence.
- **Bounded everything.** Frame length, connections, in-flight calls, and per-direction stream windows are all capped; wire-supplied counts never size allocations. Backpressure is end-to-end — a slow consumer parks the producer instead of growing memory, with no head-of-line blocking between sibling streams.
- **Termination is graceful and typed.** END finishes your own direction, STOP asks the peer to finish theirs (surfaced as `.peerStopped`, never an error), CANCEL aborts the call. Every call ends with exactly one terminal response.
- **Evolution without version bumps.** The protocol version is 1 and stays 1: payloads are int-keyed maps, unknown keys are skipped, new fields must be optional, and a fingerprint mismatch triggers discovery — never a disconnect.
- **Structured concurrency, no hidden tasks.** The public API is async/await with typed `Result` errors; the client's inbound loop runs as the host's structured child; lifecycle belongs to `ServiceGroup`. No GCD, no free-floating tasks, no reconnection magic — retry policy is the application's, driven by `stateUpdates()`.

## Quick start

The wire contract is written exactly once, declaratively. `#schema` generates everything it implies: the request/response/element structs (integer-keyed MessagePack maps; the call's target entity rides the open envelope, so payloads are plain values), the typed descriptors, the namespace list, and a runtime contract you can verify against and diff with a live server:

```swift
import MMSchema

public enum Echo: MethodNamespace {
    #schema("echo") {
        // Named types are part of the contract: string-valued wire enums
        // (with a generated `unknown` fallback case) and referenceable
        // structs. Descriptions are served by discovery — the contract
        // documents itself — and never affect compatibility.
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

Declare the whole server — configuration, ACL table, handlers — and run it in a `ServiceGroup`:

```swift
import Foundation
import Logging
import MMServer
import ServiceLifecycle

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
                    break  // .peerStopped / .callEnded — wrap up
                }
            }
            return .success(Echo.WatchResponse(count: request.count))
        }
    }
}

let logger = Logger(label: "echo")
let group = ServiceGroup(configuration: .init(
    services: [.init(service: server)],
    gracefulShutdownSignals: [.sigterm],
    cancellationSignals: [.sigint],
    logger: logger
))
try await group.run()
```

Handlers can also live in reusable `RouteGroup` types — their own files, their own dependencies — and drop into the `For` block as values. Every server auto-registers the builtins `server.schema` (discovery, filtered by the caller's traversal rights) and `server.entity` (an entity's ACL record).

### Client

The simple shape is the bracket — one scope owns the whole connect → run → close lifecycle, no hidden tasks and nothing to leak. `with` is sugar over `MMClientConnection.open`, the live connection as an FPBracket resource (acquire connects and starts the inbound loop; dispose closes and joins it):

```swift
import MMClient

let main = try! EntityName.parse("echo.main").get()
let reply = await MMClientConnection.with(.unix(path: "/tmp/echo.sock")) { connection in
    await connection.call(Echo.run, on: main, Echo.RunRequest(value: 42, mode: .shouted))
}
// Result<Result<Echo.RunResponse, MMCallError>, MMClientError>:
// the outer layer is the connection — .failure means connect failed or the
// connection did not survive the scope (a transport error or protocol
// violation while the body ran; a clean EOF or the bracket's own close
// releases successfully). The inner layer is your call.
```

One connection multiplexes many calls (msgid-correlated, concurrent callers welcome, bounded by `maxInFlightCalls`) — open one per unit of work, never per call.

When the body needs its own choreography (concurrent streams, staged teardown), it happens *inside* the bracket as structured children — the bracket still owns the lifecycle around it. For the commonest case, a stream consumed alongside other calls, `withStream(_:each:_:)` packages the split (`each` runs in a structured sibling that grants credit as it consumes; the trailing closure is your main flow, free to use the connection; the join is built in — it returns only after the stream ended):

```swift
let outcome = await MMClientConnection.with(.unix(path: "/tmp/echo.sock")) { connection in
    let main = try! EntityName.parse("echo.main").get()

    // Server-streaming call: a typed, backpressured AsyncSequence of elements
    // plus a terminal result. `stop()` asks the server to wrap up gracefully,
    // `cancel()` aborts.
    let watch = await connection.call(Echo.watch, on: main, Echo.WatchRequest(count: 5))
    let reply = await withStream(watch, each: { event in
        print(event.value)              // ends on server END, terminal, or close
    }) {
        // Typed call on the same connection while events flow:
        // Result<Echo.RunResponse, MMCallError>.
        await connection.call(Echo.run, on: main, Echo.RunRequest(value: 42, mode: .shouted))
    }
    let summary = await watch.result()  // Result<Echo.WatchResponse, MMCallError>
    return (reply, summary)
}
```

Daemons drop `MMClientConnectionService(connection:)` into their `ServiceGroup` instead of using the bracket. Reconnection is deliberately out of scope: a closed connection stays closed, and retry policy belongs to the application, driven by `stateUpdates()`.

### CLI

The same declaration can generate a command-line tool. `#schema("echo", cli: .enabled)` additionally emits one swift-argument-parser command per call — names, `--help` text, and argument shapes all from the contract — plus a namespace group; the file then imports `ArgumentParser` and `MMCLI`. A `CLI(...)` part renames or omits commands, `Field(..., cli:)` shapes arguments (positional, flag, short, renamed, omitted), and none of it touches the wire: the overlay is never served, fingerprinted, or compared.

```swift
Call("append", description: "Appends one line to a journal") {
    CLI(.command("add", aliases: ["append"]))      // wire: journal.append — CLI: journal add
    Access { .write }
    Request {
        Field("line", .string, description: "The line text")
    }
    Response { Field("count", .int) }
}
```

Mount the generated group in a root command and the whole tool is a few lines:

```swift
@main
struct MM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mm",
        subcommands: [Journal.Command.self]
    )
}
```

```sh
$ mm journal add journal.notes --line "hello" --socket /tmp/mm.sock
{"count":1}
$ mm journal add journal.system --line "nope" --socket /tmp/mm.sock
denied: journal.append on journal.system            # exit code 77
```

**What `journal.notes` is — and why it is not in the schema.** Every call binds a verb to a noun. The schema declares the verbs and their payload shapes (`journal.append` needs `-w-` on its target and carries `{line}`); the nouns are **entities** — the runtime tree of things the daemon manages, declared server-side with their ACLs (`Entity("journal") { Entity("notes"); Entity("system", owner: 0, mode: 0o700) }`, see [Authorization model](#authorization-model)). Think syscall table versus file paths: nobody lists `/etc/passwd` in the syscall table, and `cat` still needs a path. Entities are created and destroyed without any schema change — the fingerprint never moves — and the same verb against a different entity can be a denial, as `journal.system` shows above. The two `journal`s in `mm journal add journal.notes` are different things: the command group comes from the method namespace, the entity path merely lives under the same prefix by convention (discovery filters methods by their prefix entity).

So the entity is the one argument every command has, always the leading positional. Request fields default to `--field-name` options; opting a field into positional style is explicit — `Field("line", .string, cli: .argument)` turns the same command into `mm journal add journal.notes "hello"` (the shape the runnable example in `Examples/` uses).

Unary calls print their response as JSON (`--output json-pretty` to taste); server-stream commands print elements as JSON lines with SIGINT mapped to a graceful STOP; client-stream commands read stdin. `MMCLI` also ships schema-driven generic commands: `discover` (what the server serves) and `call` (invoke any method by wire name with `--params` JSON).

**Schema verification is automatic — never manual.** Every generated command confirms its own namespace against the live server before dispatching (one scoped discovery diff; drift prints the difference and exits 76; `--no-verify` skips it for one invocation). A purpose-built CLI upgrades that to a free check: bind the build-time defaults around the root command's run — `await withCLI(MMCLIDefaults(serverContract: .complete([journalContract]), endpoint: .unix(path: socketPath))) { await MM.main() }` (a task-local: build-time knowledge, no process-global state; the endpoint default makes `--socket`/`--tcp` optional) — and the expected whole-server hello fingerprint is folded at build time from the same declarations the daemon compiled (builtins included), so a matching hello proves the entire composition with zero extra round-trips; on mismatch, commands fall back to the scoped diff of the namespace in use. A server that registers shared `Types(...)` containers folds their definitions too — pass the same declarations (`sharedTypes:`) to the claim, or it can never match. Embedding clients get the same automation: set `configuration.schema = .complete([journalContract])` (or `.partial` for a client that uses a slice of the server; both take `sharedTypes:` when the server registers shared `Types(...)` containers) and the connection verifies itself right after connect — `await connection.verify()` yields `.ok` (whole composition proven from the hello), `.partial` (your contracts are in sync; the composition changed elsewhere), or `.difference(differences)` — never a disconnect. For humans and scripts there is still the explicit `verify` subcommand per group — there is no manual fingerprint anywhere, CLI or library; the fingerprint is build knowledge folded from contracts, never something an operator types.

## Streaming

Every method declares four independent parts — an opening `Request`, a client-push `RequestStream`, a server-push `ResponseStream`, and a terminal `Response` — freely combinable; a unary call is the degenerate case with no stream parts. Server push is an ordinary method with a `ResponseStream`: correlated to a msgid, authorized once at open on the request's entity, fingerprinted, and discoverable — there is no separate notification mechanism.

- **Descriptors:** `ServerStreamMethod` (server → client), `ClientStreamMethod` (client → server), `BidirectionalStreamMethod` (both). Handlers get a credit-gated `MMResponseSink` to push elements and/or an `MMRequestStream` AsyncSequence of inbound elements; clients get an `InboundStreamHandle` (an element `AsyncSequence` plus `result()`/`stop()`/`cancel()`), an `OutboundStreamHandle` (`send()`/`finish()`/`result()`), or a two-halved `BidirectionalStreamHandle`.
- **Credit-based flow control:** each direction starts with a window of 8 items; the receiver grants more (watermark-batched) as its consumer drains. A sender at zero credit suspends — backpressure reaches the producing task and memory stays bounded, with no head-of-line blocking between sibling streams.
- **Graceful termination:** END finishes your own direction, STOP asks the peer to finish theirs (surfaced as a typed `.peerStopped`, never an error), and CANCEL aborts the whole call. Every call — unary or streaming — ends with exactly one terminal response, the client's signal of graceful versus failed. A handler relaying a quiet source observes STOP promptly via `sink.stopRequested()` instead of waiting for its next send.

## Authorization model

Entities are dotted paths (`box.item`) forming a tree. Each entity carries an `EntityACL` — owner uid, group gid, and a 9-bit rwx/ugo mode, exactly like a file:

- Peer identity comes from kernel credentials on Unix sockets; TCP peers are `anonymous` in v1 and match only the _other_ class. uid 0 is not special.
- Classes resolve **first-matching-class-wins**: an owner match is judged by the owner bits alone, even when group or other bits would grant more.
- Dispatch requires `.execute` on **every ancestor prefix** of the target entity (like directory x bits, outermost first), then the method's declared access class (r, w, or x) on the target itself.
- An entity with no ACL record is `permissionDenied` — existence is never leaked. Root-targeted requests are denied unless the route accepts them via the `.root` pattern.
- Grants are per-entity-per-mode, never per-method (the read bit on a file gates every program that opens it). When a daemon serves several method families over one tree, declare a route's target vocabulary: `On(Journal.read, Accepts("journal.*")) { ... }` (a subtree), `Accepts("system.log", "system.audit")` (exact entities), `Accepts("tenants.*.journal.*")` (a `*` segment matches exactly one segment; trailing `.*` is any depth), `Accepts(.root, .all)` (root plus everything, for tree-wide methods like discovery). Unaccepted targets are denied before the ACL is even consulted, indistinguishably from any other denial. A route naming exactly one concrete entity also accepts an entity-less call (`on:` omitted client-side, `<entity>` omitted in the CLI): the server infers the target and authorizes it as if spelled out.

Authorization runs before the request payload is touched at all: the target entity rides the open envelope, and no params byte is interpreted until every check passes.

## Observability

Both halves emit [swift-metrics](https://github.com/apple/swift-metrics) instruments under stable `mm_server_*` / `mm_client_*` labels — connection lifecycle, frames, denials, dispatch latency, per-direction stream items and credit stalls. The library never opens a metrics port: bootstrap the backend of your choice (Prometheus, StatsD, OTel) once in the host process, or the built-in no-op handler discards everything at near-zero cost. The full label inventory, wiring sketch, and exposure-security notes are in the integration guide's Observability section.

## Requirements

- Swift 6 (strict concurrency), macOS 15+ or Linux.
- Dependencies (the complete runtime list): [swift-nio](https://github.com/apple/swift-nio), [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle), [swift-log](https://github.com/apple/swift-log), [swift-metrics](https://github.com/apple/swift-metrics). MessagePack is implemented in-repo. ([swift-syntax](https://github.com/swiftlang/swift-syntax) is a compile-time-only dependency of the `#schema` macro plugin — never linked into products.)

## Installation

Add the package and pick the products you need (clients depend on `MMClient` + `MMSchema` only):

```swift
dependencies: [
    .package(url: "https://github.com/velocityzen/mm.git", from: "1.0.0")
],
targets: [
    .target(name: "MyDaemon", dependencies: [
        .product(name: "MMServer", package: "mm"),
        .product(name: "MMSchema", package: "mm"),
    ])
]
```

## Documentation

The API reference is DocC, generated from the catalogs in `Sources/<Target>/<Target>.docc` and hosted on the [Swift Package Index](https://swiftpackageindex.com/velocityzen/mm) ([.spi.yml](.spi.yml) builds all four targets):

- [MMWire](https://swiftpackageindex.com/velocityzen/mm/documentation/mmwire) — MessagePack coding, framing, the envelope, the hello preamble.
- [MMSchema](https://swiftpackageindex.com/velocityzen/mm/documentation/mmschema) — method descriptors, the contract DSL and `#schema` macro, ACLs, the fingerprint.
- [MMServer](https://swiftpackageindex.com/velocityzen/mm/documentation/mmserver) — router, authorization, streaming handlers, service bootstrap.
- [MMClient](https://swiftpackageindex.com/velocityzen/mm/documentation/mmclient) — typed calls, streaming handles, discovery.
- [MMCLI](https://swiftpackageindex.com/velocityzen/mm/documentation/mmcli) — the schema-generated CLI runtime.

The long-form guides ship as DocC articles inside those catalogs (hosted with the reference, readable in-repo too):

- [Wire protocol specification](Sources/MMWire/MMWire.docc/WireProtocol.md) — the normative byte-level spec: framing, hello, envelope, ACL semantics, fingerprint, conformance vectors (under MMWire).
- [Integration guide](Sources/MMServer/MMServer.docc/IntegrationGuide.md) — embedding the router and an `EntityACLProvider` in a host daemon (under MMServer).
- [Remote access](Sources/MMServer/MMServer.docc/RemoteAccess.md) — SSH Unix-socket forwarding, socket-permission and systemd/launchd recipes, troubleshooting (under MMServer).
- [Examples](Examples/README.md) — a runnable daemon + client pair exercising the full story.

### For AI agents

[agents/mm/SKILL.md](agents/mm/SKILL.md) is a condensed implementation guide for coding agents: the contract → server → client golden path, the authorization model, the sharp edges, and the house rules, with pointers into the deeper docs. Include it in the agent's context when building against this library — or, for Claude Code auto-discovery, copy or symlink it to `.claude/skills/mm/SKILL.md` in your project.

## Build and test

```sh
swift build
swift test                         # full suite
swift test --filter MMWireTests    # one test target
```

Tests use Swift Testing (`import Testing`) in three tiers: `EmbeddedChannel` for channel handlers, plain unit tests for domain logic, and real temp-dir Unix-socket integration tests.

## Versioning

The wire protocol version is a single `u8`, currently **1**, and is deliberately decoupled from the package version: package releases follow semantic versioning, while the protocol version only changes on wire-level breaks. Hello negotiation is min-wins, and a schema fingerprint mismatch triggers discovery, never a disconnect — schema evolution rides on optional fields and skipped unknown keys, not version bumps.

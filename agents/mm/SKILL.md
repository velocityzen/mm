---
name: mm
description: Implement, extend, or debug a matter-in-motion (mm) RPC server or client in Swift. Use this skill whenever the task involves MMService, MMClientConnection, a #schema contract, EntityACL tables, RPC handlers, streaming (follow/import-style calls), or any daemon/client that talks over this library's Unix-socket/TCP protocol. Use it even if the user just says "add a method", "expose X over the socket", "write a client for the daemon", or "the call is denied". Also use it before reviewing or refactoring code that imports MMWire, MMSchema, MMServer, or MMClient.
---

# Implementing a matter-in-motion server and client

matter-in-motion is a binary RPC library: length-prefixed MessagePack envelopes over Unix domain sockets (or TCP). Schemas are Swift values, declared once. Authorization uses rwx/ugo modes, checked against kernel peer credentials. `Examples/` (API + Daemon + Client) has runnable code for every pattern below.

Choose products by role. Keep this dependency direction:

- Shared contract module: `MMSchema` only. Never import server or client.
- Daemon: `MMServer` + `MMSchema` (+ swift-service-lifecycle, swift-log).
- Client process: `MMClient` + `MMSchema`. Never link `MMServer`.

## Step 1: declare the contract once, with `#schema`

Put the contract in its own module, so clients can import it without the server. One macro block generates the payload structs, typed descriptors, `all`, `types`, and a runtime `contract`. There is no second copy to sync:

```swift
import MMSchema

public enum Journal: MethodNamespace {
    #schema("journal", description: "Append-only journals.") {
        Enum("Priority", description: "How urgent a line is") {
            Case("normal")
            Case("urgent")
        }
        Type("ChangeEvent", description: "One appended line") {
            Field("entity", .string)
            Field("line", .string)
        }
        Call("append", description: "Appends one line") {
            Access { .write }
            Request { Field("line", .string) }
            Response { Field("count", .int) }
        }
        // Server → client stream: an ordinary method with a ResponseStream:
        // correlated to one call, authorized once at open, discoverable.
        Call("follow") {
            Access { .read }
            ResponseStream(.reference("ChangeEvent"))
            Response("FollowSummary") { Field("delivered", .int) }
        }
        // Client → server stream: RequestStream; the terminal reports totals.
        Call("import") {
            Access { .write }
            RequestStream("ImportLine") { Field("line", .string) }
            Response("ImportSummary") { Field("imported", .int) }
        }
    }
}

// Generated types nest inside Journal; re-export for natural call sites.
public typealias ChangeEvent = Journal.ChangeEvent
public let journalContract: SchemaDeclaration = Journal.contract
```

Rules that keep the wire stable:

- A method has four independent, combinable parts: `Request`, `RequestStream`, `ResponseStream`, `Response`. Unary has no stream parts. No `Request` means an empty payload.
- `Call("@")` is the namespace **root call**: wire name `search`, not `search.run`. Generated members use `root` (`Search.root`, `RootRequest`, `RootCommand`). The CLI runs it as the group's default subcommand (`tool search`). One per schema. Discovery filters it by execute on its own name-entity, like its dotted siblings. With `Accepts("search")`, callers can omit the entity.
- The target entity travels in the **open envelope**, never the payload. Never add an `entity` request field for routing. Handlers read `context.entity`. Clients pass `on:`.
- Field keys are declaration-order integers. To evolve a schema, pin keys (`Field(3, "note", .string)`) and make new fields `.optional(...)`. Peers skip unknown keys, so old and new peers interoperate. The protocol version stays 1: evolve with optional fields, not versions.
- `Access { .read / .write / .execute }` is the permission class required on the target entity. Choose it like a file mode, not by HTTP semantics.
- Calendar/clock fields are wire kinds. Never model them as `.string` or an epoch `.int`:
  - `Field("day", .date)` (calendar date), `.datetime` (wall clock, no zone), `.timestamp` (absolute instant with offset).
  - Wire: VPTS binary (variable-precision timestamp codec, spec `Sources/MMWire/MMWire.docc/VPTS.md`). ISO 8601 strings appear only in JSON/CLI projections (spec §8.3).
  - Swift: `MMDate`/`MMDateTime`/`MMTimestamp`. Dependency-free and `Comparable`. Timestamps order by instant.
  - Math: `date + .month(1)` clamps month ends. Time components carry across days. `timestamp - other` is an exact `Duration`. `startDate..<endDate` iterates by day. `DateComponents` converts both ways.
  - The core types have no clock. For the current time, use the Foundation-gated `MMTimestamp.now()` (UTC) / `.now(in:)`, `MMDateTime.now(in:)`, `MMDate.today(in:)`.
- Discovery serves `description:`, but fingerprints ignore it. Editing it is not drift. This includes the namespace: `#schema("journal", description: "...")` (or `Schema("journal", description: "...")`) appears in discovery's `namespaces` list and becomes the generated CLI group's abstract.
- Any part can be a named type: `Request(.reference("X"))`, `ResponseStream(.reference("ChangeEvent"))`, or a `SchemaDescribable` Swift type. The macro then generates no struct for it.
- Put types shared across schemas in `#schemaTypes("common") { ... }`. Compiler limitation: in one module, a macro's arguments cannot see members another macro generated. Put shared containers in their own module, or hand-write `SchemaDescribable` types.
- Hand-written types also work. An empty request struct with no stored properties must declare `static var schema: TypeSchema { .structure(fields: []) }` (`SchemaDescribable`), because a decoder cannot probe it.

## Step 2: the server

Declare the daemon as data in `MMService { ... }` and pass it to a `ServiceGroup`. Verify the contract before listening, so drift fails at boot, not on the wire:

```swift
import Logging
import MMSchema
import MMServer
import ServiceLifecycle

switch journalContract.verify(against: Journal.self) {
    case .failure(let error): fatalError("schema probe failed: \(error)")
    case .success(let breaks) where !breaks.isEmpty: fatalError("contract drift: \(breaks)")
    case .success: break
}

let store = JournalStore()  // your state: an actor, injected into handlers

let service = MMService {
    Configuration(endpoint: .unix(path: socketPath))
    ACLProvider {
        // The ACL table IS an entity tree: children take relative paths,
        // inherit owner/group, default to mode 0o750.
        Entity("journal", owner: getuid(), group: getgid(), mode: 0o750) {
            Entity("notes")
            Entity("system", owner: 0, group: 0, mode: 0o700)
        }
    }
    Log(logger)
    // For(...) groups routes AND enrolls the startup cross-check: every
    // Journal method needs a handler here or the daemon refuses to boot.
    For(Journal.self) {
        JournalHandlers(store: store)
    }
}

let group = ServiceGroup(configuration: .init(
    services: [.init(service: service)],
    gracefulShutdownSignals: [.sigterm],   // drains, removes the socket
    cancellationSignals: [.sigint],
    logger: logger
))
try await group.run()
```

Put handlers in a reusable `RouteGroup` in its own file, holding its dependencies. `On` has one overload per method shape. The context (`auth` below) always carries the already-authorized `entity`:

```swift
struct JournalHandlers: RouteGroup {
    let store: JournalStore

    @RouterBuilder var routes: [Route] {
        On(Journal.append) { auth, request in
            .success(Journal.AppendResponse(count: await store.append(request.line, to: auth.entity)))
        }
        On(Journal.follow) { auth, request, sink in          // server-stream: + MMResponseSink
            var delivered = 0
            loop: for await event in store.follow(auth.entity) {
                switch await sink.send(event) {              // credit-gated: suspends on backpressure
                case .sent: delivered += 1
                case .peerStopped, .callEnded: break loop    // graceful outcomes, not errors
                }
            }
            // Quiet sources: a relay parked between events observes STOP only
            // on its next send. Watch `sink.stopRequested()` from a structured
            // sibling to terminal promptly (see the example daemon).
            return .success(Journal.FollowSummary(delivered: delivered))
        }
        On(Journal.import) { auth, request, elements in      // client-stream: + MMRequestStream
            var imported = 0
            for await element in elements {                  // sequence ends on the client's END
                _ = await store.append(element.line, to: auth.entity)
                imported += 1
            }
            return .success(Journal.ImportSummary(imported: imported))
        }
        // Bidirectional: { auth, request, elements, sink in ... }
    }
}
```

Server facts to design around:

- Handlers return `Result<Response, MMError>`. Codes 1 to 63 are reserved for the protocol. Application errors start at 64.
- Every server registers the builtins `server.schema` (discovery, filtered by the caller's traversal rights) and `server.entity`.
- Cross-connection fan-out (one connection's append feeding another's `follow` stream) is application code. For the safe registry pattern, see `Examples/Daemon/FollowerHub.swift`: synchronous `onTermination`, idempotent removal, never finish under the lock.
- Root-targeted requests (empty entity) are denied unless the route accepts them: `On(method, Accepts(.root, .all)) { ... }`.
- Dynamic authorization (SQLite, for example): implement `EntityACLProvider` and pass `ACLProvider(provider)`. The builder tree is shorthand for `InMemoryACLProvider`.
- Startup order (ServiceLifecycle starts services concurrently): `Ready(readiness)` fires a `ServiceReadiness` at bind. Wrap dependents in `GatedService` to start after it. `OnBind { address in }` reports ephemeral TCP ports.

## Step 3: the client

For simple call-and-return clients, use the bracket: one scope owns connect, run, close, and join. `with` is shorthand for `MMClientConnection.open`, the live connection as an FPBracket resource (acquire = connect + start the loop, dispose = close + join). Compose `open` with other brackets via `flatMap`/`BracketAsyncDo`:

```swift
let reply = await MMClientConnection.with(.unix(path: socketPath)) { connection in
    await connection.call(Journal.append, on: notes, Journal.AppendRequest(line: "hi"))
}
// Result<Result<AppendResponse, MMCallError>, MMClientError>: connection vs call
// failure. Dispose returns the loop's outcome: bracket .failure = connect failed OR
// the connection died mid-scope (transport error / protocol violation); clean EOF
// or the bracket's own close is .success.
```

One connection multiplexes many calls (msgids, concurrent callers, `maxInFlightCalls` limit). Open one per unit of work, never one per call.

Run custom flows (streams in sibling tasks, staged teardown) as structured children *inside* the bracket body. The bracket still owns the lifecycle:

```swift
import MMClient

let outcome = await MMClientConnection.with(.unix(path: socketPath)) { connection in
    let notes = try! EntityName.parse("journal.notes").get() // validated dotted path

    // Unary: Result<Journal.AppendResponse, MMCallError>
    let reply = await connection.call(Journal.append, on: notes, Journal.AppendRequest(line: "hi"))

    // Server-stream: withStream consumes in a structured sibling (iterating
    // grants credit) while the body drives the connection; the join is built
    // in. It returns once the sequence ends.
    let follow = await connection.call(Journal.follow, on: notes, Journal.FollowRequest())
    await withStream(follow, each: { change in
        print(change.line)
        if change.line == "more" { await follow.stop() }  // graceful; terminal still arrives
        // follow.cancel() aborts the whole call instead.
    }) {
        _ = await connection.call(Journal.append, on: notes, Journal.AppendRequest(line: "more"))
    }
    _ = await follow.result()          // Result<Journal.FollowSummary, MMCallError>

    // Client-stream: send through the credit-gated writer, END, await terminal.
    let imp = await connection.call(Journal.import, on: notes, Journal.ImportRequest())
    _ = await imp.send(Journal.ImportLine(line: "bulk"))
    await imp.finish()
    _ = await imp.result()

    return reply
}
```

In a daemon-style client, skip the bracket. Call `MMClientConnection.connect` and add `MMClientService(connection: connection)` to the `ServiceGroup`. It is a separate product: depend on `MMClientService` and `import MMClientService`.

Verify the schema like the server does:

```swift
switch await connection.discoverSchema() {
case .success(let schema):
    let difference = SchemaDifference(local: journalContract, remote: schema)
    print(difference)                  // "in sync" or the non-empty buckets
case .failure(let error): ...
}
```

A hello fingerprint mismatch never disconnects. Treat it as a signal to run discovery and degrade deliberately. There is no reconnection, by design: a closed connection stays closed. Watch `stateUpdates()` (`.connected` → `.closed(reason:)`). The application owns retry policy.

## Generating a CLI from the contract

A top-level `CLI(.enabled)` entry in the schema block generates one swift-argument-parser command per call, plus a `Journal.Command` group. Names, help text, and argument shapes come from the declaration. The `MMCLIGeneratorPlugin` build-tool plugin writes the commands into the CLI target (`plugins: [.plugin(name: "MMCLIGeneratorPlugin", package: "mm")]`). That target depends on `MMCLI` and `ArgumentParser`. The API module stays on `MMSchema` only, so the daemon never links MMCLI or ArgumentParser. Declare the namespace type at file scope (generated code extends it) and make it visible to the CLI module (`public` across modules).

- Rename or omit commands with a `CLI(...)` part: `CLI(.command("add", aliases: ["append"]))`, `CLI(.omitted)`. The default name is the kebab-cased call name.
- Shape arguments with `Field(..., cli:)`:
  - `.argument`: positional. Required ones come before the omittable `<entity>`. Optional and array ones come after it.
  - `.flag`: bools.
  - `.option("name", short: "n")`. `short: .auto` derives `-n` from the long name.
  - `.omitted`: optional fields only.
  - Unset: `--field-name` options. Wire enums become typed options (the `unknown` fallback is hidden and refused). Structure, map, and named-type fields take JSON literals.
  - `Field(..., default: <literal>)` on an optional field makes a hybrid option: bare `--format` uses the default, `--format yaml` parses, absent stays nil. Calendar/clock fields take `default: .now` (invocation time). Defaults are declaration metadata, never wire behavior.
- The overlay is presentation-only. It is stored on `MethodDeclaration`, never forwarded to `MethodSignature`, so it cannot affect discovery, fingerprints, or compatibility.
- Every command gets the shared connection options (`--socket`/`--tcp`, timeouts, `--output json|json-pretty|raw`), an optional `<entity>` positional (after any required positional fields), and sysexits-style exit codes (denied → 77, usage → 64, transport → 69, SIGINT → 130).
- The entity positional (`journal.notes`) never comes from the schema. The schema declares verbs and payload shapes. Entities are the daemon's runtime tree, declared server-side with ACLs (compare a syscall table with file paths). Never list entities in a contract. Never drop the entity argument from a command. It is optional at the call site: omitting it sends a root target. The server infers the target only if the route's `Accepts` names exactly one concrete entity. Other routes deny it.
- Server-stream commands print elements as JSON lines (SIGINT = graceful STOP, second SIGINT = CANCEL). Client-stream commands read stdin lines (plain lines for single-string-field elements, otherwise JSON; EOF = END). Bidirectional does both.
- `MMCLI` also ships `MMCLIDiscover` ("discover") and `MMCLIRawCall` ("call": any method by wire name, `--params` JSON, schema-driven) to mount beside generated groups.
- Verification is automatic. Each generated command diffs its own namespace against the server before dispatch. Drift exits 76. `--no-verify` skips it for one invocation. Denied discovery skips it with a note (call rights do not imply read on the namespace entity).
- A companion CLI is ONE declaration, the CLI counterpart of `MMService { }`: `await MMCLI { Name("mm"); Abstract("..."); Version("1.0.0"); Commands([Journal.Command.self, MMCLIDiscover.self, MMCLIRawCall.self]); Contract(.complete([journalContract])); Endpoint(.unix(path: wellKnownSocket)); Format(ChangeEvent.self) { ... } }`.
  - MMCLI builds and runs the root command. Do not write an AsyncParsableCommand root. A hand-written root uses the `run:` form instead.
  - For fields like `defaultSubcommand`, pass a full `Configuration(CommandConfiguration(...))`. Shorthand entries merge onto it.
  - Declarations bind as a task-local, not a process global.
  - `Endpoint` makes `--socket`/`--tcp` optional. `Output(.text)` sets the default format.
  - `--output text` uses a `Format(ChangeEvent.self) { ... }` declaration, else the type's `CustomStringConvertible` conformance, else JSON. JSON formats always bypass it, so scripts stay stable.
  - The whole-server hello fingerprint is computed at build time, builtins included, via `SchemaFingerprint.expected(serving:sharedTypes:)`. Pass the server's shared `Types(...)` declarations, or a server that registers `Types` never matches. A match makes verification free. A mismatch falls back to a diff.
- Client daemons get the same automation. Set `configuration.schema = .complete([...])` / `.partial([...])`, and the connection verifies itself after connect. `await connection.verify()` returns a `Result`: `.ok` / `.partial` / `.difference` (a soft verdict, never a disconnect), or the errors `.noExpectation`/`.denied`/`.failed`. `connection.verifyContracts([...])` is the manual slice check underneath.
- Every generated group includes an explicit `verify` command (exit 1 on drift, like diff). There is no manual fingerprint option. The fingerprint comes from the compiled contracts at build time, never from an operator at runtime.
- List `Journal.Command.self` and the other commands in `Commands([...])` inside `MMCLI { }`. See `Examples/CLI/CLI.swift`.

## Authorization model (why calls get denied)

- Identity comes from kernel-attested peer credentials on Unix sockets. TCP peers are `anonymous`. No token crosses the wire. uid 0 is not special.
- Entities are dotted paths in a tree. Dispatch needs `.execute` on **every ancestor** of the target (like directory x bits), then the method's declared class on the target.
- The first matching class wins, as in POSIX. An owner match uses only owner bits, even if group or other bits would grant more.
- A missing ACL record means `permissionDenied`. Existence never leaks. If discovery shows fewer methods than the server defines, that is traversal filtering, not a bug.
- Grants are per entity and per mode, never per method. A mode bit admits every method of that access class. In multi-family daemons, declare each route's targets:
  - `On(Journal.read, Accepts("journal.*")) { ... }`: subtree.
  - `Accepts("system.log")`: exact entity.
  - `Accepts("tenants.*.journal.*")`: a `*` segment matches exactly one segment. A trailing `.*` matches any depth.
  - `Accepts(.root, .all)`: root opt-in.
  - Unaccepted targets are denied before any ACL lookup. A route naming exactly one concrete entity also accepts entity-less calls (the server infers the target).
- Authorization runs before any payload byte is decoded.
- Metrics: the library emits swift-metrics instruments with stable `mm_server_*`/`mm_client_*` labels. Never rename them. It bootstraps no backend and opens no port. The host calls `MetricsSystem.bootstrap(...)` once, or all metrics are no-ops. The label list is in the IntegrationGuide's Observability section.

## House rules that apply to any code you write here

- Swift 6.4+ with strict concurrency, macOS 15+/Linux.
- Never use Dispatch/GCD, free-floating `Task {}`, `.wait()`, `print()`, `Date()`, or `@unchecked Sendable`.
- Public APIs return typed `Result`s (`MMCallError`, `MMWireError`, `MMError`), not thrown errors.
- Tests use Swift Testing (`@Test`/`#expect`) in three tiers: `EmbeddedChannel` for handlers, plain value tests for domain logic, real temp-dir Unix sockets for integration.
- Before deviating from anything, read this skill and the integration guide (`Sources/MMServer/MMServer.docc/IntegrationGuide.md`).

## Verify your work

1. `swift build`. The `For` cross-check and macro output are checked at compile and boot time.
2. Boot the daemon. `contract.verify(against:)` must pass with a clean log.
3. Run the client against it end to end (`swift run mm-example-daemon` + `swift run mm-example-client`). Include one deliberate denial to confirm the ACL table.
4. `swift test`. Add tests in the tier that matches what you changed.

## Where to go deeper

- `Sources/MMWire/MMWire.docc/WireProtocol.md`: normative byte-level spec (framing, hello, envelope kinds 0 to 6, termination matrix, fingerprint, conformance vectors).
- `Sources/MMServer/MMServer.docc/IntegrationGuide.md`: production embedding (SQLite-backed ACL provider, hardening options, operational defaults).
- `Sources/MMServer/MMServer.docc/RemoteAccess.md`: SSH socket forwarding, systemd/launchd recipes, TCP caveats.
- `Examples/`: the runnable daemon + client pair for everything above.

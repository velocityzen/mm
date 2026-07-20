---
name: mm
description: Implement, extend, or debug a matter-in-motion (mm) RPC server or client in Swift. Use this skill whenever the task involves MMService, MMClientConnection, a #schema contract, EntityACL tables, RPC handlers, streaming (follow/import-style calls), or any daemon/client that talks over this library's Unix-socket/TCP protocol — even if the user just says "add a method", "expose X over the socket", "write a client for the daemon", or "the call is denied". Also use it before reviewing or refactoring code that imports MMWire, MMSchema, MMServer, or MMClient.
---

# Implementing a matter-in-motion server and client

matter-in-motion is a binary RPC library: length-prefixed MessagePack envelopes over Unix domain sockets (or TCP), schemas declared once as Swift values, and filesystem-style rwx/ugo authorization enforced from kernel peer credentials. Everything below is the golden path; the runnable proof of every pattern is in `Examples/` (API + Daemon + Client).

Pick products by role — the dependency direction is load-bearing:

- Shared contract module: depends on `MMSchema` only. Never imports server or client.
- Daemon: `MMServer` + `MMSchema` (+ swift-service-lifecycle, swift-log).
- Client process: `MMClient` + `MMSchema`. A client never links `MMServer`.

## Step 1 — declare the contract once, with `#schema`

The contract lives in its own module (so clients can import it without the server) as a single macro block. The macro generates the payload structs, typed descriptors, `all`, `types`, and a runtime `contract` — there is no second copy to keep in sync:

```swift
import MMSchema

public enum Journal: MethodNamespace {
    #schema("journal") {
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
        // Server → client stream: an ordinary method with a ResponseStream —
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

- A method is four independent, freely combinable parts: `Request`, `RequestStream`, `ResponseStream`, `Response`. Unary is just "no stream parts". Omitted `Request` means an empty payload.
- The call's target entity rides the **open envelope**, never the payload. Do not add an `entity` field to a request "for routing" — handlers read `context.entity`, clients pass `on:`.
- Field keys are declaration-order integers. When evolving, pin keys (`Field(3, "note", .string)`) and make every new field `.optional(...)` — unknown keys are skipped, so old and new peers interoperate without a version bump. The protocol version stays 1; evolution is optional fields, not versions.
- `Access { .read / .write / .execute }` is the permission class the verb demands on the target entity. Choose it like a file mode, not like HTTP semantics.
- `description:` everywhere is served by discovery but never fingerprinted — doc edits are not schema drift.
- Any part can BE a named type: `Request(.reference("X"))`, `ResponseStream(.reference("ChangeEvent"))`, or a `SchemaDescribable` Swift type. The macro then generates no struct for that part.
- Shared types across schemas go in `#schemaTypes("common") { ... }` — but a compiler limitation means same-module macro arguments cannot see another macro's generated members, so shared containers need their own module (or hand-written `SchemaDescribable` types).
- Hand-written types outside the macro work too; an empty request struct with no stored properties must declare `static var schema: TypeSchema { .structure(fields: []) }` (`SchemaDescribable`) because a property-less decoder cannot be probed.

## Step 2 — the server

Declare the whole daemon as data inside `MMService { ... }` and hand it to a `ServiceGroup`. Verify the contract before listening — drift becomes a boot failure instead of a wire surprise:

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

Keep handlers in a reusable `RouteGroup` in its own file, carrying its dependencies. `On` has one overload per method shape; the context (`auth` below) always carries the already-authorized `entity`:

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
            // on its next send — watch `sink.stopRequested()` from a structured
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

- Handlers return `Result<Response, MMError>`; error codes 1–63 are reserved for the protocol — application errors start at 64.
- Every server auto-registers the builtins `server.schema` (discovery, filtered by the caller's traversal rights) and `server.entity`.
- Cross-connection fan-out (broadcasting one connection's append to another's `follow` stream) is application infrastructure — see `Examples/Daemon/FollowerHub.swift` for the safe registry pattern (synchronous `onTermination`, idempotent removal, never finish under the lock).
- Root-targeted requests (empty entity) are denied unless the route accepts them: `On(method, Accepts(.root, .all)) { ... }`.
- Dynamic authorization (SQLite etc.): implement `EntityACLProvider` and pass the instance — `ACLProvider(provider)`. The builder tree is sugar over `InMemoryACLProvider`.
- Startup ordering (ServiceLifecycle starts everything concurrently): `Ready(readiness)` in the builder fires a `ServiceReadiness` at bind; wrap dependents in `GatedService` to start after it. `OnBind { address in }` gives you ephemeral TCP ports.

## Step 3 — the client

For simple call-and-return clients, use the bracket — one scope owns connect/run/close/join. `with` is sugar over `MMClientConnection.open`, the live connection as an FPBracket resource (acquire = connect + start the loop, dispose = close + join); compose `open` with other brackets via `flatMap`/`BracketAsyncDo`:

```swift
let reply = await MMClientConnection.with(.unix(path: socketPath)) { connection in
    await connection.call(Journal.append, on: notes, Journal.AppendRequest(line: "hi"))
}
// Result<Result<AppendResponse, MMCallError>, MMClientError> — connection vs call
// failure. Dispose returns the loop's outcome: bracket .failure = connect failed OR
// the connection died mid-scope (transport error / protocol violation); clean EOF
// or the bracket's own close is .success.
```

One connection multiplexes many calls (msgids, concurrent callers, `maxInFlightCalls` bound) — one connection per unit of work, never per call. A closed connection stays closed; retry policy is the application's.

Custom choreography (streams in sibling tasks, staged teardown) lives *inside* the bracket body as structured children — the bracket still owns the lifecycle:

```swift
import MMClient

let outcome = await MMClientConnection.with(.unix(path: socketPath)) { connection in
    let notes = try! EntityName.parse("journal.notes").get() // validated dotted path

    // Unary: Result<Journal.AppendResponse, MMCallError>
    let reply = await connection.call(Journal.append, on: notes, Journal.AppendRequest(line: "hi"))

    // Server-stream: withStream consumes in a structured sibling (iterating
    // grants credit) while the body drives the connection; the join is built
    // in — it returns once the sequence ends.
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

In a daemon-style client, use `MMClientConnection.connect` and add `MMClientConnectionService(connection: connection)` to the `ServiceGroup` instead of the bracket.

Verify the schema like the server does:

```swift
switch await connection.discoverSchema() {
case .success(let schema):
    let difference = SchemaDifference(local: journalContract, remote: schema)
    print(difference)                  // "in sync" or the non-empty buckets
case .failure(let error): ...
}
```

A hello fingerprint mismatch is a signal to run discovery and degrade deliberately — never a disconnect. Reconnection is out of scope by design: a closed connection stays closed; watch `stateUpdates()` (`.connected` → `.closed(reason:)`) and let the application own retry policy.

## Generating a CLI from the contract

`#schema("journal", cli: .enabled)` additionally emits a swift-argument-parser command per call plus a `Journal.Command` group — names, help text, and argument shapes all come from the declaration. Requirements: the file must `import ArgumentParser` and `import MMCLI`, and the module must depend on both (the daemon then links them transitively — accepted tradeoff).

- Rename/omit commands with a `CLI(...)` part: `CLI(.command("add", aliases: ["append"]))`, `CLI(.omitted)`. Default name is the kebab-cased call name.
- Shape arguments with `Field(..., cli:)`: `.argument` (positional after the entity), `.flag` (bools), `.option("name", short: "n")`, `.omitted` (optional fields only). Defaults: `--field-name` options; wire enums become typed options (the `unknown` fallback is hidden and refused); structure/map/named-type fields take JSON literals.
- The overlay is presentation-only by construction — stored on `MethodDeclaration`, never forwarded to `MethodSignature`, so it cannot affect discovery, fingerprints, or compatibility.
- Every command gets the shared connection options (`--socket`/`--tcp`, timeouts, `--output json|json-pretty|raw`), an entity positional first, and sysexits-style failures (denied → 77, usage → 64, transport → 69, SIGINT → 130).
- The entity positional (`journal.notes`) is NOT from the schema and never will be: the schema declares verbs and payload shapes; entities are the daemon's runtime tree, declared server-side with ACLs. Syscall table vs. file paths — don't try to enumerate entities in a contract, and don't drop the entity argument from a command.
- Server-stream commands print elements as JSON lines (SIGINT = graceful STOP, second = CANCEL); client-stream commands read stdin lines (single-string-field elements take plain lines, others JSON; EOF = END); bidirectional does both.
- `MMCLI` also ships `MMCLIDiscover` ("discover") and `MMCLIRawCall` ("call" — any method by wire name, `--params` JSON, schema-driven) to mount alongside generated groups.
- Schema verification is automatic: every generated command diffs its own namespace against the server before dispatch (drift → exit 76; `--no-verify` opts out per invocation; denied discovery skips with a note — call rights don't imply read on the namespace entity). A companion CLI should install `MMCLIServerContract.install(.complete([journalContract]))` in its custom `main()` — the whole-server hello fingerprint folds at build time (builtins included via `SchemaFingerprint.expected(serving:)`), making verification free when it matches and a fallback diff when it doesn't. Client daemons get the same automation via `configuration.schema = .complete([...])` / `.partial([...])` — the connection verifies itself after connect and `await connection.verify()` yields `Result` of `.ok` / `.partial` / `.difference` (soft verdict, never a disconnect; `.noExpectation`/`.denied`/`.failed` on the error side); `connection.verifyContracts([...])` remains the manual slice-check underneath.
- Every generated group also includes explicit `verify` (exit 1 on drift, like diff). There is no manual fingerprint option: the fingerprint is build knowledge (folded from the compiled contracts), never something an operator supplies at runtime.
- Assemble the tool with a root `AsyncParsableCommand` (async dispatch requires the root to be async) listing `Journal.Command.self` and friends — see `Examples/CLI/CLI.swift`.

## Authorization model (why calls get denied)

- Identity is kernel-attested peer credentials on Unix sockets; TCP peers are `anonymous`. No token crosses the wire, and uid 0 is not special.
- Entities are dotted paths forming a tree. Dispatch needs `.execute` on **every ancestor** of the target (like directory x bits), then the method's declared class on the target itself.
- Classes resolve first-matching-class-wins: an owner match is judged by owner bits alone even if group/other would grant more — exactly POSIX.
- A missing ACL record means `permissionDenied`, and existence is never leaked. If discovery shows fewer methods than the server defines, that's traversal filtering, not a bug.
- Grants are per-entity-per-mode, never per-method: a mode bit admits every method of that access class. In multi-family daemons, declare a route's targets — `On(Journal.read, Accepts("journal.*")) { ... }` (subtree), `Accepts("system.log")` (exact), `Accepts(.root, .all)` (root opt-in, replacing the old `acceptsRoot:`); unaccepted targets are denied before any ACL lookup.
- Authorization runs before a single payload byte is decoded.

## House rules that apply to any code you write here

Swift 6 strict concurrency, macOS 15+/Linux. No Dispatch/GCD, no free-floating `Task {}`, no `.wait()`, no `print()`, no `Date()`, no `@unchecked Sendable`. Public APIs surface failures as typed `Result`s (`MMCallError`, `MMWireError`, `MMError`), not thrown errors. Tests use Swift Testing (`@Test`/`#expect`), in the repo's three tiers: `EmbeddedChannel` for handlers, plain value tests for domain logic, real temp-dir Unix sockets for integration. Read `CLAUDE.md` before deviating from anything.

## Verify your work

1. `swift build` — the `For` cross-check and macro fidelity are compile/boot-time gates.
2. Boot the daemon: `contract.verify(against:)` must pass and log clean.
3. Run the client against it end-to-end (the repo's own pair: `swift run mm-example-daemon` + `swift run mm-example-client`), including one deliberate denial to confirm the ACL table does what you think.
4. `swift test` — add tests in the tier that matches what you touched.

## Where to go deeper

- `Sources/MMWire/MMWire.docc/WireProtocol.md` — the normative byte-level spec (framing, hello, envelope kinds 0–6, termination matrix, fingerprint, conformance vectors).
- `Sources/MMServer/MMServer.docc/IntegrationGuide.md` — production embedding: SQLite-backed ACL provider, hardening knobs, operational defaults.
- `Sources/MMServer/MMServer.docc/RemoteAccess.md` — SSH socket forwarding, systemd/launchd recipes, TCP caveats.
- `Examples/` — the runnable daemon + client pair mirroring everything above.

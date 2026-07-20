# Integration guide

How a host application embeds matter-in-motion: define a method namespace, back the ACLs with SQLite, construct the router inside your existing `ServiceGroup`, harden the server, stream from handlers, and wire up a client in a companion process. The running example is **eyed**, the daemon this library was designed for — a long-running per-user service that owns a `journal` domain — but nothing here is eyed-specific; substitute your own domain throughout.

Prerequisites: the host already runs on swift-service-lifecycle (a `ServiceGroup` owns its services), uses SwiftNIO as the async runtime, and follows the same rules this library enforces internally — no free-floating `Task { }`, no blocking IO outside `NIOThreadPool`, no `Dispatch*`.

## 1. Define a method namespace

A method's whole contract lives in one `Method<Request, Response>` value: wire name, the `AccessMode` its verb requires on the target entity, and the request/response types as generics. Server handlers and typed client calls both hang off the same descriptor, so keep the namespace in a module both processes import.

Two wire conventions are load-bearing:

- **The call's target entity rides the open envelope, not the payload.** The router parses and authorizes it before interpreting a single params byte; handlers read the already-authorized target from `auth.entity` (the per-call context). Request payloads are plain values — no entity field, no reserved key.
- **Structs encode as MessagePack maps with integer keys.** Unknown keys are skipped on decode, so evolution is append-only: new fields must be optional.

```swift
import MMSchema

// Public memberwise inits elided throughout for brevity.
public struct AppendRequest: Codable, Sendable {
    public var line: String
    public var tag: String?                // added in v1.1 — optional, per the evolution rule

    enum CodingKeys: Int, CodingKey {
        case line = 0
        case tag = 1
    }
}

public struct AppendResponse: Codable, Sendable {
    public var sequence: UInt64

    enum CodingKeys: Int, CodingKey {
        case sequence = 0
    }
}

public struct ReadRequest: Codable, Sendable {
    public var fromSequence: UInt64

    enum CodingKeys: Int, CodingKey {
        case fromSequence = 0
    }
}

public struct ReadResponse: Codable, Sendable {
    public var lines: [String]

    enum CodingKeys: Int, CodingKey {
        case lines = 0
    }
}

/// The empty opening request of `journal.follow` (§5): the journal to follow
/// is the call's envelope entity. Empty payloads self-describe (a
/// property-less decoder cannot be probed).
public struct FollowRequest: Codable, Sendable, SchemaDescribable {
    public static var schema: TypeSchema { .structure(fields: []) }
}

/// One streamed change on a followed journal — a response-stream *element* of
/// `journal.follow` (§5), so no entity is injected and keys start at 0.
public struct ChangeEvent: Codable, Sendable {
    public var entity: EntityName
    public var sequence: UInt64

    enum CodingKeys: Int, CodingKey {
        case entity = 0
        case sequence = 1
    }
}

/// The terminal of a `journal.follow` call: how many changes were streamed
/// before the follower detached (client STOP or connection end).
public struct FollowSummary: Codable, Sendable {
    public var delivered: Int

    enum CodingKeys: Int, CodingKey {
        case delivered = 0
    }
}

public enum Journal: MethodNamespace {
    /// Appending mutates the target: `.write`.
    public static let append = Method<AppendRequest, AppendResponse>(
        name: "journal.append",
        access: .write
    )
    /// Reading observes it: `.read`.
    public static let read = Method<ReadRequest, ReadResponse>(
        name: "journal.read",
        access: .read
    )
    /// Server → client stream: the server streams a `ChangeEvent` for every
    /// append to the followed journal, then a `FollowSummary` terminal.
    /// Server push is an ordinary method with a response stream — correlated,
    /// authorized at open (`.read`, like `read`), fingerprinted, discoverable.
    public static let follow = ServerStreamMethod<FollowRequest, ChangeEvent, FollowSummary>(
        name: "journal.follow",
        access: .read
    )

    /// The sealed list the router cross-checks at startup, built with
    /// `@SchemaBuilder` — bare descriptor values (unary and streaming alike),
    /// erased for you.
    @SchemaBuilder public static var all: [AnyMethod] {
        append
        read
        follow
    }
}
```

Method names are dotted like entity paths, and the name's prefix matters: `server.schema` treats the prefix (`journal.append` → `journal`) as an entity when filtering discovery by traversal rights, and the router's namespace cross-check owns routes by prefix. Name methods so their prefix is the entity subtree they operate on.

`@SchemaBuilder` supports the same conditional forms as `@RouterBuilder` — `if`, `if`/`else`, `for`, and splicing another namespace's list by naming it — so a feature-flagged method can be compiled out of both the schema and the router in one place:

```swift
@SchemaBuilder public static var all: [AnyMethod] {
    append
    read
    if FeatureFlags.compaction {
        compact
    }
}
```

The method descriptors themselves stay `static let` on purpose: `client.call(Journal.append, on: entity, request)` type-checks its request and response because `Journal.append` is a `Method<AppendRequest, AppendResponse>` the compiler can see. A builder can compose the (type-erased) list, but only real declarations give you the typed call surface.

### Declaring the contract as data

For contract-first work there is a fully declarative layer: `Schema` builds the wire contract with no Codable types involved, producing plain `MethodSignature` values:

```swift
let journalContract = Schema("journal") {
    Call("append") {
        Access { .write }
        Request {
            Field("line", .string)
        }
        Response {
            Field("count", .int)
        }
    }
    Call("read") {
        Access { .read }
        Response {
            Field("lines", .array(.string))
        }
    }
    Call("follow") {
        Access { .read }
        ResponseStream {
            Field("entity", .string)
            Field("sequence", .uint)
        }
        Response {
            Field("delivered", .int)
        }
    }
}
```

Field keys are declaration-order; pin them (`Field(3, "note", .string)`) when evolving. Every part keys its fields from 0 — the call's target entity is envelope metadata, never payload. `Request` and `Response` are both optional: omit either for the common empty payload (`read` and `follow` above). Shapes compose through `TypeSchema`: `.optional(.string)`, `.array(Fields { ... })`, `.map(key:value:)`, or nested blocks (`Field("owner") { Field("uid", .uint) }`).

Streaming is declared with the `RequestStream` and `ResponseStream` Call parts. Each is optional and combines freely with `Request`/`Response`, giving the four-part method model — a method may take an opening request, stream elements from the client, stream elements to the client, and return a terminal, in any combination:

```swift
Call("follow") {
    Access { .read }
    Request { Field("from", .optional(.uint)) }   // opening arguments
    ResponseStream { Field("line", .string) }      // server streams elements
    Response { Field("total", .uint) }             // terminal summary
}
Call("import") {
    Access { .write }
    RequestStream { Field("line", .string) }       // client streams elements
    Response { Field("imported", .int) }
}
```

Stream elements are plain values — no entity is injected (authorization runs once on the opening request's entity), and each stream part takes a reserved `StreamOptions` argument for future per-stream knobs. The correlated wire frames, credit-based flow control, and the END/STOP/CANCEL termination model are the wire contract of the [wire protocol specification](https://swiftpackageindex.com/velocityzen/mm/documentation/mmwire/wireprotocol) §4.2; the handler and client APIs are §5 and §6 below.

#### Named types, enums, and descriptions

`Enum` and `Type` declare **named types** — nominal wire contract, referenceable from fields — and every element takes an optional `description:` that discovery serves to peers (doc-only: never fingerprinted, never treated as drift):

```swift
let journalContract = Schema("journal") {
    Enum("Priority", description: "How urgent a line is") {
        Case("normal")
        Case("urgent", description: "Surfaces immediately to followers")
    }
    Type("LineMeta", description: "Attribution carried with a line") {
        Field("author", .string, description: "Who wrote the line")
        Field("priority", "Priority")              // reference by local name
    }
    Call("append", description: "Appends one line") {
        Access { .write }
        Request(description: "The line and its attribution") {
            Field("line", .string, description: "The line text")
            Field("meta", .optional(.reference("LineMeta")))
        }
        Response { Field("count", .int) }
    }
}
```

Any part can also **be** a named type instead of declaring fields — fully symmetric across all four parts, since the entity rides the envelope and every payload is a plain value: `Request(.reference("SetPayload"))`, `Response(.reference("LineMeta"))`, `ResponseStream(.reference("ChangeEvent"))`, or cross-schema `Request(CommonTypes.Stamp.self)`. `#schema` then generates no struct for that part; the descriptor's payload type is the named type itself (`Method<SetPayload, LineMeta>`):

```swift
Type("SetPayload", description: "Shared set request") {
    Field("line", .string)
}
Call("set") {
    Access { .write }
    Request(.reference("SetPayload"))
}
```

Enums are **string-valued** on the wire (the case name is the value; renaming a case is a wire break, reordering is not) and generated Swift enums gain an `unknown` fallback case per the wire-enum house rule. Names are **nominal**: `journal.Priority` is part of the contract and the fingerprint; discovery serves a `TypeDefinition` table next to the method list, filtered to what each peer's visible methods reach. An undotted reference (`"Priority"`) must resolve within the block and is qualified automatically; a dotted one (`"common.LineMeta"`) is cross-schema and validated at server startup. Shared types that belong to no method namespace live in a `Types("common") { Enum/Type... }` block (runtime) or a `#schemaTypes` container (macro, below), registered on the server with the `Types(CommonTypes.self)` builder element.

The declaration is load-bearing three ways:

- `journalContract.verify(against: Journal.self)` — a test asserts the Codable types actually honor the declared contract across all four request/requestStream/response/responseStream parts **and the declared type table** (empty mismatch list = match), so the contract file is the single source of truth and drift fails CI. Shape checks run against decoder-behavior probes, so a `SchemaDescribable` conformance cannot vouch for itself; descriptions are ignored throughout.
- `SchemaDifference(local: journalContract, remote: discovered)` — the client diffs the declared contract (signatures and named types) against a live server.
- `journalContract.fingerprint()` — pins the expected hello fingerprint when the declaration covers the server's complete method set and type table.

A *runtime* declaration cannot mint `Method<Request, Response>` descriptors — those generics are what make `client.call` typed, and only real type declarations provide them. (The DSL's method element is named `Call` because `Method` is taken by the typed descriptor.) Which is exactly what the macro form is for:

### `#schema` — the declaration as the compile-time source of truth

Expanded inside a namespace enum, `#schema` consumes the same DSL and **generates** the types the runtime form cannot: the request/response/stream-element structs (integer `CodingKeys` from 0, public memberwise inits), the typed descriptors, the `all` list, and the runtime `contract` — one declaration, zero duplication:

```swift
public enum Journal: MethodNamespace {
    #schema("journal") {
        Call("append") {
            Access { .write }
            Request { Field("line", .string) }
            Response { Field("count", .int) }
        }
        Call("follow") {
            Access { .read }
            ResponseStream("ChangeEvent") {
                Field("entity", .string)
                Field("line", .string)
                Field("count", .int)
            }
            Response("FollowSummary") { Field("delivered", .int) }
        }
    }
}

// Generated: Journal.AppendRequest/AppendResponse/ChangeEvent/FollowSummary…,
// Journal.append (Method), Journal.follow (ServerStreamMethod),
// Journal.all, Journal.contract.
```

Generated type names default to `<Call>Request` / `<Call>Response` / `<Call>RequestItem` / `<Call>ResponseItem`; override with a leading string literal (`ResponseStream("ChangeEvent") { ... }`). Declare the `MethodNamespace` conformance on the enum yourself (a freestanding macro cannot add it), and re-export the nested generated types with typealiases if you want them top-level. Keeping the daemon's boot check — `Journal.contract.verify(against: Journal.self)` — turns it into a macro-fidelity guard: the generated Codable types are probed and compared against the re-emitted declaration on every start.

`Enum`/`Type` declarations expand too: `Enum("Priority") { Case("normal"); Case("urgent") }` generates a `String`-raw Swift enum with a generated `unknown` case (unrecognized wire values decode to it), `Type("LineMeta") { ... }` a struct — both `SchemaDescribable` as their qualified `.reference`, plus the namespace's `types` definition table and per-type decoder-behavior probes for `verify`. Every part's `description:` lands in the served signatures and as doc comments on the generated Swift declarations. Shared types get their own container:

```swift
public enum CommonTypes: TypeNamespace {
    #schemaTypes("common") {
        Enum("Priority") { Case("low"); Case("high") }
        Type("Stamp") {
            Field("author", .string)
            Field("priority", "Priority")
        }
    }
}
// Another schema references the generated Swift type:
//     Field("stamp", CommonTypes.Stamp.self)
// and registers the container on the server with Types(CommonTypes.self).
```

Cross-schema references in a `#schema` block use the Swift type (`Field("x", Other.Name.self)`) — the macro cannot know the Swift type behind a dotted wire name. One compiler limitation to know: a macro argument cannot reference macro-*generated* members of another container **in the same module** (the compiler will not expand one macro's arbitrary names while type-checking another's arguments); put shared `#schemaTypes` containers in their own module, or reference hand-written `SchemaDescribable` types.

The macro consumes the DSL's **static subset**: literal names and keys, no runtime conditionals, no `payload:`/`.bytes` shapes and no wire type mapped from `.string` other than `String` (an `EntityName`-typed field, for example, needs a hand-written type). For anything outside the subset — feature-flagged methods, hand-tuned Codable, `.bytes` — write that method with the runtime DSL and hand-written types; the two forms compose in one namespace. `#schema` requires the toolchain to build the `MMSchemaMacros` plugin (swift-syntax, compile-time only — never linked into your product).

## 2. An `EntityACLProvider` backed by SQLite

For a **static** ACL table — fixtures, small daemons, tests — declare the entity tree inline; it assembles an `InMemoryACLProvider`:

```swift
ACLProvider {
    Entity("journal", owner: uid, group: gid, mode: 0o750) {
        Entity("notes")                            // journal.notes — inherits owner/group, mode 0o750
        Entity("system", owner: 0, group: 0, mode: 0o700)
    }
}
```

Children take paths relative to the parent, inherit the parent's `owner`/`group` unless overridden, and default `mode` to `EntityACL.defaultCreationMode` (0o750). Top-level entities must state owner and group — authorization is never defaulted — and invalid paths or duplicates fail at startup.

Real hosts, whose ACLs live in storage and change at runtime, implement the provider protocol instead and pass the instance (`ACLProvider(provider)`). The protocol is the host's one authorization seam, `async` precisely because real providers sit on storage:

```swift
public protocol EntityACLProvider: Sendable {
    func acl(for entity: EntityName) async -> Result<EntityACL?, ACLProviderError>
    func invalidate(_ entity: EntityName) async
}
```

The contract, exactly as the router enforces it:

- `.success(nil)` means "no ACL record for this entity". The router answers `permissionDenied` — never "not found" — so peers cannot probe for entity existence. An entity without a row is unreachable by everyone.
- `.failure(ACLProviderError)` means the provider itself broke. The router logs it and answers `internalError`; provider detail never reaches the wire.
- `invalidate(_:)` is the chmod-equivalent hook: implementations that **cache** must drop the cached entry for that entity before returning, so the next `acl(for:)` observes the mutation. The router itself does not cache in v1 — dispatch correctness never depends on this hook — it exists so hosts can layer caching without changing the router.

`acl(for:)` is on the hot path: one lookup per ancestor prefix (traversal `x` checks) plus one for the target, per request. A request targeting `journal.main` costs two lookups (`journal`, then `journal.main`). Cache accordingly.

SQLite calls are blocking IO, and the house rule is absolute: blocking IO runs on `NIOThreadPool.runIfActive`, never on an event loop or the cooperative pool.

```swift
import MMSchema
import MMServer
import NIOConcurrencyHelpers
import NIOPosix
import SQLite3  // Darwin system module; on Linux, a CSQLite system-library target

/// eyed's ACL source: one table, a read-through cache, and every touch of
/// SQLite on the NIOThreadPool.
///
///     CREATE TABLE IF NOT EXISTS entity_acl (
///         entity TEXT PRIMARY KEY,   -- dotted path, "" never stored (root has no ACL)
///         owner  INTEGER NOT NULL,   -- uid
///         grp    INTEGER NOT NULL,   -- gid ("group" is inconvenient in SQL)
///         mode   INTEGER NOT NULL    -- low 9 bits, rwxrwxrwx
///     );
///
/// Invariant for the @unchecked Sendable: `database` is opened with
/// SQLITE_OPEN_FULLMUTEX (serialized mode), so the handle is safe to use from
/// any thread-pool thread; SQLite serializes internally. The handle itself is
/// written once in init and never reassigned. The cache is a NIOLockedValueBox.
public final class SQLiteACLProvider: EntityACLProvider, @unchecked Sendable {
    private let database: OpaquePointer
    private let threadPool: NIOThreadPool
    /// Read-through cache; `nil` values (missing rows) are cached too, so a
    /// denied prefix does not hammer storage. Bounded by the entity universe,
    /// which the host controls.
    private let cache = NIOLockedValueBox<[EntityName: EntityACL?]>([:])

    public init(path: String, threadPool: NIOThreadPool = .singleton) throws {
        var handle: OpaquePointer?
        // Serialized mode: see the Sendable invariant above.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw ACLProviderError(description: "sqlite open failed: \(path)")
        }
        self.database = handle
        self.threadPool = threadPool
    }

    public func acl(for entity: EntityName) async -> Result<EntityACL?, ACLProviderError> {
        // Fast path: cached hit or cached miss, no thread-pool hop.
        if let cached = self.cache.withLockedValue({ $0[entity] }) {
            return .success(cached)
        }
        let database = self.database
        do {
            // The one blocking hop. runIfActive suspends the caller; the query
            // runs on a pool thread, never on a loop.
            let row: EntityACL? = try await self.threadPool.runIfActive {
                try Self.selectACL(database: database, entity: entity.rawValue)
            }
            self.cache.withLockedValue { $0[entity] = .some(row) }
            return .success(row)
        } catch {
            // Storage failure: surface as the provider error; the router logs
            // it and answers the peer with internalError. Never cache failures.
            return .failure(ACLProviderError(description: String(describing: error)))
        }
    }

    /// Called by eyed's own mutation paths after every chmod/chown-equivalent
    /// write, entity creation, and entity deletion — anything that changes
    /// what `acl(for:)` should answer. Dropping before returning is the
    /// contract: the next lookup re-reads storage.
    public func invalidate(_ entity: EntityName) async {
        self.cache.withLockedValue { $0[entity] = nil }
    }

    private static func selectACL(database: OpaquePointer, entity: String) throws -> EntityACL? {
        var statement: OpaquePointer?
        let sql = "SELECT owner, grp, mode FROM entity_acl WHERE entity = ?1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ACLProviderError(description: "prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, entity, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return EntityACL(
                owner: uid_t(sqlite3_column_int64(statement, 0)),
                group: gid_t(sqlite3_column_int64(statement, 1)),
                mode: UInt16(truncatingIfNeeded: sqlite3_column_int64(statement, 2))
            )
        case SQLITE_DONE:
            return nil  // no record -> router answers permissionDenied
        default:
            throw ACLProviderError(description: "step failed: \(sqlite3_errcode(database))")
        }
    }
}
```

Caching notes, in order of how much they matter:

- **Invalidate on creation and deletion, not just chmod.** This provider caches misses (`nil` rows), so creating `journal.scratch` without `invalidate(entity("journal.scratch"))` leaves it invisible until the entry is dropped. If your mutation paths cannot reliably enumerate affected entities, cache positive rows only.
- **Never cache failures.** A transient storage error must not turn into a sticky denial.
- **Remember the ACL semantics you are serving**: first-matching-class-wins (a peer classified as owner is judged by owner bits alone, even when group/other bits would grant), uid 0 is not special, and traversal requires `x` on every ancestor prefix. All of that is enforced by the router via `EntityACL.permitted` — the provider only stores and fetches.
- The library ships `InMemoryACLProvider` (an actor over a dictionary) for tests and small daemons; its `invalidate` is a documented no-op because it never caches.

### Grants are per-entity-per-mode — declare what a route accepts when that's too broad

One mental-model boundary deserves stating outright: a mode bit on an entity gates **every** method with that access class, exactly like the read bit on a file gates every program that opens it. There is no per-method grant — you cannot express "this peer may `server.entity` this target but not `journal.read` it." Methods (verbs) and entities (nouns) are deliberately orthogonal, and the router will happily authorize `journal.read` on `system.something` if the peer can traverse to it and read it.

For a daemon serving one method family over its own subtree that is exactly right. For a daemon serving **several** families over one entity tree, it means an ACL grant made for one family's sake admits every family's verbs of the same class. When that's too broad, declare the route's target vocabulary with `Accepts` — the optional second argument of `On`/`Handle`:

```swift
On(Journal.read, Accepts("journal.*")) { auth, request in ... }      // journal's descendants
On(System.rotate, Accepts("system.log", "system.audit")) { ... }     // exactly these entities
On(Tree.walk, Accepts(.root, .all)) { ... }                          // root AND any entity
```

The patterns compose (any match admits): `"*"` / `.all` is any non-root entity (the default), `"journal.*"` is strict descendants (glob discipline — list `"journal"` too when the namespace entity is itself a target), a bare name is an exact entity, and `.root` opts into root-targeted dispatches — the only way to accept them, since root carries no ACL; it replaces the old `acceptsRoot:` flag and is reserved for methods with documented tree-wide semantics whose handlers enforce their own authorization (as the builtin `server.schema` does).

`Accepts` is checked immediately after the target parses — before any ACL lookup — and an unaccepted target answers with the same wire error as a denial, so a caller cannot distinguish "outside this method's world" from "no access". It is routing policy, not contract: never fingerprinted, never served by discovery. Entity-agnostic methods (the builtin `server.entity`, a backup verb that targets any subtree) simply keep the default.

## 3. Declaring the server inside the existing `ServiceGroup`

`MMService` is a swift-service-lifecycle `Service`: eyed does not get a new lifecycle mechanism, it gets one more entry in the `ServiceGroup` it already runs. The declarative form assembles everything — configuration, authorization, logging, and the handlers — in one builder; underneath it constructs the `Router` (with `registerBuiltins: true`, so `server.schema` and `server.entity` exist without user code), computes the hello fingerprint from every registered signature, and prepares metrics, all before `run()` is ever called.

```swift
import Logging
import MMSchema
import MMServer
import ServiceLifecycle

let store: JournalStore = ...  // eyed's own actor/loop-pinned storage
let aclProvider = try SQLiteACLProvider(path: "/var/lib/eyed/acl.db")

let server = MMService {
    Configuration(endpoint: .unix(path: "/var/run/eyed/rpc.sock"))
    ACLProvider(aclProvider)
    Log(label: "eyed.rpc")

    // For(Namespace.self) groups the routes AND enrolls the namespace in the
    // startup cross-check: every descriptor in Journal.all needs a handler,
    // every handler under the "journal" prefix must be declared.
    For(Journal.self) {
        // Inline, right in the definition. `On` puts the authorized
        // connection context first, then the decoded request; handlers
        // return Result<Response, MMError> — domain failures go to the
        // peer verbatim as `MMError` values, codes >= 64.
        On(Journal.append) { auth, request in
            switch await store.append(request.line, tag: request.tag, to: auth.entity) {
            case .success(let sequence):
                // The store broadcasts the change to every live follower of
                // this journal (see the follow handler in §5).
                await store.broadcast(ChangeEvent(entity: auth.entity, sequence: sequence))
                return .success(AppendResponse(sequence: sequence))
            case .failure(.journalSealed):
                return .failure(MMError(code: 64, message: "journal is sealed"))
            case .failure:
                return .failure(MMError(code: 65, message: "store failure"))
            }
        }
        // — or a reusable group declared in its own file (see below).
        JournalReadHandlers(store: store)
    }
}
```

Required parts: exactly one `Configuration` and exactly one `ACLProvider` (authorization has no default, deliberately). Optional: `Log` (a `Logger`, a `label:level:` pair, or a closure sink `Log { level, message in ... }`), `OnBind { address in ... }`, and `Types(CommonTypes.self)` for each shared types-only container (`#schemaTypes` block) your schemas reference — namespaces declared with `For` contribute their own type tables automatically. Violations fail at daemon startup, like every router precondition — including a duplicate type definition or a `.reference` that no registered table resolves.

A `RouteGroup` is the handler analogue of a custom SwiftUI view — a separately-declared bundle with its own dependencies:

```swift
struct JournalReadHandlers: RouteGroup {
    let store: JournalStore

    @RouterBuilder var routes: [Route] {
        On(Journal.read) { auth, request in
            await store.read(from: request.fromSequence, in: auth.entity)
                .map(ReadResponse.init(lines:))
                .mapError { _ in MMError(code: 65, message: "store failure") }
        }
        // Server-streaming: (auth, request, sink). See §5. A journal can go
        // quiet, and a relay parked on a quiet source observes STOP only on
        // its next send — production handlers pair this loop with a
        // `sink.stopRequested()` watcher (the example daemon shows the full
        // shape).
        On(Journal.follow) { auth, request, sink in
            let (token, changes) = await store.follow(auth.entity)
            var delivered = 0
            loop: for await event in changes {
                switch await sink.send(event) {
                case .sent: delivered += 1
                case .peerStopped, .callEnded: break loop
                }
            }
            await store.unfollow(token, from: auth.entity)
            return .success(FollowSummary(delivered: delivered))
        }
    }
}
```

(The parameter-based `MMService(configuration:namespaces:aclProvider:logger:onBind:routes:)` initializer and the `Handle(method) { request, context in ... }` spelling remain available; `On` and `Handle` register identical routes — `On` simply orders the closure parameters context-first for the builder style.)

### Startup ordering: `ServiceReadiness` and `GatedService`

swift-service-lifecycle starts every group member concurrently and orders only *shutdown* (reverse array order) — it deliberately has no readiness concept. When a sibling service must not start before the RPC socket is listening (a discovery announcer, a health gate, an in-process client), compose the ordering on top:

```swift
let rpcReady = ServiceReadiness()

let group = ServiceGroup(configuration: .init(
    services: [
        .init(service: MMService {
            Configuration(endpoint: .unix(path: sock))
            ACLProvider(aclProvider)
            Ready(rpcReady)                        // fires at bind+listen
            For(Journal.self) { JournalHandlers(store: store) }
        }),
        .init(service: GatedService(after: rpcReady, run: AnnounceService(path: sock))),
    ],
    gracefulShutdownSignals: [.sigterm],
    logger: logger
))
```

`GatedService` awaits its readiness signals, then runs the wrapped service; combined with reverse-order shutdown this gives full dependency semantics — the dependent starts after and stops before its dependency. A graceful shutdown arriving while still gated exits cleanly (the wrapped service never starts, so there is nothing to drain). `Ready` may appear multiple times (one signal per dependent) and composes with an explicit `OnBind`.

// eyed's existing group — the RPC server is just one more service beside the
// ones already there. Conventional signal mapping: SIGTERM (systemd/launchd
// stop) -> graceful shutdown, SIGINT (dev Ctrl-C) -> cancellation.
let group = ServiceGroup(configuration: .init(
    services: [
        .init(service: existingSchedulerService),
        .init(service: server),
    ],
    gracefulShutdownSignals: [.sigterm],
    cancellationSignals: [.sigint],
    logger: Logger(label: "eyed")
))
try await group.run()
```

The `@RouterBuilder` closure supports plain `Handle(...)` expressions, pre-built `[Route]` groups, `if`/`else`, and `for` loops, so routes can be registered conditionally at daemon startup (feature flags, platform differences).

**Startup preconditions are deliberate fail-fast.** Every misregistration is a `precondition` failure at daemon boot — a crash in the first second of deployment — rather than a surprise at first call. The router checks, at `init`:

- duplicate method names across all routes (builtins included);
- every descriptor in each declared namespace's `all` has a registered route (no unbound descriptors);
- every registered route under a method-name prefix owned by a declared namespace appears in that namespace's `all` list (no strays hiding from the fingerprint cross-check);
- every request/response type survives the schema probe, so the fingerprint covers everything and no type fails at first decode;
- every method name's namespace prefix parses as a valid `EntityName`.

Passing `namespaces: [Journal.self]` is what arms the second and third checks; leaving a namespace out of the list silently skips its cross-check, so declare every namespace you register routes for. The assembled router is exposed as `server.router` — its `fingerprint` and `signatures` are useful at build time (§6).

Graceful shutdown is already correct end to end: the listener closes first, open connections stop reading while in-flight handlers complete and flush, channels close, and (for unix endpoints) the socket file is unlinked last — guarded by a device/inode identity check so a slow drain never deletes a successor instance's socket.

One optional nicety: bootstrap swift-log with `MMLogContext.metadataProvider` (or merge it into your provider) and every log line inside a connection's task tree — including lines from your handler bodies with your own loggers — carries the `connection` id.

## 4. Server configuration hardening

Everything in `MMServerConfiguration` is bounded on purpose: no peer can grow server memory without limit. What each knob bounds:

- `maxFrameLength` (default 16 MiB = `MMWireInfo.defaultMaxFrameLength`) — the per-frame memory a peer can make the server accumulate. Enforced by the frame decoder **before** accumulation: a peer *claiming* a larger frame has its connection failed immediately, no buffering happens first.
- `maxConnections` (default 128) — total concurrent connections, enforced at accept. Over the cap the new connection is closed immediately (no busy frame — pre-hello there is no msgid to correlate an error to) and a rejection is counted.
- `maxInFlightRequestsPerConnection` (default 16) — concurrent unary handler executions one connection can hold. An over-cap request is answered immediately with `tooManyInFlight` (code 4). Nothing queues beyond the cap.
- `maxConcurrentStreamsPerConnection` (default 8) — concurrent streaming calls one connection can hold, counted separately from the unary in-flight cap. Per-stream buffers are bounded by the credit window (§5), so this bounds the total stream memory a peer can hold open.
- `idleTimeout` (default 120 s, monotonic `TimeAmount`) — how long a connection may sit with no traffic in *either* direction before being reaped, including clients that connect and never complete the hello. Outbound counts as liveness on purpose: a client that only consumes a response stream legitimately sends little while the server streams to it.
- `unixSocketMode` (default `0o660`) — who can connect at all. `chmod(2)`ed onto the socket file **between `bind(2)` and `listen(2)`**, so no connection is ever accepted under a more permissive umask-derived mode. This is the outer authorization boundary — everything past connect is decided by per-entity ACLs, but connect itself is decided here. Use `0o600` for strictly single-user daemons, and set the socket *directory's* ownership deliberately too. Ignored for TCP.
- `capabilities` (default 0) — the hello capability bitset; v1 defines no bits.

For eyed the interesting deviations from defaults are a smaller frame cap (journal lines are small; 16 MiB is generous for a schema response but absurd for `journal.append`) and the socket mode:

```swift
let configuration = MMServerConfiguration(
    endpoint: .unix(path: "/var/run/eyed/rpc.sock"),
    maxFrameLength: 1 << 20,          // 1 MiB: largest legitimate payload, with margin
    maxConnections: 64,
    idleTimeout: .seconds(300),       // tools that keep a follow stream open
    unixSocketMode: 0o660             // owner + service group; the group is the grant
)
```

TCP endpoints exist (`.tcp(host:port:)`, port 0 + the `onBind` callback for ephemeral ports) but carry **no peer identity in v1**: every TCP peer is `PeerIdentity.anonymous` and only ACL *other*-class bits apply. Raw TCP is for trusted networks; the documented remote path is SSH unix-socket forwarding, which preserves kernel peer credentials end to end.

## 5. Streaming from handlers

Server push is an ordinary method with a `ResponseStream`, not a side channel. A server-streaming handler takes `(req, sink, ctx)`: it pushes response elements through the credit-gated `MMResponseSink<Element>` and closes the call by returning its terminal `Result<Response, MMError>`. A client-streaming handler takes `(req, elements, ctx)`, where `elements` is an `MMRequestStream<Element>` — a backpressured `AsyncSequence` whose normal end is the client's graceful END; a bidirectional handler takes `(req, elements, sink, ctx)`. Authorization runs once, at open, on the request's entity, exactly like a unary call.

`sink.send(_:)` is the whole outbound surface. It encodes the element, spends one credit, and returns a `StreamSendOutcome` — all three cases are *graceful*, none is an error:

```swift
Handle(Journal.follow) { request, sink, auth in
    // Register this call as a follower; the store fans out every append.
    let (token, changes) = store.follow(auth.entity)
    var delivered = 0
    loop: for await event in changes {
        switch await sink.send(event) {
        case .sent:
            // Buffered toward the client under the credit window; the send may
            // have suspended first at zero credit (a slow consumer parks the
            // producing task — memory stays bounded, siblings unaffected).
            delivered += 1
        case .peerStopped:
            // The client sent STOP ("I have seen enough, wrap up") — graceful,
            // the stopping element was dropped. Break and return the terminal.
            break loop
        case .callEnded:
            // Client CANCELled, the connection died, or the terminal is already
            // out. Break promptly; the return value is discarded.
            break loop
        }
    }
    store.unfollow(token, from: auth.entity)   // every exit path
    return .success(FollowSummary(delivered: delivered))
}
```

The store's follower registry deserves one production note: keep it behind a lock, not actor isolation, and wire each follower stream's `onTermination` to unregister — termination handlers are synchronous, so an actor-isolated registry cannot clean up a dead follower without spawning a task. `Examples/Daemon/FollowerHub.swift` is the reference shape: registration removed under the lock, `finish()` called only after release (a termination handler re-enters the registry), removal idempotent so the handler-path and termination-path cleanup race safely — which is also why `store.follow`/`store.unfollow` above are synchronous, not `await`ed.

The client-streaming side is the mirror: iterate `elements` to consume request items (consuming grants the client more credit), and the sequence ending *is* the client's graceful END:

```swift
Handle(Journal.import) { request, elements, auth in
    var imported = 0
    for await line in elements {            // normal end == client END
        _ = await store.append(line.text, to: auth.entity)
        imported += 1
    }
    return .success(ImportSummary(imported: imported))
    // elements.stop() would send a server-initiated STOP (advisory): "I have all
    // the request items I need" — the call still runs to this terminal.
}
```

Semantics to design around:

- **Cross-connection fan-out is host logic.** Each `follow` call gets one correlated response stream; wiring appends on *any* connection to every interested follower is the store's job (the registry the handler above registers with). The library gives you the per-call stream, not pub/sub.
- **Flow control is automatic and bounded.** The window starts at 8 items per direction; a lagging consumer parks the producer at zero credit rather than growing memory, and a stalled stream never blocks sibling calls (no head-of-line blocking).
- **Streaming methods *are* fingerprinted and discoverable.** Unlike the removed notification mechanism, a response stream is a normal part of the method signature (`server.schema` reports its element shape), so a client detects a reshape through the hello fingerprint and discovery like any other contract change. Stream element payloads still evolve append-only (new fields optional).
- **Termination is graceful by default.** END finishes a direction, STOP asks the peer to (surfaced as `.peerStopped`), and the terminal is always the last frame; CANCEL and connection death arrive as `.callEnded` / task cancellation. A handler relaying a **quiet** source would otherwise observe STOP only on its next send — arbitrarily far away — so pair the relay with `sink.stopRequested()` watched from a structured sibling: it parks until the STOP (or the end of the call) and lets the handler return its terminal promptly. The full matrix is in the [wire protocol specification](https://swiftpackageindex.com/velocityzen/mm/documentation/mmwire/wireprotocol) §4.2.

## 6. The client side: a companion process

The client (say `eyectl`, or a sibling daemon) imports the same namespace module and `MMClient`.

**One connection, many calls.** A connection is a multiplexer — every call gets its own msgid, concurrent callers interleave freely (bounded by `maxInFlightCalls`), and streams share the connection with per-stream credit windows. Open one connection per *unit of work* (a daemon's lifetime, a tool invocation), never per call.

**Own the lifecycle in one of two sanctioned shapes:**

```swift
import MMClient
import MMSchema
import ServiceLifecycle

// Shape 1 — daemons: the ServiceGroup adapter.
let connection = try await MMClientConnection.connect(
    to: .unix(path: "/var/run/eyed/rpc.sock"),
    configuration: MMClientConfiguration(schema: .complete([Eye.contract]))
).get()
let group = ServiceGroup(configuration: .init(
    services: [.init(service: MMClientConnectionService(connection: connection))],
    gracefulShutdownSignals: [.sigterm],
    cancellationSignals: [.sigint],
    logger: logger
))
try await group.run()

// Shape 2 — tools and tests: the bracket. Acquire connects AND starts the
// inbound loop; dispose closes, joins it, and returns the loop's outcome as
// the release verdict — the bracket fails if the connection did not survive
// the scope (`with` is sugar over `MMClientConnection.open`, an FPBracket
// resource).
let reply = await MMClientConnection.with(.unix(path: socketPath)) { connection in
    await connection.call(
        Journal.append,
        AppendRequest(entity: journalMain, line: "hello", tag: nil)
    )
}
```

Custom choreography — stream drainers in sibling tasks, staged teardown — lives *inside* the bracket body as structured children (`async let`, a local group); the bracket still owns the lifecycle around it.

`connect` performs the bootstrap and hello exchange only — it spawns nothing; the connection is inert until its loop runs. Every connected connection must eventually see `run()` or `close()`. Calls issued before `run()` starts park until the loop produces the writer — start it promptly. When the connection dies (EOF, transport error, `close()`, cancellation), pending calls fail with `MMCallError.connectionClosed`, `state` becomes `.closed(reason:)`, and `run()` returns. Reconnection is deliberately out of scope for v1: a closed connection stays closed; retry policy is application logic, driven by `stateUpdates()`.

**Typed calls** return `Result<Response, MMCallError>` — no throws on the data path:

```swift
switch await connection.call(Journal.read, on: journalMain, ReadRequest(fromSequence: 0)) {
case .success(let response):
    render(response.lines)
case .failure(.denied):
    fail("permission denied — check the entity ACL and the socket group")
case .failure(.remote(let error)) where error.code == 64:
    fail("journal is sealed")
case .failure(let other):
    fail("call failed: \(other)")
}
```

Calls are bounded by `maxInFlightCalls` (default 16, matching the server's per-connection cap): the excess fails immediately with `.tooManyInFlight`, never queued. Cancelling the awaiting task abandons the msgid locally — the request may still execute server-side; only response delivery is cut.

**Streaming calls** return a typed handle, not a `Result`. A server-streaming `call` returns an `InboundStreamHandle<Element, Response>`: a single-iteration `AsyncSequence` of elements over `NIOAsyncSequenceProducer` (bounded buffer, real backpressure, never a bare `AsyncStream`), plus an awaitable `result()` terminal and `stop()` / `cancel()` control:

```swift
tasks.addTask {
    let follow = await connection.call(Journal.follow, on: journalMain, FollowRequest())
    for await event in follow {         // ends on server END, terminal, or close
        await indexQueue.enqueue(event) // hand off fast (see the caveat below)
    }
    switch await follow.result() {      // Result<FollowSummary, MMCallError>
    case .success(let summary): logger.info("followed \(summary.delivered) changes")
    case .failure(let error):   logger.warning("follow ended: \(error)")
    }
}

// Later, from anywhere: ask the server to wrap up gracefully.
await follow.stop()                     // STOP; the call still runs to its terminal
```

Iterating the sequence is what grants credit back to the server (the initial window of 8 arrives unprompted; each further window the consumer drains emits a grant). A consumer that stops draining stops granting — the server parks at zero credit and memory stays bounded. `stop()` is a graceful STOP; `cancel()` (or cancelling the consuming task's own cancellation handler) sends CANCEL and resolves every surface `.cancelled`. An element that fails to decode is dropped with a warning and a counter — it never ends the sequence.

A client-streaming `call` returns an `OutboundStreamHandle<Element, Response>` — the mirror image: credit-gated `send(_:)` returning a `StreamSendOutcome`, a one-shot `finish()` (END), and an awaitable `result()`:

```swift
let importCall = await connection.call(Journal.import, on: journalMain, ImportRequest())
for line in linesToImport {
    switch await importCall.send(ImportLine(text: line)) {   // suspends at zero credit
    case .sent: continue
    case .peerStopped, .callEnded, .connectionClosed: break  // server STOP / call over
    }
}
await importCall.finish()               // END: finish the request direction
let summary = await importCall.result() // Result<ImportSummary, MMCallError>
```

A bidirectional `call` returns a `BidirectionalStreamHandle` with independent `.inbound` and `.outbound` halves (drive them from different tasks) sharing the one terminal.

**The head-of-line caveat, which is intended semantics:** the inbound element buffer is bounded by the credit window. When a consumer lags and its buffer fills, the connection's inbound loop *suspends before reading more frames*, so the lag propagates to the socket and suspends the server's writes for *that stream* — but credits are per-stream, so a stalled stream starves only itself; sibling calls and streams keep flowing. Still, iterate an inbound stream from a task that does **not** also await other traffic on this connection, and hand elements to your own pipeline instead of doing slow work inside the `for await` body.

**Schema verification is automatic — declare contracts, never a fingerprint.** Give the client configuration the contracts this build was compiled against and the connection verifies itself right after `run()` starts. A mismatch is never a disconnect; the verdict is data:

```swift
let connection = try await MMClientConnection.connect(
    to: .unix(path: socketPath),
    // .complete when this client knows the server's whole composition;
    // .partial([Journal.contract]) when it uses a slice of a bigger server.
    configuration: MMClientConfiguration(schema: .complete([Journal.contract]))
).get()

// ... run() as a structured child, then:
switch await connection.verify() {
case .success(.ok):
    // Complete expectation, hello matched: the entire composition is
    // proven with zero discovery round-trips.
    break
case .success(.partial):
    // Every declared contract is served verbatim; the composition
    // changed somewhere this build does not use.
    break
case .success(.difference(let differences)):
    // The namespaces this build depends on moved: disable the dependent
    // features, keep the rest running.
    disable(differences)
case .failure(let reason):
    // .noExpectation / .denied / .failed(callError) — no verdict; act per
    // application policy.
    log(reason)
}
```

For custom policy over the raw buckets, the manual flow underneath remains available: `connection.verifyContracts([...])` for a scoped diff, or `discoverSchema()` + `SchemaDifference(local:remote:)` (note `remote.methods` is filtered by *this peer's* traversal rights; `remote.fingerprint` is the server's unfiltered value, comparable with `connection.server.fingerprint`).

`SchemaDifference` buckets: `missingMethods` (absent *or invisible to this peer* — the fix may be an ACL change, not a deploy), `signatureChanged` (the wire contract moved under this build), `accessChanged` (the verb needs a different permission class now), `remoteOnly` (harmless; upgrade planning) — plus the named-type buckets `missingTypes`, `typeChanged` (same qualified name, different shape — treat like `signatureChanged` for features carrying the type), and `remoteOnlyTypes`. Prefer `SchemaDifference(local: contract, remote:)` with a `SchemaDeclaration` so types diff too. All comparisons are description-stripped (doc edits are never drift), all buckets sorted by name for deterministic logs, and the value is `CustomStringConvertible` — `"\(diff)"` renders `in sync` or the non-empty buckets (`missing: a.get; types changed: common.Priority`), so log it directly instead of iterating buckets.

## 7. Operational defaults

Every value verified against the shipped initializers and constants.

| Knob | Default | Where | What it bounds |
|---|---|---|---|
| Frame length cap | 16 MiB (`MMWireInfo.defaultMaxFrameLength`) | `MMServerConfiguration.maxFrameLength`, `MMClientConfiguration.maxFrameLength` | Per-frame memory; checked before accumulation, oversized claims fail the connection |
| Connection cap | 128 | `MMServerConfiguration.maxConnections` | Concurrent connections; enforced at accept, over-cap closed immediately |
| Server in-flight cap | 16 per connection | `MMServerConfiguration.maxInFlightRequestsPerConnection` | Concurrent unary handler runs per connection; over-cap requests get `tooManyInFlight`, never queued |
| Concurrent streams cap | 8 per connection | `MMServerConfiguration.maxConcurrentStreamsPerConnection` | Concurrent streaming calls per connection, counted separately from the unary cap |
| Client in-flight cap | 16 per connection | `MMClientConfiguration.maxInFlightCalls` | Calls awaiting responses; excess fails immediately with `.tooManyInFlight` |
| Server idle timeout | 120 s (monotonic) | `MMServerConfiguration.idleTimeout` | Reaps connections with no traffic in either direction, pre-hello clients included |
| Client idle timeout | disabled (`nil`) | `MMClientConfiguration.idleTimeout` | Optional reaping of a silent connection; outbound stream frames count as liveness |
| Unix socket mode | `0o660` | `MMServerConfiguration.unixSocketMode` | Who may connect; chmod between bind and listen, set it (and the directory) deliberately |
| Entity creation mode | `0o750` (`EntityACL.defaultCreationMode`) | host entity-creation paths | Default `rwxr-x---` for new entities; the host may override umask-style |
| Stream credit window | 8 items per direction (initial) | `MMStreamFlowControl.initialWindow` | Pre-grant burst per stream direction; a sender at zero credit suspends (§5, §6) |
| Protocol version | 1 (`MMWireInfo.protocolVersion`) | hello preamble | Min-wins negotiation; a server advertising 0 is unsupported |

## 8. Observability: metrics

Both halves of the library instrument themselves through [swift-metrics](https://github.com/apple/swift-metrics) — a facade, like swift-log. The library only **emits**; it never opens a port, never serves a `/metrics` endpoint, and never bootstraps a backend. Until the host process bootstraps one, every instrument hits the built-in no-op handler: near-zero cost, data discarded. So exposing these numbers is a host decision, made once, before the `ServiceGroup` runs:

```swift
import Metrics
import Prometheus   // swift-prometheus

let registry = PrometheusCollectorRegistry()
MetricsSystem.bootstrap(PrometheusMetricsFactory(registry: registry))
// Serve the scrape text yourself — a tiny HTTP endpoint returning
// registry.emit(into:), or write it periodically to a file for
// node_exporter's textfile collector. Push-style backends (StatsD,
// an OTel exporter) need no listening port at all.
```

**Who can see them is your perimeter, not the library's.** Metrics do not ride the RPC socket, are not a builtin method, and are entirely outside the entity-ACL model — whatever surface the backend opens is a *new* surface. And it is an information surface worth treating like one: call rates, denial counts, and connection activity profile the daemon's use. Bind a scrape endpoint to localhost or a mode-restricted Unix socket, or prefer a push backend, with the same deliberateness §4 applies to `unixSocketMode`.

The labels are a stable operational contract (they do not change when internals are refactored). Counters are monotonic and `_total`-suffixed; the two timers record nanoseconds.

**Server — connection lifecycle and frames:**

| Label | Kind | Meaning |
|---|---|---|
| `mm_server_connections_accepted_total` | counter | Connections accepted |
| `mm_server_connections_rejected_total` | counter | Connections closed at accept over `maxConnections` |
| `mm_server_active_connections` | gauge | Currently open connections |
| `mm_server_accept_failures_total` | counter | Per-child accept failures absorbed without killing the listener |
| `mm_server_frames_in_total` / `mm_server_frames_out_total` | counter | Framed messages read / written |
| `mm_server_protocol_violations_total` | counter | Bad hellos and undecodable/ill-formed frames (connection-fatal) |

**Server — routing and streams:**

| Label | Kind | Meaning |
|---|---|---|
| `mm_server_auth_denials_total` | counter | Every denial: missing ACL, failed traversal or target check, root without `.root`, target outside the route's `Accepts` |
| `mm_server_dispatch_duration_ns` | timer | Unary dispatch, authorization included |
| `mm_server_inbound_responses_dropped_total` | counter | Response-kind frames from peers (clients never answer calls) |
| `mm_server_streams_opened_total` / `_ended_total` / `_stopped_total` / `_cancelled_total` | counter | Stream lifecycle: opens, graceful terminals, STOPs observed, client CANCELs |
| `mm_server_stream_items_in_total` / `_out_total` | counter | Request items delivered to handlers / response items written |
| `mm_server_stream_credit_stalls_total` | counter | Response sends that parked at zero credit (slow consumers) |
| `mm_server_stream_credit_grants_out_total` | counter | Additive credit grants written for request streams |
| `mm_server_stream_stops_out_total` | counter | Server-initiated request-stream STOPs |
| `mm_server_stream_violations_total` | counter | Stream-contract violations answered with a code-6 terminal |
| `mm_server_streams_over_cap_total` | counter | Opens rejected over `maxConcurrentStreamsPerConnection` |
| `mm_server_stream_frames_dropped_total` | counter | Stream frames for unknown/retired msgids, dropped |

**Client:**

| Label | Kind | Meaning |
|---|---|---|
| `mm_client_calls_total` / `mm_client_call_failures_total` | counter | Calls issued / calls that resolved `.failure` |
| `mm_client_call_roundtrip_ns` | timer | Unary round-trip, send to resolved response |
| `mm_client_responses_unmatched_total` | counter | Responses whose msgid matched no pending call |
| `mm_client_protocol_violations_total` | counter | Undecodable frames and inbound requests (connection-fatal) |
| `mm_client_streams_opened_total` | counter | Streaming calls opened |
| `mm_client_stream_frames_dropped_total` | counter | Stream frames for unknown/retired msgids, dropped |
| `mm_client_stream_item_decode_failures_total` | counter | Stream elements that failed to decode (dropped with a warning; the stream continues) |

Instruments are process-global by label: bundles like `MMStreamMetrics` are constructed per connection but alias the same counters, so numbers aggregate across connections by design. Tests that need isolation inject a private capturing `MetricsFactory` (`MMStreamMetrics(factory:)`) instead of bootstrapping the global system.

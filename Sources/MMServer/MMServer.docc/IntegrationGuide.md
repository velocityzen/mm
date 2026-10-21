# Integration guide

This guide shows how a host application embeds matter-in-motion: define a method namespace, store ACLs in SQLite, add the server to your existing `ServiceGroup`, harden it, stream from handlers, and connect a client from a companion process. The example is **eyed**, the long-running per-user daemon this library was built for, which owns a `journal` domain. Nothing here is eyed-specific; use your own domain.

Prerequisites: the host runs on swift-service-lifecycle (a `ServiceGroup` owns its services), uses SwiftNIO as its async runtime, and follows this library's internal rules: no free-floating `Task { }`, no blocking IO outside `NIOThreadPool`, no `Dispatch*`.

## 1. Define a method namespace

A `Method<Request, Response>` value holds a method's whole contract: the wire name, the `AccessMode` its verb needs on the target entity, and the request and response types as generics. Handlers and typed client calls share this descriptor, so put the namespace in a module both processes import.

Two wire rules matter:

- **The target entity is in the open envelope, not the payload.** The router parses and authorizes it before reading any params byte. Handlers read it from `auth.entity` (the per-call context). Payloads are plain values, with no entity field and no reserved key.
- **Structs encode as MessagePack maps with integer keys.** Decoders skip unknown keys, so evolution is append-only: new fields must be optional.

```swift
import MMSchema

// Public memberwise inits elided throughout for brevity.
public struct AppendRequest: Codable, Sendable {
    public var line: String
    public var tag: String?                // added in v1.1: optional, per the evolution rule

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

/// One streamed change on a followed journal. A response-stream *element* of
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
    /// Server push is an ordinary method with a response stream: correlated,
    /// authorized at open (`.read`, like `read`), fingerprinted, discoverable.
    public static let follow = ServerStreamMethod<FollowRequest, ChangeEvent, FollowSummary>(
        name: "journal.follow",
        access: .read
    )

    /// The sealed list the router cross-checks at startup, built with
    /// `@SchemaBuilder`: bare descriptor values (unary and streaming alike),
    /// erased for you.
    @SchemaBuilder public static var all: [AnyMethod] {
        append
        read
        follow
    }
}
```

Method names are dotted like entity paths, and the prefix is significant. `server.schema` treats it (`journal.append` → `journal`) as an entity when it filters discovery by traversal rights, and the router's namespace cross-check assigns routes by prefix. Name each method so its prefix is the entity subtree it acts on.

`@SchemaBuilder` supports the conditional forms of `@RouterBuilder` (`if`, `if`/`else`, `for`, and splicing another namespace's list by name). So one condition removes a feature-flagged method from both the schema and the router:

```swift
@SchemaBuilder public static var all: [AnyMethod] {
    append
    read
    if FeatureFlags.compaction {
        compact
    }
}
```

Keep descriptors as `static let`. `client.call(Journal.append, on: entity, request)` type-checks its request and response because the compiler sees `Journal.append` as a `Method<AppendRequest, AppendResponse>`. A builder composes only the type-erased list; typed calls need real declarations.

### Declaring the contract as data

For contract-first work, `Schema` declares the wire contract without Codable types and produces plain `MethodSignature` values:

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

Field keys follow declaration order; pin them when you evolve the contract (`Field(3, "note", .string)`). Every part keys its fields from 0, because the target entity is envelope metadata, not payload. `Request` and `Response` are optional; omit either for an empty payload (`read` and `follow` above). Compose shapes with `TypeSchema`: `.optional(.string)`, `.array(Fields { ... })`, `.map(key:value:)`, or nested blocks (`Field("owner") { Field("uid", .uint) }`).

`RequestStream` and `ResponseStream` declare streaming. Both are optional and combine freely with `Request`/`Response`. This is the four-part method model: in any combination, a method can take an opening request, receive elements from the client, send elements to the client, and return a terminal:

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

Stream elements are plain values with no injected entity; authorization runs once, on the opening request's entity. Each stream part takes a reserved `StreamOptions` argument for future per-stream settings. The [wire protocol specification](https://swiftpackageindex.com/velocityzen/mm/documentation/mmwire/wireprotocol) §4.2 defines the correlated frames, credit-based flow control, and END/STOP/CANCEL termination. §5 and §6 below cover the handler and client APIs.

#### Named types, enums, and descriptions

`Enum` and `Type` declare **named types**: nominal contract types that fields can reference. Every element accepts an optional `description:`, which discovery serves to peers. Descriptions are documentation only: never fingerprinted, never counted as drift.

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

Any of the four parts can also **be** a named type instead of declaring fields, because the entity is in the envelope and every payload is a plain value: `Request(.reference("SetPayload"))`, `Response(.reference("LineMeta"))`, `ResponseStream(.reference("ChangeEvent"))`, or cross-schema `Request(CommonTypes.Stamp.self)`. `#schema` then generates no struct for that part; the payload type is the named type itself (`Method<SetPayload, LineMeta>`):

```swift
Type("SetPayload", description: "Shared set request") {
    Field("line", .string)
}
Call("set") {
    Access { .write }
    Request(.reference("SetPayload"))
}
```

Rules for named types:

- Enums are **string-valued** on the wire: the case name is the value. Renaming a case breaks the wire; reordering does not. Generated Swift enums add an `unknown` fallback case (the house rule for wire enums).
- Names are **nominal**: `journal.Priority` is part of the contract and the fingerprint. Discovery serves a `TypeDefinition` table beside the method list, filtered to the types each peer's visible methods reach.
- An undotted reference (`"Priority"`) must resolve within the block and is qualified automatically. A dotted one (`"common.LineMeta"`) is cross-schema and validated at server startup.
- Shared types outside any method namespace go in a `Types("common") { Enum/Type... }` block (runtime) or a `#schemaTypes` container (macro, below). Register them on the server with the `Types(CommonTypes.self)` builder element.

The declaration has three uses:

- `journalContract.verify(against: Journal.self)`: a test that the Codable types match all four parts (request, requestStream, response, responseStream) **and the declared type table**. An empty mismatch list means a match. The contract file stays the single source of truth, and drift fails CI. Shape checks probe decoder behavior, so a `SchemaDescribable` conformance cannot vouch for itself. Descriptions are ignored.
- `SchemaDifference(local: journalContract, remote: discovered)`: the client diffs the declared contract (signatures and named types) against a live server.
- `journalContract.fingerprint()`: pins the expected hello fingerprint when the declaration covers the server's complete method set and type table.

A *runtime* declaration cannot create `Method<Request, Response>` descriptors. Their generics make `client.call` typed, and only real type declarations provide them. (The DSL element is named `Call` because `Method` is the typed descriptor.) The macro form solves this:

### `#schema`: the declaration as the compile-time source of truth

In a namespace enum, `#schema` reads the same DSL and **generates** what the runtime form cannot: the request, response, and stream-element structs (integer `CodingKeys` from 0, public memberwise inits), the typed descriptors, the `all` list, and the runtime `contract`. You write one declaration, with no duplication:

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

Generated type names default to `<Call>Request` / `<Call>Response` / `<Call>RequestItem` / `<Call>ResponseItem`. A leading string literal overrides them (`ResponseStream("ChangeEvent") { ... }`). Declare the `MethodNamespace` conformance on the enum yourself; a freestanding macro cannot add it. Re-export the nested generated types with typealiases if you want them at top level. Keep the daemon's boot check, `Journal.contract.verify(against: Journal.self)`. On every start it probes the generated Codable types and compares them with the re-emitted declaration, which checks the macro output.

`Enum`/`Type` declarations expand too. `Enum("Priority") { Case("normal"); Case("urgent") }` generates a `String`-raw Swift enum with a generated `unknown` case for unrecognized wire values. `Type("LineMeta") { ... }` generates a struct. Both are `SchemaDescribable` as their qualified `.reference`. The macro also generates the namespace's `types` definition table and per-type decoder-behavior probes for `verify`. Every `description:` appears in the served signatures and as doc comments on the generated Swift declarations. Shared types get their own container:

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

Cross-schema references in a `#schema` block use the Swift type (`Field("x", Other.Name.self)`), because the macro cannot know the Swift type behind a dotted wire name. Compiler limitation: a macro argument cannot reference members that another container's macro generates **in the same module**. (The compiler does not expand one macro's arbitrary names while it type-checks another macro's arguments.) Put shared `#schemaTypes` containers in their own module, or reference hand-written `SchemaDescribable` types.

The macro accepts only the DSL's **static subset**: literal names and keys, no runtime conditionals, no `payload:`/`.bytes` shapes, and no wire type mapped from `.string` other than `String` (for example, an `EntityName`-typed field needs a hand-written type). For anything else (feature-flagged methods, hand-tuned Codable, `.bytes`), use the runtime DSL with hand-written types. Both forms can share one namespace. `#schema` requires the toolchain to build the `MMSchemaMacros` plugin (swift-syntax, compile time only, never linked into your product).

## 2. An `EntityACLProvider` backed by SQLite

For a **static** ACL table (fixtures, small daemons, tests), declare the entity tree inline. This builds an `InMemoryACLProvider`:

```swift
ACLProvider {
    Entity("journal", owner: uid, group: gid, mode: 0o750) {
        Entity("notes")                            // journal.notes: inherits owner/group, mode 0o750
        Entity("system", owner: 0, group: 0, mode: 0o700)
    }
}
```

Children use paths relative to the parent and inherit its `owner`/`group` unless overridden. `mode` defaults to `EntityACL.defaultCreationMode` (0o750). Top-level entities must state owner and group, because authorization never has a default. Invalid paths and duplicates fail at startup.

Hosts whose ACLs live in storage and change at runtime implement the provider protocol and pass the instance (`ACLProvider(provider)`). This protocol is the host's only authorization interface. It is `async` because real providers read storage:

```swift
public protocol EntityACLProvider: Sendable {
    func acl(for entity: EntityName) async -> Result<EntityACL?, ACLProviderError>
    func invalidate(_ entity: EntityName) async
}
```

The router enforces this contract:

- `.success(nil)` means "no ACL record for this entity". The router answers `permissionDenied`, never "not found", so peers cannot probe whether an entity exists. An entity without a row is unreachable for everyone.
- `.failure(ACLProviderError)` means the provider itself failed. The router logs it and answers `internalError`; provider details never reach the wire.
- `invalidate(_:)` is the chmod-equivalent hook. Implementations that **cache** must drop the entity's cached entry before returning, so the next `acl(for:)` sees the change. The v1 router does not cache, and dispatch correctness never depends on this hook. It lets hosts add caching without changing the router.

`acl(for:)` is on the hot path. Each request does one lookup per ancestor prefix (traversal `x` checks) plus one for the target. A request to `journal.main` costs two (`journal`, then `journal.main`). Cache accordingly.

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
    /// write, entity creation, and entity deletion: anything that changes
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

Caching notes, most important first:

- **Invalidate on creation and deletion, not only chmod.** This provider caches misses (`nil` rows), so a newly created `journal.scratch` stays invisible until you call `invalidate(entity("journal.scratch"))`. If your mutation paths cannot reliably list the affected entities, cache only positive rows.
- **Never cache failures.** A temporary storage error must not become a permanent denial.
- **Know the ACL semantics you serve.** The first matching class wins: a peer classified as owner is judged by owner bits alone, even if group or other bits would grant. uid 0 is not special. Traversal requires `x` on every ancestor prefix. The router enforces all of this through `EntityACL.permitted`; the provider only stores and fetches.
- The library ships `InMemoryACLProvider` (an actor over a dictionary) for tests and small daemons. Its `invalidate` is a documented no-op, because it never caches.

### Grants are per entity and per mode: declare what a route accepts when that is too broad

A mode bit on an entity gates **every** method of that access class, as a file's read bit gates every program that opens the file. There are no per-method grants: you cannot let a peer call `server.entity` on a target but not `journal.read`. Methods (verbs) and entities (nouns) are independent by design, so the router authorizes `journal.read` on `system.something` if the peer can traverse to it and read it.

That is right for a daemon with one method family over its own subtree. With **several** families over one entity tree, a grant made for one family admits the same-class verbs of every family. When that is too broad, declare the targets a route accepts with `Accepts`, the optional second argument of `On`/`Handle`:

```swift
On(Journal.read, Accepts("journal.*")) { auth, request in ... }      // journal's descendants
On(System.rotate, Accepts("system.log", "system.audit")) { ... }     // exactly these entities
On(Journal.read, Accepts("tenants.*.journal.*")) { ... }             // any tenant's journal subtree
On(Tree.walk, Accepts(.root, .all)) { ... }                          // root AND any entity
```

Patterns combine: any match admits the target. The grammar:

- A pattern is dot-separated segments, each a literal or `*`. `*` matches exactly one segment: `"tenants.*.journal"` admits `tenants.acme.journal`, not `tenants.a.b.journal`.
- A **trailing** `.*` matches one or more further segments at any depth. So `"journal.*"` means strict descendants (as in a glob); also list `"journal"` when the namespace entity is itself a target.
- A bare name matches exactly that entity.
- `"*"` / `.all` has no prefix and matches any depth: any non-root entity. This is the default.
- `.root` admits root-targeted dispatches. It is the only way to accept them, because root has no ACL. Reserve it for methods with documented tree-wide behavior whose handlers enforce their own authorization (as the builtin `server.schema` does).

The router checks `Accepts` right after the target parses, before any ACL lookup. An unaccepted target gets the same wire error as a denial, so a caller cannot tell "outside this method's targets" from "no access". `Accepts` is routing policy, not contract: never fingerprinted, never served by discovery. Entity-agnostic methods (the builtin `server.entity`, a backup verb for any subtree) keep the default.

When `Accepts` names **exactly one** concrete entity (one pattern, no wildcards, like `Accepts("system.log")`), a request **without an entity** targets it. The client omits `on:` (which defaults to root), or the CLI omits the `<entity>` positional. The server infers the target and runs the usual traversal and target ACL checks on it. Wider patterns infer nothing; such a request is denied like any unaccepted target, so omission is never ambiguous. Inference is server-side only: clients never see `Accepts`, and omitting the entity on the wrong daemon just returns a denial.

## 3. Declaring the server inside the existing `ServiceGroup`

`MMService` is a swift-service-lifecycle `Service`, so eyed adds one more entry to the `ServiceGroup` it already runs instead of a new lifecycle mechanism. One builder holds configuration, authorization, logging, and handlers. Before `run()` is called, it builds the `Router` (with `registerBuiltins: true`, so `server.schema` and `server.entity` exist without user code), computes the hello fingerprint from every registered signature, and prepares metrics.

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
        // return Result<Response, MMError>. Domain failures go to the
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
        // Or a reusable group declared in its own file (see below).
        JournalReadHandlers(store: store)
    }
}
```

Required: exactly one `Configuration` and exactly one `ACLProvider` (authorization has no default, on purpose). Optional: `Log` (a `Logger`, a `label:level:` pair, or a closure sink `Log { level, message in ... }`), `OnBind { address in ... }`, and `Types(CommonTypes.self)` for each shared types-only container (`#schemaTypes` block) your schemas reference. Namespaces declared with `For` add their own type tables automatically. Violations fail at daemon startup, like every router precondition. This includes a duplicate type definition and a `.reference` that no registered table resolves.

A `RouteGroup` is a separately declared bundle of handlers with its own dependencies, like a custom SwiftUI view:

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
        // its next send. Production handlers pair this loop with a
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

(The parameter-based `MMService(configuration:namespaces:aclProvider:logger:onBind:routes:)` initializer and the `Handle(method) { request, context in ... }` form still work. `On` and `Handle` register identical routes; `On` only puts the context first in the closure parameters, for the builder style.)

### Startup ordering: `ServiceReadiness` and `GatedService`

swift-service-lifecycle starts all group members concurrently and orders only *shutdown* (reverse array order). It has no readiness concept, by design. If a sibling service must not start before the RPC socket listens (a discovery announcer, a health gate, an in-process client), add the ordering yourself:

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

`GatedService` waits for its readiness signals, then runs the wrapped service. With reverse-order shutdown, this gives full dependency ordering: the dependent starts after its dependency and stops before it. A graceful shutdown during the wait exits cleanly; the wrapped service never started, so nothing needs draining. `Ready` can appear more than once (one signal per dependent) and works with an explicit `OnBind`.

```swift
// eyed's existing group: the RPC server is just one more service beside the
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

The `@RouterBuilder` closure accepts plain `Handle(...)` expressions, pre-built `[Route]` groups, `if`/`else`, and `for` loops, so routes can be registered conditionally at startup (feature flags, platform differences).

**Startup preconditions fail fast on purpose.** Every misregistration is a `precondition` failure at daemon boot: a crash in the first second of deployment, not a surprise at the first call. At `init`, the router checks that:

- no method name is duplicated across all routes (builtins included);
- every descriptor in each declared namespace's `all` has a registered route;
- every route under a prefix owned by a declared namespace is in that namespace's `all` list (so no route escapes the fingerprint cross-check);
- every request/response type passes the schema probe, so the fingerprint covers everything and no type fails at first decode;
- every method name's namespace prefix parses as a valid `EntityName`.

Passing `namespaces: [Journal.self]` enables the second and third checks. A namespace left out of the list silently skips its cross-check, so declare every namespace you register routes for. `server.router` exposes the assembled router; its `fingerprint` and `signatures` are useful at build time (§6).

Graceful shutdown is correct end to end. The listener closes first. Open connections stop reading while in-flight handlers complete and flush. Channels close. For unix endpoints, the socket file is unlinked last, after a device/inode identity check, so a slow drain never deletes a newer instance's socket.

Optionally, bootstrap swift-log with `MMLogContext.metadataProvider` (or merge it into your provider). Then every log line in a connection's task tree carries the `connection` id, including lines your handlers write with your own loggers.

## 4. Server configuration hardening

Every setting in `MMServerConfiguration` is bounded, so no peer can grow server memory without limit:

- `maxFrameLength` (default 16 MiB = `MMWireInfo.defaultMaxFrameLength`): the per-frame memory a peer can make the server accumulate. The frame decoder checks it **before** accumulating: a peer that *claims* a larger frame has its connection failed at once.
- `maxConnections` (default 128): total concurrent connections, checked at accept. An over-cap connection is closed at once and counted as a rejection. No busy frame is sent, because before the hello there is no msgid to attach an error to.
- `maxInFlightRequestsPerConnection` (default 16): concurrent unary handler runs per connection. An over-cap request gets `tooManyInFlight` (code 4) at once; nothing queues.
- `maxConcurrentStreamsPerConnection` (default 8): concurrent streaming calls per connection, counted separately from the unary cap. The credit window (§5) bounds each stream's buffers, so this bounds the total stream memory a peer can hold open.
- `idleTimeout` (default 120 s, monotonic `TimeAmount`): how long a connection may have no traffic in *either* direction before it is closed. This includes clients that never complete the hello. Outbound traffic counts on purpose: a client that only consumes a response stream sends little.
- `unixSocketMode` (default `0o660`): who can connect at all. The server applies it with `chmod(2)` **between `bind(2)` and `listen(2)`**, so no connection is ever accepted under a looser umask-derived mode. This is the outer authorization boundary: ACLs decide everything after connect, and this mode decides connect. Use `0o600` for strictly single-user daemons, and set the socket *directory*'s ownership deliberately too. Ignored for TCP.
- `capabilities` (default 0): the hello capability bitset. v1 defines no bits.

eyed lowers the frame cap (journal lines are small; 16 MiB is generous for a schema response but far too large for `journal.append`) and sets the socket mode:

```swift
let configuration = MMServerConfiguration(
    endpoint: .unix(path: "/var/run/eyed/rpc.sock"),
    maxFrameLength: 1 << 20,          // 1 MiB: largest legitimate payload, with margin
    maxConnections: 64,
    idleTimeout: .seconds(300),       // tools that keep a follow stream open
    unixSocketMode: 0o660             // owner + service group; the group is the grant
)
```

TCP endpoints exist (`.tcp(host:port:)`; port 0 with the `onBind` callback for ephemeral ports) but carry **no peer identity in v1**. Every TCP peer is `PeerIdentity.anonymous`, so only ACL *other*-class bits apply. Use raw TCP only on trusted networks. The documented remote path is SSH unix-socket forwarding, which keeps kernel peer credentials end to end.

## 5. Streaming from handlers

Server push is an ordinary method with a `ResponseStream`, not a side channel:

- A server-streaming handler takes `(req, sink, ctx)`. It sends response elements through the credit-gated `MMResponseSink<Element>` and ends the call by returning its terminal `Result<Response, MMError>`.
- A client-streaming handler takes `(req, elements, ctx)`. `elements` is an `MMRequestStream<Element>`, a backpressured `AsyncSequence` that ends normally at the client's graceful END.
- A bidirectional handler takes `(req, elements, sink, ctx)`.

Authorization runs once, at open, on the request's entity, as for a unary call.

`sink.send(_:)` is the whole outbound API. It encodes the element, spends one credit, and returns a `StreamSendOutcome`. All three cases are *graceful*, not errors:

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
            // producing task: memory stays bounded, siblings unaffected).
            delivered += 1
        case .peerStopped:
            // The client sent STOP ("I have seen enough, wrap up"): graceful,
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

Production note: protect the store's follower registry with a lock, not actor isolation, and make each follower stream's `onTermination` unregister it. Termination handlers are synchronous, so an actor-isolated registry cannot clean up a dead follower without spawning a task. `Examples/Daemon/FollowerHub.swift` is the reference: it removes the registration under the lock, calls `finish()` only after releasing the lock (a termination handler re-enters the registry), and makes removal idempotent so handler and termination cleanup can race safely. That is also why `store.follow`/`store.unfollow` above are synchronous, not `await`ed.

Client streaming is the reverse. Iterate `elements` to consume request items (consuming grants the client more credit). The end of the sequence *is* the client's graceful END:

```swift
Handle(Journal.import) { request, elements, auth in
    var imported = 0
    for await line in elements {            // normal end == client END
        _ = await store.append(line.text, to: auth.entity)
        imported += 1
    }
    return .success(ImportSummary(imported: imported))
    // elements.stop() would send a server-initiated STOP (advisory): "I have all
    // the request items I need". The call still runs to this terminal.
}
```

Design around these semantics:

- **Cross-connection fan-out is host logic.** Each `follow` call gets one correlated response stream. Delivering appends from *any* connection to every interested follower is the store's job (the registry the handler above uses). The library provides the per-call stream, not publish/subscribe.
- **Flow control is automatic and bounded.** The window starts at 8 items per direction. A slow consumer stops the producer at zero credit instead of growing memory, and a stalled stream never blocks sibling calls (no head-of-line blocking).
- **Streaming methods *are* fingerprinted and discoverable**, unlike the removed notification mechanism. A response stream is part of the method signature (`server.schema` reports its element shape), so clients detect a reshape through the hello fingerprint and discovery, like any contract change. Element payloads still evolve append-only (new fields optional).
- **Termination is graceful by default.** END finishes a direction, STOP asks the peer to finish (`.peerStopped`), and the terminal is always the last frame. CANCEL and connection loss arrive as `.callEnded` or task cancellation. A handler relaying a **quiet** source sees STOP only at its next send, possibly much later. So watch `sink.stopRequested()` from a structured sibling: it waits for STOP (or the call's end) so the handler can return its terminal promptly. Full matrix: the [wire protocol specification](https://swiftpackageindex.com/velocityzen/mm/documentation/mmwire/wireprotocol) §4.2.

## 6. The client side: a companion process

The client (for example `eyectl`, or a sibling daemon) imports the same namespace module and `MMClient`.

**One connection, many calls.** A connection multiplexes: each call gets its own msgid, concurrent callers interleave freely (up to `maxInFlightCalls`), and streams share the connection with per-stream credit windows. Open one connection per *unit of work* (a daemon's lifetime, a tool run), never per call.

**Own the lifecycle in one of two supported shapes:**

```swift
import MMClient
import MMClientService  // product MMClientService: the ServiceGroup adapter
import MMSchema
import ServiceLifecycle

// Shape 1. Daemons: the ServiceGroup adapter.
let connection = try await MMClientConnection.connect(
    to: .unix(path: "/var/run/eyed/rpc.sock"),
    configuration: MMClientConfiguration(schema: .complete([Eye.contract]))
).get()
let group = ServiceGroup(configuration: .init(
    services: [.init(service: MMClientService(connection: connection))],
    gracefulShutdownSignals: [.sigterm],
    cancellationSignals: [.sigint],
    logger: logger
))
try await group.run()

// Shape 2. Tools and tests: the bracket. Acquire connects AND starts the
// inbound loop; dispose closes, joins it, and returns the loop's outcome as
// the release verdict. The bracket fails if the connection did not survive
// the scope (`with` is sugar over `MMClientConnection.open`, an FPBracket
// resource).
let reply = await MMClientConnection.with(.unix(path: socketPath)) { connection in
    await connection.call(Journal.append, on: journalMain, AppendRequest(line: "hello"))
}
```

Custom choreography (stream drainers in sibling tasks, staged teardown) goes *inside* the bracket body as structured children (`async let`, a local group). The bracket still owns the lifecycle around it.

`connect` performs only the bootstrap and hello exchange. It starts no tasks; the connection does nothing until its loop runs. Every connected connection must eventually see `run()` or `close()`. Calls issued before `run()` starts wait until the loop creates the writer, so start it promptly. When the connection dies (EOF, transport error, `close()`, cancellation), pending calls fail with `MMCallError.connectionClosed`, `state` becomes `.closed(reason:)`, and `run()` returns. v1 does not reconnect, by design: a closed connection stays closed. Retry policy is application logic, driven by `stateUpdates()`.

**Typed calls** return `Result<Response, MMCallError>`; nothing throws on the data path:

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

`maxInFlightCalls` (default 16, matching the server's per-connection cap) bounds calls. The excess fails at once with `.tooManyInFlight` and is never queued. Cancelling the awaiting task abandons the msgid locally: the server may still execute the request, but the response is not delivered.

**Streaming calls** return a typed handle, not a `Result`. A server-streaming `call` returns an `InboundStreamHandle<Element, Response>`: a single-iteration `AsyncSequence` of elements over `NIOAsyncSequenceProducer` (bounded buffer, real backpressure, never a bare `AsyncStream`), an awaitable `result()` terminal, and `stop()` / `cancel()` control:

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

Iterating the sequence grants credit back to the server. The initial window of 8 arrives unrequested; each further window the consumer drains sends a grant. A consumer that stops draining stops granting, so the server waits at zero credit and memory stays bounded. `stop()` sends a graceful STOP. `cancel()` (or cancelling the consuming task's own cancellation handler) sends CANCEL and resolves every surface `.cancelled`. An element that fails to decode is dropped with a warning and a counter increment; it never ends the sequence.

A client-streaming `call` returns the reverse, an `OutboundStreamHandle<Element, Response>`: a credit-gated `send(_:)` that returns a `StreamSendOutcome`, a one-shot `finish()` (END), and an awaitable `result()`:

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

A bidirectional `call` returns a `BidirectionalStreamHandle` whose independent `.inbound` and `.outbound` halves (drive them from different tasks) share one terminal.

**Head-of-line behavior (intended):** the credit window bounds the inbound element buffer. When a slow consumer's buffer fills, the connection's inbound loop *suspends before reading more frames*, so the socket pauses the server's writes for *that stream*. Credits are per stream, so only that stream stalls; sibling calls and streams continue. Still, iterate an inbound stream from a task that does **not** also await other traffic on this connection, and hand elements to your own pipeline instead of doing slow work in the `for await` body.

**Schema verification is automatic: declare contracts, never a fingerprint.** Give the client configuration the contracts this build was compiled against, and the connection verifies itself right after `run()` starts. A mismatch never disconnects; the verdict is a value:

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
    // .noExpectation / .denied / .failed(callError). No verdict; act per
    // application policy.
    log(reason)
}
```

For custom policy over the raw buckets, use the manual flow underneath: `connection.verifyContracts([...])` for a scoped diff, or `discoverSchema()` + `SchemaDifference(local:remote:)`. `remote.methods` is filtered by *this peer's* traversal rights. `remote.fingerprint` is the server's unfiltered value, comparable with `connection.server.fingerprint`.

`SchemaDifference` buckets:

- `missingMethods`: absent *or invisible to this peer* (the fix may be an ACL change, not a deploy).
- `signatureChanged`: the wire contract changed under this build.
- `accessChanged`: the verb now needs a different permission class.
- `remoteOnly`: harmless; useful for upgrade planning.
- `missingTypes`, `typeChanged`, `remoteOnlyTypes`: the named-type buckets. `typeChanged` (same qualified name, different shape) counts like `signatureChanged` for features that carry the type.

Prefer `SchemaDifference(local: contract, remote:)` with a `SchemaDeclaration` so types are diffed too. Comparisons ignore descriptions (doc edits are never drift), and buckets are sorted by name for deterministic logs. The value is `CustomStringConvertible`: `"\(diff)"` renders `in sync` or the non-empty buckets (`missing: a.get; types changed: common.Priority`), so log it directly instead of iterating buckets.

## 7. Operational defaults

Every value is verified against the shipped initializers and constants.

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

Server and client both emit metrics through [swift-metrics](https://github.com/apple/swift-metrics), a facade like swift-log. The library only **emits**: it never opens a port, serves a `/metrics` endpoint, or bootstraps a backend. Until the host bootstraps one, every instrument uses the built-in no-op handler (near-zero cost, data discarded). Exposing the numbers is a host decision, made once before the `ServiceGroup` runs:

```swift
import Metrics
import Prometheus   // swift-prometheus

let registry = PrometheusCollectorRegistry()
MetricsSystem.bootstrap(PrometheusMetricsFactory(registry: registry))
// Serve the scrape text yourself: a tiny HTTP endpoint returning
// registry.emit(into:), or write it periodically to a file for
// node_exporter's textfile collector. Push-style backends (StatsD,
// an OTel exporter) need no listening port at all.
```

**You decide who can see metrics; the library does not.** They do not use the RPC socket, are not a builtin method, and are outside the entity-ACL model, so whatever the backend opens is a *new* surface. It also reveals usage: call rates, denial counts, and connection activity. Bind a scrape endpoint to localhost or a mode-restricted Unix socket, or use a push backend, with the same care §4 gives `unixSocketMode`.

The labels are a stable operational contract; internal refactors do not change them. Counters are monotonic and end in `_total`. The two timers record nanoseconds.

**Server: connection lifecycle and frames**

| Label | Kind | Meaning |
|---|---|---|
| `mm_server_connections_accepted_total` | counter | Connections accepted |
| `mm_server_connections_rejected_total` | counter | Connections closed at accept over `maxConnections` |
| `mm_server_active_connections` | gauge | Currently open connections |
| `mm_server_accept_failures_total` | counter | Per-child accept failures absorbed without killing the listener |
| `mm_server_frames_in_total` / `mm_server_frames_out_total` | counter | Framed messages read / written |
| `mm_server_protocol_violations_total` | counter | Bad hellos and undecodable/ill-formed frames (connection-fatal) |

**Server: routing and streams**

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

Instruments are process-global by label. Bundles like `MMStreamMetrics` are created per connection but share the same counters, so numbers aggregate across connections by design. Tests that need isolation inject a private capturing `MetricsFactory` (`MMStreamMetrics(factory:)`) instead of bootstrapping the global system.

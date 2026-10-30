# Integration guide

This guide shows how a host application embeds matter-in-motion: define a method namespace, store ACLs, declare the server as a resource and run it, harden it, stream from handlers, and connect a client. The running example is the journal daemon and client in the repository's `Examples/` directory. `mm-example-daemon` serves a `journal` namespace over a Unix socket, and `mm-example-client` walks every call pattern against it. The snippets are excerpts of those sources. Where the guide goes further than the example (a SQLite ACL provider, hardened configuration, metrics), the snippet changes the example daemon instead of introducing another application.

Prerequisites: the host owns its resources as [fp-swift-bracket](https://github.com/velocityzen/fp-swift-bracket) brackets (the example daemon runs them with [fp-swift-service](https://github.com/velocityzen/fp-swift-service), which maps signals to a graceful stop), uses SwiftNIO as its async runtime, and follows this library's internal rules: no free-floating `Task { }`, no blocking IO outside `NIOThreadPool`, no `Dispatch*`.

## 1. Define a method namespace

A `Method<Request, Response>` value holds a method's whole contract: the wire name, the `AccessMode` its verb needs on the target entity, and the request and response types as generics. Handlers and typed client calls share this descriptor, so put the namespace in a module both processes import. The example's is `MMExampleAPI` (`Examples/API/JournalAPI.swift`). It depends on `MMSchema` only, so client-only processes never link the server.

Two wire rules matter:

- **The target entity is in the open envelope, not the payload.** The router parses and authorizes it before reading any params byte. Handlers read it from `auth.entity` (the per-call context). Payloads are plain values, with no entity field and no reserved key.
- **Structs encode as MessagePack maps with integer keys.** Decoders skip unknown keys, so evolution is append-only: new fields must be optional.

### `#schema`: the declaration as the source of truth

The example declares its namespace once, with `#schema`. The macro reads the declaration and **generates** the request, response, and stream-element structs (integer `CodingKeys` from 0, public memberwise inits), the typed descriptors, the `all` list, and the runtime `contract`. You write one declaration, with no duplication:

```swift
import MMSchema

public enum Journal: MethodNamespace {
    #schema(
        "journal",
        description: "Append-only journals: write lines, read them back, follow changes live."
    ) {
        // Enum/Type declarations and the stream methods: below.
        // The CLI(...) overlays are covered in MMCLI.
        Call("append", description: "Appends one line to a journal") {
            Access { .write }
            Request {
                Field("line", .string, description: "The line text")
                Field(
                    "meta",
                    .optional(.reference("LineMeta")),
                    description: "Optional attribution"
                )
            }
            Response {
                Field("count", .int, description: "Lines now in the journal")
            }
        }
        Call("read", description: "Returns every line in the journal") {
            Access { .read }
            Response {
                Field("lines", .array(.string))
            }
        }
    }
}

// The generated types live inside `Journal`; re-export them so handler and
// client code reads naturally.
public typealias AppendRequest = Journal.AppendRequest
public typealias AppendResponse = Journal.AppendResponse
public typealias ReadRequest = Journal.ReadRequest
public typealias ReadResponse = Journal.ReadResponse
```

Generated type names default to `<Call>Request` / `<Call>Response` / `<Call>RequestItem` / `<Call>ResponseItem`. A leading string literal overrides them (`Response("FollowSummary") { ... }`). Declare the `MethodNamespace` conformance on the enum yourself; a freestanding macro cannot add it. Field keys follow declaration order; pin them when you evolve the contract (`Field(3, "note", .string)`). Every part keys its fields from 0, because the target entity is envelope metadata, not payload. `Request` and `Response` are optional; omit either for an empty payload (`read` above has no `Request`).

Method names are dotted like entity paths, and the prefix is significant. `server.schema` treats it (`journal.append` → `journal`) as an entity when it filters discovery by traversal rights, and the router's namespace cross-check assigns routes by prefix. Name each method so its prefix is the entity subtree it acts on.

### Streaming methods: the four-part model

`RequestStream` and `ResponseStream` declare streaming. Both are optional and combine freely with `Request`/`Response`. In any combination, a method can take an opening request, receive elements from the client, send elements to the client, and return a terminal. The example declares one of each streaming shape:

```swift
// Server → client: a ChangeEvent for every append to the journal (from any
// connection) until the follower STOPs; the terminal summarizes delivery.
Call("follow", description: "Streams every change to a journal until STOP") {
    Access { .read }
    ResponseStream(.reference("ChangeEvent"))
    Response("FollowSummary", description: "What was delivered before STOP") {
        Field("delivered", .int)
    }
}
// Client → server: the client streams lines and finishes; the terminal
// reports how many landed and the journal's new total.
Call("import", description: "Bulk-appends a stream of lines") {
    Access { .write }
    RequestStream("ImportLine", description: "One line to append") {
        Field("line", .string)
    }
    Response("ImportSummary") {
        Field("imported", .int)
        Field("total", .int)
    }
}
// Duplex: lines up the request stream, each resulting ChangeEvent straight
// back down the response stream, one shared terminal.
Call("sync", description: "Appends a stream of lines, echoing each change back") {
    Access { .write }
    RequestStream("SyncLine", description: "One line to append") {
        Field("line", .string)
    }
    ResponseStream(.reference("ChangeEvent"))
    Response("SyncSummary") {
        Field("synced", .int)
        Field("total", .int)
    }
}
```

Server push is an ordinary method with a response stream: correlated, authorized at open (`follow` needs `.read`, like `read`), fingerprinted, and discoverable. Stream elements are plain values with no injected entity; authorization runs once, on the opening request's entity. Each stream part takes a reserved `StreamOptions` argument for future per-stream settings. The [wire protocol specification](https://swiftpackageindex.com/velocityzen/mm/documentation/mmwire/wireprotocol) §4.2 defines the correlated frames, credit-based flow control, and END/STOP/CANCEL termination. §5 and §6 below cover the handler and client APIs.

### Named types, enums, and descriptions

`Enum` and `Type` declare **named types**: nominal contract types that fields can reference. Every element accepts an optional `description:`, which discovery serves to peers. Descriptions are documentation only: never fingerprinted, never counted as drift. The example's three:

```swift
Enum("Priority", description: "How urgent a line is") {
    Case("normal")
    Case("urgent", description: "Surfaces immediately to followers")
}
Type("LineMeta", description: "Attribution carried with a line") {
    Field("author", .string, description: "Who wrote the line")
    Field("priority", "Priority")
}
Type("ChangeEvent", description: "One appended line, as delivered to followers") {
    Field("entity", .string)
    Field("line", .string)
    Field("count", .int)
}
```

`append`'s `meta` field references `LineMeta` by local name. Any of the four parts can also **be** a named type instead of declaring fields, because the entity is in the envelope and every payload is a plain value. `follow` and `sync` above stream `ResponseStream(.reference("ChangeEvent"))`, so both share one element type, and `#schema` generates no separate struct for those parts.

`Enum` generates a `String`-raw Swift enum with an `unknown` case for unrecognized wire values. `Type` generates a struct. Both are `SchemaDescribable` as their qualified `.reference`. The macro also generates the namespace's `types` definition table and per-type decoder-behavior probes for `verify`. Every `description:` appears in the served signatures and as doc comments on the generated Swift declarations.

Rules for named types:

- Enums are **string-valued** on the wire: the case name is the value. Renaming a case breaks the wire; reordering does not. The generated `unknown` case is the house rule for wire enums.
- Names are **nominal**: `journal.Priority` is part of the contract and the fingerprint. Discovery serves a `TypeDefinition` table beside the method list, filtered to the types each peer's visible methods reach.
- An undotted reference (`"Priority"`) must resolve within the block and is qualified automatically. A dotted one (`"common.LineMeta"`) is cross-schema and validated at server startup.
- Shared types outside any method namespace go in a `#schemaTypes("common") { Enum/Type... }` container on a `TypeNamespace` enum (or a runtime `Types("common") { ... }` block). Register the container on the server with the `Types(Container.self)` builder element.

Cross-schema references in a `#schema` block use the Swift type (`Field("x", Other.Name.self)`), because the macro cannot know the Swift type behind a dotted wire name. Compiler limitation: a macro argument cannot reference members that another container's macro generates **in the same module**. (The compiler does not expand one macro's arbitrary names while it type-checks another macro's arguments.) Put shared `#schemaTypes` containers in their own module, or reference hand-written `SchemaDescribable` types.

### What `#schema` generates, written by hand

The macro accepts only the DSL's **static subset**: literal names and keys, no runtime conditionals, no `payload:`/`.bytes` shapes, and no wire type mapped from `.string` other than `String` (for example, an `EntityName`-typed field needs a hand-written type). For anything else (feature-flagged methods, hand-tuned Codable, `.bytes`), write the types and descriptors yourself; both forms can share one namespace. Hand-written, the example's `append` and `read` are what the macro generates:

```swift
public struct AppendRequest: Codable, Hashable, Sendable {
    public var line: String
    public var meta: LineMeta?             // a named type: see below

    enum CodingKeys: Int, CodingKey {
        case line = 0
        case meta = 1
    }
}

public struct AppendResponse: Codable, Hashable, Sendable {
    public var count: Int

    enum CodingKeys: Int, CodingKey {
        case count = 0
    }
}

/// `read` declares no Request: an empty payload. A property-less decoder
/// cannot be probed, so empty structs describe themselves.
public struct ReadRequest: Codable, Hashable, Sendable, SchemaDescribable {
    public static var schema: TypeSchema { .structure(fields: []) }
}

public struct ReadResponse: Codable, Hashable, Sendable {
    public var lines: [String]

    enum CodingKeys: Int, CodingKey {
        case lines = 0
    }
}

// Public memberwise inits elided.
public enum Journal: MethodNamespace {
    public static let append = Method<AppendRequest, AppendResponse>(
        name: "journal.append",
        access: .write
    )
    public static let read = Method<ReadRequest, ReadResponse>(
        name: "journal.read",
        access: .read
    )
    // The stream shapes have their own descriptor types:
    // ServerStreamMethod<FollowRequest, ChangeEvent, FollowSummary> (follow),
    // ClientStreamMethod<ImportRequest, ImportLine, ImportSummary> (import),
    // BidirectionalStreamMethod<SyncRequest, SyncLine, ChangeEvent, SyncSummary> (sync).

    /// The sealed list the router cross-checks at startup: bare descriptor
    /// values, unary and streaming alike, erased for you.
    @SchemaBuilder public static var all: [AnyMethod] {
        append
        read
    }
}
```

`@SchemaBuilder` supports the conditional forms of `@RouterBuilder` (`if`, `if`/`else`, `for`, and splicing another namespace's list by name), so one condition removes a feature-flagged method from both the schema and the router. Keep descriptors as `static let`. `connection.call(Journal.append, on: entity, request)` type-checks its request and response because the compiler sees `Journal.append` as a `Method<AppendRequest, AppendResponse>`. A builder composes only the type-erased list; typed calls need real declarations.

### The runtime declaration

`#schema` also emits `Journal.contract`, the declaration as a runtime `SchemaDeclaration` (the example re-exports it as `journalContract`). For contract-first work without Codable types, `Schema("journal") { ... }` builds the same value at runtime from the same DSL, for example the example's `read`:

```swift
let contract = Schema("journal") {
    Call("read") {
        Access { .read }
        Response {
            Field("lines", .array(.string))
        }
    }
}
```

A runtime declaration cannot create `Method<Request, Response>` descriptors. Their generics make `connection.call` typed, and only real type declarations provide them. (The DSL element is named `Call` because `Method` is the typed descriptor.)

The declaration has three uses, and the example uses the first two:

- `journalContract.verify(against: Journal.self)`: checks that the Codable types match all four parts (request, requestStream, response, responseStream) **and the declared type table**. An empty mismatch list means a match. Shape checks probe decoder behavior, so a `SchemaDescribable` conformance cannot vouch for itself. Descriptions are ignored. The example daemon runs it at boot, before it listens; with `#schema` it checks the macro output:

  ```swift
  switch journalContract.verify(against: Journal.self) {
      case .failure(let error):
          logger.critical("schema probe failed", metadata: ["error": "\(error)"])
          return
      case .success(let breaks) where !breaks.isEmpty:
          for line in breaks {
              logger.critical("contract violation", metadata: ["detail": "\(line)"])
          }
          return
      case .success:
          logger.info("contract verified", metadata: ["namespace": "journal"])
  }
  ```

  With hand-written types, the same call in a test makes drift fail CI.
- `SchemaDifference(local: journalContract, remote: discovered)`: the client diffs the declared contract (signatures and named types) against a live server (§6).
- `journalContract.fingerprint()`: the expected hello fingerprint when the declaration covers the server's complete method set and type table.

`#schema` requires the toolchain to build the `MMSchemaMacros` plugin (swift-syntax, compile time only, never linked into your product).

## 2. ACLs: a static table, or an `EntityACLProvider` backed by SQLite

For a **static** ACL table (fixtures, small daemons, tests), declare the entity tree inline. This builds an `InMemoryACLProvider`. The example daemon's table:

```swift
ACLProvider {
    Entity("journal", owner: uid, group: gid, mode: 0o750) {
        Entity("notes")
        Entity("system", owner: 0, group: 0, mode: 0o700)
    }
    // The builtins' method-name prefixes: granting r-x here makes
    // server.schema and server.entity visible in filtered discovery.
    Entity("server", owner: uid, group: gid, mode: 0o550)
}
```

Children use paths relative to the parent (`"notes"` under `"journal"` is `journal.notes`) and inherit its `owner`/`group` unless overridden. `mode` defaults to `EntityACL.defaultCreationMode` (0o750). Top-level entities must state owner and group, because authorization never has a default. Invalid paths and duplicates fail at startup. The example keys ownership to the uid and gid the daemon runs as, so the local user's client is the owner of `journal.notes`, and the root-owned `journal.system` (0o700) denies it.

Hosts whose ACLs live in storage and change at runtime implement the provider protocol and pass the instance (`ACLProvider(provider)`). This protocol is the host's only authorization interface. It is `async` because real providers read storage:

```swift
public protocol EntityACLProvider: Sendable {
    @concurrent func acl(for entity: EntityName) async -> Result<EntityACL?, ACLProviderError>
    @concurrent func invalidate(_ entity: EntityName) async
}
```

Both requirements are `@concurrent`: the router calls them from connection tasks, off any actor. Handlers run the same way, each in its call's own task.

The router enforces this contract:

- `.success(nil)` means "no ACL record for this entity". The router answers `permissionDenied`, never "not found", so peers cannot probe whether an entity exists. An entity without a row is unreachable for everyone.
- `.failure(ACLProviderError)` means the provider itself failed. The router logs it and answers `internalError`; provider details never reach the wire.
- `invalidate(_:)` is the chmod-equivalent hook. Implementations that **cache** must drop the entity's cached entry before returning, so the next `acl(for:)` sees the change. The v1 router does not cache, and dispatch correctness never depends on this hook. It lets hosts add caching without changing the router.

`acl(for:)` is on the hot path. Each request does one lookup per ancestor prefix (traversal `x` checks) plus one for the target. A request to `journal.notes` costs two (`journal`, then `journal.notes`). Cache accordingly.

To move the example daemon's table into storage, replace the `ACLProvider { ... }` block with a provider instance. SQLite calls are blocking IO, and the house rule is absolute: blocking IO runs on `NIOThreadPool.runIfActive`, never on an event loop or the cooperative pool.

```swift
import MMSchema
import MMServer
import NIOConcurrencyHelpers
import NIOPosix
import SQLite3  // Darwin system module; on Linux, a CSQLite system-library target

/// A storage-backed replacement for the example daemon's static table: one
/// table, a read-through cache, and every touch of SQLite on the NIOThreadPool.
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

    /// Called by the daemon's own mutation paths after every
    /// chmod/chown-equivalent write, entity creation, and entity deletion:
    /// anything that changes what `acl(for:)` should answer. Dropping before
    /// returning is the contract: the next lookup re-reads storage.
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

- **Invalidate on creation and deletion, not only chmod.** This provider caches misses (`nil` rows), so a journal created at runtime (say `journal.drafts`) stays invisible until you call `invalidate` for it. If your mutation paths cannot reliably list the affected entities, cache only positive rows.
- **Never cache failures.** A temporary storage error must not become a permanent denial.
- **Know the ACL semantics you serve.** The first matching class wins: a peer classified as owner is judged by owner bits alone, even if group or other bits would grant. uid 0 is not special. Traversal requires `x` on every ancestor prefix. The router enforces all of this through `EntityACL.permitted`; the provider only stores and fetches.
- The static `ACLProvider { ... }` table is an `InMemoryACLProvider` (an actor over a dictionary). Its `invalidate` is a documented no-op, because it never caches.

### Grants are per entity and per mode: declare what a route accepts when that is too broad

A mode bit on an entity gates **every** method of that access class, as a file's read bit gates every program that opens the file. There are no per-method grants: you cannot let a peer call `server.entity` on a target but not `journal.read`. Methods (verbs) and entities (nouns) are independent by design, so without further declaration the router authorizes `journal.read` on `server` if the peer can read it.

That is right for a daemon with one method family over its own subtree. With **several** families over one entity tree (the example has `journal` and the builtin `server`), a grant made for one family admits the same-class verbs of every family. When that is too broad, declare the targets a route accepts with `Accepts`, the optional second argument of `On`/`Handle`. Every route in the example's `JournalHandlers` keeps journal verbs on journal nouns:

```swift
On(Journal.read, Accepts("journal.*")) { auth, request in
    .success(ReadResponse(lines: await store.read(auth.entity)))
}
```

Patterns combine: any match admits the target. The grammar:

- A pattern is dot-separated segments, each a literal or `*`. `*` matches exactly one segment: `"*.notes"` admits `journal.notes`, not `journal.team.notes`.
- A **trailing** `.*` matches one or more further segments at any depth. So `"journal.*"` means strict descendants (as in a glob): `journal.notes`, `journal.system`, and anything below them, but not `journal`. Also list `"journal"` when the namespace entity is itself a target.
- A bare name matches exactly that entity: `Accepts("journal.notes")`.
- `"*"` / `.all` has no prefix and matches any depth: any non-root entity. This is the default.
- `.root` admits root-targeted dispatches. It is the only way to accept them, because root has no ACL. Reserve it for methods with documented tree-wide behavior whose handlers enforce their own authorization (as the builtin `server.schema` does).

The router checks `Accepts` right after the target parses, before any ACL lookup. An unaccepted target gets the same wire error as a denial, so a caller cannot tell "outside this method's targets" from "no access". `Accepts` is routing policy, not contract: never fingerprinted, never served by discovery. Entity-agnostic methods (the builtin `server.entity`, a backup verb for any subtree) keep the default.

When `Accepts` names **exactly one** concrete entity (one pattern, no wildcards, like `Accepts("journal.notes")`), a request **without an entity** targets it. The client omits `on:` (which defaults to root), or the CLI omits the `<entity>` positional. The server infers the target and runs the usual traversal and target ACL checks on it. Wider patterns, like the example's `"journal.*"`, infer nothing; such a request is denied like any unaccepted target, so omission is never ambiguous. Inference is server-side only: clients never see `Accepts`, and omitting the entity on the wrong daemon just returns a denial.

## 3. Declaring the server as a resource

`MMService { ... }` declares the server, and the value it builds *is* the server as a `BracketAsync<[SocketAddress], MMServiceError>`: the resource is the bound addresses, one per endpoint. So a daemon composes the server into the bracket it already runs, instead of adopting a new lifecycle mechanism. One builder holds configuration, authorization, logging, and handlers. Building it (before anything listens) builds the `Router` (with `registerBuiltins: true`, so `server.schema` and `server.entity` exist without user code), computes the hello fingerprint from every registered signature, and prepares metrics. The example daemon's:

```swift
import Logging
import MMExampleAPI
import MMSchema
import MMServer

let uid = getuid()
let gid = getgid()
let store = JournalStore()

let service = MMService {
    Configuration(endpoint: .unix(path: socketPath))
    ACLProvider {
        // The entity tree from §2.
    }
    Log(logger)
    // For(Namespace.self) groups the routes AND enrolls the namespace in the
    // startup cross-check: every descriptor in Journal.all needs a handler,
    // every handler under the "journal" prefix must be declared.
    For(Journal.self) {
        JournalHandlers(store: store)
    }
}
```

Required: exactly one `Configuration` (`endpoint:` for one listener, `endpoints:` for several served as one server) and exactly one `ACLProvider` (authorization has no default, on purpose). Optional: `Log` (a `Logger`, a `label:level:` pair, or a closure sink `Log { level, message in ... }`) and `Types(Container.self)` for each shared types-only container (`#schemaTypes` block) your schemas reference. Namespaces declared with `For` add their own type tables automatically. Violations fail at daemon startup, like every router precondition. This includes a duplicate type definition and a `.reference` that no registered table resolves.

Routes can go inline in the `For` block, or in a `RouteGroup`: a separately declared bundle of handlers with its own dependencies, like a custom SwiftUI view. The example keeps its handlers in `Examples/Daemon/JournalHandlers.swift`, so the daemon file stays pure wiring:

```swift
import MMExampleAPI
import MMServer

struct JournalHandlers: RouteGroup {
    let store: JournalStore

    @RouterBuilder var routes: [Route] {
        On(Journal.append, Accepts("journal.*")) { auth, request in
            // The store broadcasts the change to every follower of this
            // journal (any connection) as part of the append.
            let count = await store.append(request.line, to: auth.entity)
            return .success(AppendResponse(count: count))
        }
        On(Journal.read, Accepts("journal.*")) { auth, request in
            .success(ReadResponse(lines: await store.read(auth.entity)))
        }
        // follow, import, and sync: §5.
    }
}
```

`On` puts the authorized connection context first, then the decoded request. Handlers return `Result<Response, MMError>`; a domain failure goes to the peer verbatim as an `MMError` value with a code of 64 or more. (The example's handlers never fail.) The parameter-based `MMService(configuration:namespaces:aclProvider:logger:routes:)` initializer and the `Handle(method) { request, context in ... }` form still work. `On` and `Handle` register identical routes; `On` only puts the context first in the closure parameters, for the builder style.

The `@RouterBuilder` closure accepts `On`/`Handle` expressions, `RouteGroup` values, pre-built `[Route]` groups, `if`/`else`, and `for` loops, so routes can be registered conditionally at startup (feature flags, platform differences).

### Running it: Service, and composition

The server's acquire binds every endpoint, starts accepting on each, and returns once they all accept connections. Disposing it drains: stop accepting, let in-flight handlers finish and their responses flush, close the connections, remove the socket files. The example daemon has no other resources, so it hands the server straight to fp-swift-service:

```swift
import FPService

// The first SIGTERM (systemd/launchd stop) or SIGINT (dev Ctrl-C) drains;
// a second one cancels the drain, tearing connections down at once.
let daemon = Service(
    service,
    shutdownSignals: [SIGTERM, SIGINT],
    shutdownTimeout: .seconds(30)
)

switch await daemon() {
    case .success(let outcome):
        logger.info("example daemon stopped", metadata: ["outcome": "\(outcome)"])
    case .failure(let error):
        logger.critical("example daemon failed", metadata: ["error": "\(error)"])
        throw error
}
```

If the bind fails (for example, another instance holds the socket), the result is `.failure(.startFailed(.socketPathInUse(path:)))`. When one of several endpoints fails to bind, the ones already bound are closed and their socket files removed before the failure returns. The bound addresses the server yields, one per endpoint in declaration order, include the port of a `.tcp(host:port: 0)` endpoint. If an accept loop fails while the daemon runs, the whole server stops, and dispose reports it at shutdown, as `.stopFailed(...)`.

A daemon with more resources composes them into one bracket with `BracketAsyncDo` and hands that to `Service`. Map each resource's error into one daemon error type with `mapError`. Acquires run in order and disposes in reverse, so a resource bound after the server (a discovery announcer, a health gate, an in-process client) starts only once the socket listens, and stops before the server drains. If an acquire fails, everything acquired before it is disposed in reverse, and `Service` reports `.startFailed` with the mapped error. Any other lifecycle works the same way: call the bracket with a body, and the server is up for exactly as long as the body runs.

**Startup preconditions fail fast on purpose.** Every misregistration is a `precondition` failure at daemon boot: a crash in the first second of deployment, not a surprise at the first call. At `init`, the router checks that:

- no method name is duplicated across all routes (builtins included);
- every descriptor in each declared namespace's `all` has a registered route;
- every route under a prefix owned by a declared namespace is in that namespace's `all` list (so no route escapes the fingerprint cross-check);
- every request/response type passes the schema probe, so the fingerprint covers everything and no type fails at first decode;
- every method name's namespace prefix parses as a valid `EntityName`.

`For(Journal.self)` (or `namespaces: [Journal.self]` in the parameter form) enables the second and third checks. A namespace left out silently skips its cross-check, so declare every namespace you register routes for.

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

The example daemon runs on the defaults. A production version of it would lower the frame cap (journal lines are small; 16 MiB is generous for a schema response but far too large for `journal.append`) and set the socket mode deliberately, in the same `Configuration` element:

```swift
Configuration(
    endpoint: .unix(path: socketPath),
    maxFrameLength: 1 << 20,          // 1 MiB: largest legitimate payload, with margin
    maxConnections: 64,
    idleTimeout: .seconds(300),       // followers of a quiet journal hold a follow stream open
    unixSocketMode: 0o660             // owner + group; the group is the grant
)
```

TCP endpoints exist (`.tcp(host:port:)`; port 0 for an ephemeral port, read back from the address the server's bracket yields) but carry **no peer identity in v1**. Every TCP peer is `PeerIdentity.anonymous`, so only ACL *other*-class bits apply. Use raw TCP only on trusted networks. The documented remote path is SSH unix-socket forwarding, which keeps kernel peer credentials end to end.

## 5. Streaming from handlers

Server push is an ordinary method with a `ResponseStream`, not a side channel. In `On` form:

- A server-streaming handler takes `(auth, request, sink)`. It sends response elements through the credit-gated `MMResponseSink<Element>` and ends the call by returning its terminal `Result<Response, MMError>`.
- A client-streaming handler takes `(auth, request, elements)`. `elements` is an `MMRequestStream<Element>`, a backpressured `AsyncSequence` that ends normally at the client's graceful END.
- A bidirectional handler takes `(auth, request, elements, sink)`.

(`Handle` takes the same parameters with the context last.) Authorization runs once, at open, on the request's entity, as for a unary call.

`sink.send(_:)` is the whole outbound API. It encodes the element, spends one credit, and returns a `StreamSendOutcome`. All three cases are *graceful*, not errors:

- `.sent`: buffered toward the client under the credit window. The send may have suspended first at zero credit: a slow consumer parks the producing task, so memory stays bounded and siblings are unaffected.
- `.peerStopped`: the client sent STOP ("I have seen enough, wrap up"). The stopping element was dropped; break and return the terminal.
- `.callEnded`: the client CANCELled, the connection died, or the terminal is already out. Break promptly; the return value is discarded.

The example's `journal.follow` handler relays a follower's change events and returns the count as the terminal. A journal can be quiet for arbitrarily long, and a relay parked on a quiet source sees STOP only at its next send. So the handler also watches `sink.stopRequested()` from a structured sibling, which unfollows and ends the relay promptly:

```swift
On(Journal.follow, Accepts("journal.*")) { auth, request, sink in
    let (token, changes) = store.follow(auth.entity)
    var delivered = 0
    await withTaskGroup(of: Void.self) { watcher in
        watcher.addTask {
            await sink.stopRequested()
            store.unfollow(token, from: auth.entity)
        }
        loop: for await event in changes {
            switch await sink.send(event) {
                case .sent:
                    delivered += 1
                case .peerStopped, .callEnded:
                    break loop
            }
        }
        // Relay ended first (source finished or send reported the
        // stop): release a still-parked watcher.
        watcher.cancelAll()
    }
    store.unfollow(token, from: auth.entity)
    return .success(FollowSummary(delivered: delivered))
}
```

Unregistering is idempotent, because both edges may fire. Protect the store's follower registry with a lock, not actor isolation, and make each follower stream's `onTermination` unregister it. Termination handlers are synchronous, so an actor-isolated registry cannot clean up a dead follower without spawning a task. `Examples/Daemon/FollowerHub.swift` is the reference: it removes the registration under the lock, calls `finish()` only after releasing the lock (a termination handler re-enters the registry), and makes removal idempotent so handler and termination cleanup can race safely. That is also why `JournalStore.follow` and `unfollow` are `nonisolated` and synchronous, not `await`ed.

Client streaming is the reverse. Iterate `elements` to consume request items (consuming grants the client more credit). The end of the sequence *is* the client's graceful END:

```swift
On(Journal.import, Accepts("journal.*")) { auth, request, elements in
    var imported = 0
    for await element in elements {
        _ = await store.append(element.line, to: auth.entity)
        imported += 1
    }
    let total = await store.count(of: auth.entity)
    return .success(ImportSummary(imported: imported, total: total))
}
```

`elements.stop()` would send a server-initiated STOP (advisory: "I have all the request items I need"). The call still runs to its terminal.

A bidirectional handler does both on one call. The example's `journal.sync` appends each inbound line and echoes the resulting `ChangeEvent` back through the call's own sink:

```swift
On(Journal.sync, Accepts("journal.*")) { auth, request, elements, sink in
    var synced = 0
    loop: for await element in elements {
        let count = await store.append(element.line, to: auth.entity)
        let event = ChangeEvent(
            entity: auth.entity.rawValue,
            line: element.line,
            count: count
        )
        switch await sink.send(event) {
            case .sent:
                synced += 1
            case .peerStopped, .callEnded:
                break loop
        }
    }
    return .success(
        SyncSummary(synced: synced, total: await store.count(of: auth.entity))
    )
}
```

Design around these semantics:

- **Cross-connection fan-out is host logic.** Each `follow` call gets one correlated response stream. Delivering appends from *any* connection to every interested follower is the store's job: the example's `JournalStore.append` broadcasts through `FollowerHub`. The library provides the per-call stream, not publish/subscribe.
- **Flow control is automatic and bounded.** The window starts at 8 items per direction. A slow consumer stops the producer at zero credit instead of growing memory, and a stalled stream never blocks sibling calls (no head-of-line blocking).
- **Streaming methods *are* fingerprinted and discoverable**, unlike the removed notification mechanism. A response stream is part of the method signature (`server.schema` reports its element shape), so clients detect a reshape through the hello fingerprint and discovery, like any contract change. Element payloads still evolve append-only (new fields optional).
- **Termination is graceful by default.** END finishes a direction, STOP asks the peer to finish (`.peerStopped`), and the terminal is always the last frame. CANCEL and connection loss arrive as `.callEnded` or task cancellation. A relay over a quiet source needs the `sink.stopRequested()` watcher shown above. Full matrix: the [wire protocol specification](https://swiftpackageindex.com/velocityzen/mm/documentation/mmwire/wireprotocol) §4.2.

## 6. The client side

The example client (`Examples/Client/Client.swift`) imports the same `MMExampleAPI` module and `MMClient`.

**One connection, many calls.** A connection multiplexes: each call gets its own msgid, concurrent callers interleave freely (up to `maxInFlightCalls`), and streams share the connection with per-stream credit windows. Run the client once per *unit of work* (a daemon's lifetime, a tool run), never per call. The example runs every pattern over one connection.

**The client is a bracket, declared like the server.** `MMClient { ... }` builds a `BracketAsync<MMClientConnection, MMClientError>`: acquire connects AND starts the inbound loop; dispose closes, joins it, and returns the loop's outcome as the release verdict, so the bracket fails if the connection did not survive the scope. The example calls it with a body:

```swift
import Logging
import MMClient
import MMExampleAPI
import MMSchema

let journal = MMClient {
    Configuration(endpoint: .unix(path: socketPath))
    Schema(.complete([Journal.contract]))
    Log(logger)
}
let outcome = await journal { connection in
    await verify(connection)
    await discover(connection)
    await append(connection, to: notes)
    await follow(connection, journal: notes)
    // … importLines, sync, read, appendDenied
    // No close, no join: the bracket's dispose does both on the way out.
    return .success(())
}

if case .failure(let error) = outcome {
    print("cannot connect to \(socketPath): \(error)")
    print("start the daemon first: swift run mm-example-daemon")
    return
}
```

Each step handles its own calls' failures (shown below), so the bracket's failure means only the connection's. A daemon that talks to another daemon composes the client like the server in §3: map its error with `mapError` and bind it into the daemon's `BracketAsyncDo`.

The builder takes exactly one `Configuration(endpoint:...)` (the endpoint plus tunables such as `maxInFlightCalls` and the timeouts), at most one `Schema(...)`, and at most one `Log(...)`. `MMClient(endpoint:configuration:)` is the parameter form. Like any bracket, it runs on the caller's actor, so `@MainActor` code (the example's `main`) can call it directly. The value is not `Sendable`: build it where it runs, or hand it to `Service`, which takes it as `sending`.

Custom choreography (stream drainers in sibling tasks, staged teardown) goes *inside* the bracket body as structured children (`async let`, a local group, `withStream`). The bracket still owns the lifecycle around it.

There is no connection outside a bracket, so there is nothing to leak: no loop to forget and no close to miss. When the connection dies (EOF, transport error, protocol violation, or the bracket's dispose), pending calls fail with `MMCallError.connectionClosed` and `state` becomes `.closed(reason:)`. Dispose has no drain: a body that wants its responses awaits them before returning. v1 does not reconnect, by design: a closed connection stays closed. Retry policy is application logic, driven by `stateUpdates()`.

**Typed calls** return `Result<Response, MMCallError>`; nothing throws on the data path. The example's `append(_:to:)`:

```swift
switch await connection.call(
    Journal.append,
    on: journal,
    AppendRequest(
        line: "hello from the example client",
        meta: LineMeta(author: "example-client", priority: .urgent)
    )
) {
    case .success(let response):
        print("  ok — journal now has \(response.count) line(s)")
    case .failure(let error):
        print("  failed: \(error)")
}
```

Match specific failures where they mean something: the example's `appendDenied(_:to:)` sends the same call to the root-owned `journal.system` and matches `.failure(.denied)`. A handler's domain failure arrives as `.failure(.remote(MMError))`.

`maxInFlightCalls` (default 16, matching the server's per-connection cap) bounds calls. The excess fails at once with `.tooManyInFlight` and is never queued. Cancelling the awaiting task abandons the msgid locally: the server may still execute the request, but the response is not delivered.

**Streaming calls** return a typed handle, not a `Result`. A server-streaming `call` returns an `InboundStreamHandle<Element, Response>`: a single-iteration `AsyncSequence` of elements over `NIOAsyncSequenceProducer` (bounded buffer, real backpressure, never a bare `AsyncStream`), an awaitable `result()` terminal, and `stop()` / `cancel()` control. `withStream(_:each:_:)` packages the usual shape: `each` consumes the elements in a structured sibling (per the head-of-line rule below), the trailing closure is the main flow, and it returns only after the sequence ended, so the terminal read is ordered after every delivered element. The example's `follow(_:journal:)` consumes in `each` and produces with plain appends:

```swift
let follow = await connection.call(Journal.follow, on: journal, FollowRequest())

await withStream(
    follow,
    each: { event in
        // The consumer, stopping on its own criterion: here, once the
        // line it was waiting for arrives.
        print("  follow delivered: \"\(event.line)\" (count \(event.count))")
        if event.line == "second change" {
            await follow.stop()
        }
    }
) {
    // The producer: unary appends that know nothing about the follower.
    for line in ["first change", "second change"] {
        if case .failure(let error) = await connection.call(
            Journal.append,
            on: journal,
            AppendRequest(line: line, meta: nil)
        ) {
            print("  append failed: \(error)")
        }
    }
}
switch await follow.result() {
    case .success(let summary):
        print("follow terminal: delivered \(summary.delivered) change(s) before STOP")
    case .failure(let error):
        print("follow ended with error: \(error)")
}
```

Iterating the sequence grants credit back to the server. The initial window of 8 arrives unrequested; each further window the consumer drains sends a grant. A consumer that stops draining stops granting, so the server waits at zero credit and memory stays bounded. `stop()` sends a graceful STOP: the call still runs to its terminal, which is how `follow.result()` above reports what was delivered. `cancel()` sends CANCEL and resolves every surface `.cancelled`. Cancelling the consuming task only stops the reading (the sequence ends and grants stop); to abandon the whole call, call `cancel()` from that task's cancellation handler. An element that fails to decode is dropped with a warning and a counter increment; it never ends the sequence.

A client-streaming `call` returns the reverse, an `OutboundStreamHandle<Element, Response>`: a credit-gated `send(_:)` that returns a `StreamSendOutcome`, a one-shot `finish()` (END), and an awaitable `result()`. The example's `importLines(_:into:)`:

```swift
let importCall = await connection.call(Journal.import, on: journal, ImportRequest())
for line in ["imported line one", "imported line two", "imported line three"] {
    switch await importCall.send(ImportLine(line: line)) {
        case .sent:
            continue
        case .peerStopped:
            print("  server asked us to stop early")
        case .callEnded, .connectionClosed:
            print("  import call ended before we finished sending")
    }
}
await importCall.finish()
switch await importCall.result() {
    case .success(let summary):
        print("  import terminal: imported \(summary.imported), journal total \(summary.total)")
    case .failure(let error):
        print("  import ended with error: \(error)")
}
```

A bidirectional `call` returns a `BidirectionalStreamHandle` whose independent `.inbound` and `.outbound` halves share one terminal. Drive them concurrently: the example's `sync(_:into:)` consumes `inbound` in `withStream`'s sibling while the body sends and ENDs `outbound`:

```swift
let sync = await connection.call(Journal.sync, on: journal, SyncRequest())
await withStream(
    sync.inbound,
    each: { event in
        print("  change echoed back: \"\(event.line)\" (count \(event.count))")
    }
) {
    for line in ["synced line one", "synced line two"] {
        switch await sync.outbound.send(SyncLine(line: line)) {
            case .sent:
                continue
            case .peerStopped:
                print("  server asked us to stop early")
            case .callEnded, .connectionClosed:
                print("  sync call ended before we finished sending")
        }
    }
    await sync.outbound.finish()
}
switch await sync.inbound.result() {
    case .success(let summary):
        print("  sync terminal: synced \(summary.synced), journal total \(summary.total)")
    case .failure(let error):
        print("  sync ended with error: \(error)")
}
```

Waiting for each echo before the next send would remove the pipelining the two credit windows provide.

**Head-of-line behavior (intended):** the credit window bounds the inbound element buffer. When a slow consumer's buffer fills, the connection's inbound loop *suspends before reading more frames*, so the socket pauses the server's writes for *that stream*. Credits are per stream, so only that stream stalls; sibling calls and streams continue. Still, iterate an inbound stream from a task that does **not** also await other traffic on this connection (`withStream`'s `each` is that task), and hand elements to your own pipeline instead of doing slow work in the element handler.

**Schema verification is automatic: declare contracts, never a fingerprint.** Declare the contracts this build was compiled against with `Schema(...)`, and the connection verifies itself as soon as the bracket acquires. The example client ships with the daemon, so it declares the complete composition: `Schema(.complete([Journal.contract]))`. A client that uses a slice of a bigger server declares `.partial([Journal.contract])`. A mismatch never disconnects; the verdict is a value. The example's `verify(_:)`:

```swift
switch await connection.verify() {
    case .success(.ok):
        print("  schema: ok — the hello proves this build's exact composition")
    case .success(.partial):
        print("  schema: composition changed, but every contract we use is in sync")
    case .success(.difference(let differences)):
        print("  schema: DIFFERS — \(differences.count) namespace(s) drifted")
    case .failure(let reason):
        print("  schema: verification unavailable (\(reason))")
}
```

`.ok` means the complete expectation matched the hello: the entire composition is proven with zero discovery round-trips. `.partial` means every declared contract is served verbatim, but the composition changed somewhere this build does not use. `.difference` means the namespaces this build depends on moved: disable the dependent features and keep the rest running. `.failure` (`.noExpectation`, `.denied`, `.failed(callError)`) means no verdict; act per application policy. `verify()` resolves once and can be awaited any number of times.

For custom policy over the raw buckets, use the manual flow underneath: `connection.verifyContracts([...])` for a scoped diff, or `discoverSchema()` + `SchemaDifference(local:remote:)`, as the example's `discover(_:)` does:

```swift
switch await connection.discoverSchema() {
    case .failure(let error):
        print("discovery failed: \(error)")
    case .success(let schema):
        // schema.methods and schema.types: what THIS peer can reach.
        let difference = SchemaDifference(local: journalContract, remote: schema)
        print("schema difference vs this build: \(difference)")
}
```

Against the example daemon it prints `server only: server.entity, server.schema`: the builtins are served, but this build's contract declares only `journal`. `remote.methods` is filtered by *this peer's* traversal rights. `remote.fingerprint` is the server's unfiltered value, comparable with `connection.server.fingerprint`.

`SchemaDifference` buckets:

- `missingMethods`: absent *or invisible to this peer* (the fix may be an ACL change, not a deploy).
- `signatureChanged`: the wire contract changed under this build.
- `accessChanged`: the verb now needs a different permission class.
- `remoteOnly`: harmless; useful for upgrade planning.
- `missingTypes`, `typeChanged`, `remoteOnlyTypes`: the named-type buckets. `typeChanged` (same qualified name, different shape) counts like `signatureChanged` for features that carry the type.

Prefer `SchemaDifference(local: contract, remote:)` with a `SchemaDeclaration` so types are diffed too. Comparisons ignore descriptions (doc edits are never drift), and buckets are sorted by name for deterministic logs. The value is `CustomStringConvertible`: `"\(difference)"` renders `in sync` or the non-empty buckets (`missing: a.get; types changed: common.Priority`), so log it directly instead of iterating buckets.

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

Server and client both emit metrics through [swift-metrics](https://github.com/apple/swift-metrics), a facade like swift-log. The library only **emits**: it never opens a port, serves a `/metrics` endpoint, or bootstraps a backend. Until the host bootstraps one, every instrument uses the built-in no-op handler (near-zero cost, data discarded); the example daemon bootstraps none. Exposing the numbers is a host decision, made once before the daemon's resources start. In the example daemon, that is next to `LoggingSystem.bootstrap`:

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

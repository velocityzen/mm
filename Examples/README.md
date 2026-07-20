# Examples

A runnable pair demonstrating the full matter-in-motion story — schema definition, serving, discovery, typed calls, correlated streaming (server → client and client → server), and authorization — in one small package target per role:

- [API/JournalAPI.swift](API/JournalAPI.swift) — the shared wire contract, **written exactly once**: a single `#schema("journal") { ... }` declaration (unary `append`/`read`, the `follow` server → client stream, the `import` client → server stream, the `sync` duplex stream) from which the macro generates every request/response/element struct, the typed descriptors, the namespace list, and the runtime `journalContract`. Depends on `MMSchema` only, demonstrating the client-safe dependency direction. The contract stays load-bearing on **both** sides — the daemon re-verifies the generated types against the re-emitted declaration at boot (now a macro-fidelity check), the client verifies and diffs it against discovery.
- [Daemon/Daemon.swift](Daemon/Daemon.swift) — a complete daemon, declared as data and reduced to pure wiring: a startup contract check (`journalContract.verify(against: Journal.self)` — refuses to listen on drift), then the whole server in one builder — `MMService { Configuration(...); ACLProvider { Entity("journal", ...) { Entity("notes"); Entity("system", ...) } }; Log(...); For(Journal.self) { JournalHandlers(store:) } }`. The ACL table is the entity tree itself (children take relative paths, inherit owner/group, default to mode 0o750); `For` turns on the startup cross-check. Lifecycle in a `ServiceGroup` (SIGTERM drains gracefully, SIGINT cancels).
- [Daemon/JournalHandlers.swift](Daemon/JournalHandlers.swift) — the handlers as a reusable `RouteGroup` in its own file, carrying the store as its dependency: `On(Journal.append) { auth, request in ... }` for unary and stream shapes alike; `journal.follow` is a credit-flow-controlled server → client stream, `journal.import` a client → server stream, `journal.sync` a duplex stream echoing each appended line's change event back. Every route declares `Accepts("journal.*")` — ACL grants are per-entity-per-mode, never per-method, so the pattern keeps journal verbs on journal nouns: a target outside the subtree is denied before the ACL is even consulted.
- [Daemon/JournalStore.swift](Daemon/JournalStore.swift) — the application state in its own file: an actor holding the journals, delegating the cross-connection change fan-out (every append, from any connection, broadcasts a `ChangeEvent` to that journal's followers) to [Daemon/FollowerHub.swift](Daemon/FollowerHub.swift) — a lock-guarded registry so each follower stream's synchronous `onTermination` can unregister a dead consumer without spawning a task; both cleanup paths (handler exit and stream termination) race safely.
- [Client/Client.swift](Client/Client.swift) — a CLI client whose whole lifecycle is one `MMClientConnection.with(...)` bracket (acquire connects and starts the inbound loop; dispose closes and joins it), with every step multiplexed over that single connection and **one pattern per function**, each a self-contained recipe: `verify` (automatic schema verification), `discover` (discovery + `SchemaDifference`), `append`/`read` (unary calls), `follow` (server → client stream with a graceful STOP), `importLines` (client → server stream), `sync` (duplex — both directions streaming on one call), and `appendDenied` (a deliberate authorization denial).

- [CLI/CLI.swift](CLI/CLI.swift) — the generated command-line face: `#schema("journal", cli: .enabled)` emits every subcommand (names, help, argument shapes) from the same contract declaration; this file is just the root command mounting `Journal.Command`. The `CLI(.command("add", aliases: ["append"]))` overlay renames `journal.append` to `journal add` without touching the wire.

## Run it

Two terminals:

```sh
swift run mm-example-daemon            # terminal 1: listens on /tmp/mm-example.sock
swift run mm-example-client            # terminal 2
```

Or drive the daemon with the generated CLI instead:

```sh
swift run mm-example-cli journal add journal.notes "hello" --socket /tmp/mm-example.sock
swift run mm-example-cli journal read journal.notes --socket /tmp/mm-example.sock --output json-pretty
swift run mm-example-cli journal --help
```

`journal.notes` here is the target entity — the daemon's noun, declared in its ACL tree (Daemon.swift), not in the schema. The schema contributes the verbs (`add`, `read`, their options and help); which journals exist, and who may touch them, is runtime state. Swap in `journal.system` to watch the same verb get denied by the entity's ACL alone.

Both accept an optional socket path argument if `/tmp/mm-example.sock` does not suit. Stop the daemon with Ctrl-C (SIGINT) or `kill -TERM` for a graceful drain that removes the socket file.

## What the client prints

```
connected to /tmp/mm-example.sock
  protocol version: 1
  server schema fingerprint: 0x…

discovered 7 reachable methods:
  journal.append  (needs -w- on its target) — Appends one line to a journal
  journal.follow  (needs r-- on its target) — Streams every change to a journal until STOP
  journal.import  (needs -w- on its target) — Bulk-appends a stream of lines
  journal.read  (needs r-- on its target) — Returns every line in the journal
  journal.sync  (needs -w- on its target) — Appends a stream of lines, echoing each change back
  server.entity  (needs r-- on its target)
  server.schema  (needs r-- on its target)
named types reachable through those methods:
  journal.ChangeEvent — One appended line, as delivered to followers
  journal.LineMeta — Attribution carried with a line
  journal.Priority (enum: normal, urgent) — How urgent a line is
contract check: Codable types match the declared schema
schema difference vs this build: server only: server.entity, server.schema

append to journal.notes (unary call):
  ok — journal now has 1 line(s)

follow journal.notes (server -> client stream):
append twice to journal.notes (each drives a change to the follower):
  follow delivered: "first change" (count 2)
  follow delivered: "second change" (count 3)
follow terminal: delivered 2 change(s) before STOP

import into journal.notes (client -> server stream):
  import terminal: imported 3, journal total 6

sync into journal.notes (duplex stream: lines up, changes back):
  change echoed back: "synced line one" (count 7)
  change echoed back: "synced line two" (count 8)
  sync terminal: synced 2, journal total 8

read journal.notes: ["hello from the example client", "first change", "second change", "imported line one", "imported line two", "imported line three", "synced line one", "synced line two"]

append to journal.system (root-owned, mode 0o700):
  denied — exactly as the ACL intends

closed cleanly
```

Details worth noticing while reading the output against the sources:

- The discovered method list is filtered by _your_ traversal rights — the daemon's ACL table keys ownership to the uid it started as, which the kernel reports for your client via peer credentials. No token ever crosses the wire. The builtins (`server.schema`, `server.entity`) appear because the daemon's ACL tree declares the `server` entity with read for owner and group; drop that entry and they vanish from the listing (a missing ACL means invisible), even though `server.schema` itself would still answer the discovery call — its root-targeted request path is the documented exception. The schema difference then honestly reports the two server-only builtins: this build's local contract declares only `journal`.
- `journal.follow` is an ordinary method with a `ResponseStream`: correlated to one call, authorized once at open (a `read` on the target, exactly like `journal.read`), and credit-flow-controlled — the client's consumption of the element sequence grants credit all the way back to the socket, so a slow reader parks the server's producer rather than unbounding memory. Cross-connection fan-out — wiring every append to that journal's followers — is _application_ infrastructure (the daemon's `JournalStore.broadcast`), not library policy; the library gives each `follow` call the correlated, flow-controlled stream to build on.
- The `follow` section is two roles in two scopes, as in real life (where the follower is usually another process): a **consumer** that only listens — iterating the element sequence grants credit — and STOPs on its own criterion (once the line it was waiting for arrives), and a **producer** that only writes plain unary appends and knows nothing about any follower. STOP is graceful and advisory: the call still runs to its terminal, a `FollowSummary` of what was delivered. The daemon's handler observes the STOP promptly even on a quiet journal by watching `sink.stopRequested()` from a structured sibling of its relay loop — without it, a stopped follower of a quiet journal would hold its stream open until the next unrelated append.
- `journal.import` is the mirror: a `RequestStream`. The client sends `ImportLine` elements through the credit-gated writer, calls `finish()` to END its request direction, then awaits the `ImportSummary` terminal. Each imported line is an append, so the read-back shows the earlier lines plus the three imported ones.
- `journal.sync` is both at once: a `RequestStream` **and** a `ResponseStream` on one correlated call. The client's `outbound` half streams lines up while the `inbound` half delivers each line's `ChangeEvent` straight back, each direction with its own credit window, both sharing one `SyncSummary` terminal. The client consumes `inbound` with `withStream(_:each:_:)` — the element handler runs in a structured sibling while the body sends, the shape every duplex consumer needs, since awaiting the echo of each send in lockstep would forfeit the pipelining the two windows exist to provide.
- The denial happens before a single byte of the request payload is interpreted: the router authorizes the open envelope's entity slot first — the entity is call metadata, not payload.

## Where to go deeper

- [Wire protocol specification](../Sources/MMWire/MMWire.docc/WireProtocol.md) — the byte-level wire specification.
- [Integration guide](../Sources/MMServer/MMServer.docc/IntegrationGuide.md) — the production version of everything here: SQLite-backed ACL provider, hardening knobs, operational defaults.
- [Remote access](../Sources/MMServer/MMServer.docc/RemoteAccess.md) — running this over SSH unix-socket forwarding with peer credentials intact.

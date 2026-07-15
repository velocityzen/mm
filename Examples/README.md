# Examples

A runnable pair demonstrating the full matter-in-motion story — schema definition, serving, discovery, typed calls, correlated streaming (server → client and client → server), and authorization — in one small package target per role:

- [API/JournalAPI.swift](API/JournalAPI.swift) — the shared wire contract, **written exactly once**: a single `#schema("journal") { ... }` declaration (unary `append`/`read`, the `follow` server → client stream, the `import` client → server stream) from which the macro generates every request/response/element struct, the typed descriptors, the namespace list, and the runtime `journalContract`. Depends on `MMSchema` only, demonstrating the client-safe dependency direction. The contract stays load-bearing on **both** sides — the daemon re-verifies the generated types against the re-emitted declaration at boot (now a macro-fidelity check), the client verifies and diffs it against discovery.
- [Daemon/Daemon.swift](Daemon/Daemon.swift) — a complete daemon, declared as data and reduced to pure wiring: a startup contract check (`journalContract.verify(against: Journal.self)` — refuses to listen on drift), then the whole server in one builder — `MMService { Configuration(...); ACLProvider { Entity("journal", ...) { Entity("notes"); Entity("system", ...) } }; Log(...); For(Journal.self) { JournalHandlers(store:) } }`. The ACL table is the entity tree itself (children take relative paths, inherit owner/group, default to mode 0o750); `For` turns on the startup cross-check. Lifecycle in a `ServiceGroup` (SIGTERM drains gracefully, SIGINT cancels).
- [Daemon/JournalHandlers.swift](Daemon/JournalHandlers.swift) — the handlers as a reusable `RouteGroup` in its own file, carrying the store as its dependency: `On(Journal.append) { auth, request in ... }` for unary and stream shapes alike; `journal.follow` is a credit-flow-controlled server → client stream, `journal.import` a client → server stream.
- [Daemon/JournalStore.swift](Daemon/JournalStore.swift) — the application state in its own file: an actor holding the journals, delegating the cross-connection change fan-out (every append, from any connection, broadcasts a `ChangeEvent` to that journal's followers) to [Daemon/FollowerHub.swift](Daemon/FollowerHub.swift) — a lock-guarded registry so each follower stream's synchronous `onTermination` can unregister a dead consumer without spawning a task; both cleanup paths (handler exit and stream termination) race safely.
- [Client/Client.swift](Client/Client.swift) — a CLI client: hello negotiation, schema discovery + `SchemaDifference`, a `journal.follow` server → client stream with a graceful STOP, typed append/read, a `journal.import` client → server stream, and a deliberate authorization denial.

## Run it

Two terminals:

```sh
swift run mm-example-daemon            # terminal 1: listens on /tmp/mm-example.sock
swift run mm-example-client            # terminal 2
```

Both accept an optional socket path argument if `/tmp/mm-example.sock` does not suit. Stop the daemon with Ctrl-C (SIGINT) or `kill -TERM` for a graceful drain that removes the socket file.

## What the client prints

```
connected to /tmp/mm-example.sock
  protocol version: 1
  server schema fingerprint: 0x…

discovered 4 reachable methods:
  journal.append  (needs -w- on its target) — Appends one line to a journal
  journal.follow  (needs r-- on its target) — Streams every change to a journal until STOP
  journal.import  (needs -w- on its target) — Bulk-appends a stream of lines
  journal.read  (needs r-- on its target) — Returns every line in the journal
named types reachable through those methods:
  journal.ChangeEvent — One appended line, as delivered to followers
  journal.LineMeta — Attribution carried with a line
  journal.Priority (enum: normal, urgent) — How urgent a line is
contract check: Codable types match the declared schema
schema difference vs this build: in sync

follow journal.notes (server -> client stream):
append to journal.notes (drives a change into the follow stream):
  ok — journal now has 1 line(s)
  follow delivered a change: journal.notes -> "hello from the example client" (count 1)

import into journal.notes (client -> server stream):
  import terminal: imported 3, journal total 4
follow terminal: delivered 1 change(s) before STOP

read journal.notes: ["hello from the example client", "imported line one", "imported line two", "imported line three"]

append to journal.system (root-owned, mode 0o700):
  denied — exactly as the ACL intends

closed cleanly
```

Details worth noticing while reading the output against the sources:

- The discovered method list is filtered by *your* traversal rights — the daemon's ACL table keys ownership to the uid it started as, which the kernel reports for your client via peer credentials. No token ever crosses the wire. Only the `journal.*` methods appear: the builtins' prefix entities (`rpc`, `entity`) have no ACL record in the example's table, and a missing ACL means invisible — even though `rpc.schema` itself clearly answered the discovery call (its root-targeted request path is the documented exception).
- `journal.follow` is an ordinary method with a `ResponseStream`: correlated to one call, authorized once at open (a `read` on the target, exactly like `journal.read`), and credit-flow-controlled — the client's consumption of the element sequence grants credit all the way back to the socket, so a slow reader parks the server's producer rather than unbounding memory. Cross-connection fan-out — wiring every append to that journal's followers — is *application* infrastructure (the daemon's `JournalStore.broadcast`), not library policy; the library gives each `follow` call the correlated, flow-controlled stream to build on.
- The `follow` STOP is graceful and advisory: the client calls `follow.stop()` after seeing the first change to ask the server to finish its response stream, but the call still runs to its terminal — a `FollowSummary` reporting how many changes were delivered before the STOP. Because frames are ordered on the connection, the STOP is processed before the `import` below, so the three imported appends find the follower already stopped and are not delivered; the terminal reports the one change delivered before STOP.
- `journal.import` is the mirror: a `RequestStream`. The client sends `ImportLine` elements through the credit-gated writer, calls `finish()` to END its request direction, then awaits the `ImportSummary` terminal. Each imported line is an append, so the read-back shows the original line plus the three imported ones.
- The denial happens before a single byte of the request payload is interpreted: the router authorizes the open envelope's entity slot first — the entity is call metadata, not payload.

## Where to go deeper

- [Wire protocol specification](../Sources/MMWire/MMWire.docc/WireProtocol.md) — the byte-level wire specification.
- [Integration guide](../Sources/MMServer/MMServer.docc/IntegrationGuide.md) — the production version of everything here: SQLite-backed ACL provider, hardening knobs, operational defaults.
- [Remote access](../Sources/MMServer/MMServer.docc/RemoteAccess.md) — running this over SSH unix-socket forwarding with peer credentials intact.

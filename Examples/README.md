# Examples

Runnable examples of matter-in-motion: schema definition, serving, discovery, typed calls, correlated streaming (server → client and client → server), and authorization. Each role is one small package target:

- [API/JournalAPI.swift](API/JournalAPI.swift): the shared wire contract, **written exactly once**. One `#schema("journal") { ... }` declaration defines unary `append`/`read`, the `follow` server → client stream, the `import` client → server stream, and the `sync` duplex stream. The macro generates every request, response, and element struct, the typed descriptors, the namespace list, and the runtime `journalContract`. It depends only on `MMSchema`, so clients can use it. **Both** sides check it. The daemon verifies the generated types against the re-emitted declaration at boot (a macro output check). The client verifies it and diffs it against discovery.
- [Daemon/Daemon.swift](Daemon/Daemon.swift): a complete daemon, only wiring. At startup, `journalContract.verify(against: Journal.self)` stops the daemon from listening if the types drifted. One builder declares the whole server: `MMService { Configuration(...); ACLProvider { Entity("journal", ...) { Entity("notes"); Entity("system", ...) } }; Log(...); For(Journal.self) { JournalHandlers(store:) } }`. The entity tree is the ACL table. Children use relative paths, inherit owner and group, and default to mode 0o750. `For` turns on the startup cross-check. A `ServiceGroup` runs the lifecycle: SIGTERM drains gracefully, SIGINT cancels.
- [Daemon/JournalHandlers.swift](Daemon/JournalHandlers.swift): a reusable `RouteGroup` that holds the store. All routes use `On(Journal.append) { auth, request in ... }`. `journal.follow` is a credit-flow-controlled server → client stream. `journal.import` is a client → server stream. `journal.sync` is a duplex stream that returns the change event of each appended line. ACL grants are per entity and mode, never per method, so every route declares `Accepts("journal.*")`. A target outside the subtree is denied before the ACL check.
- [Daemon/JournalStore.swift](Daemon/JournalStore.swift): an actor that holds the journals. Every append, from any connection, sends a `ChangeEvent` to that journal's followers through [Daemon/FollowerHub.swift](Daemon/FollowerHub.swift), a lock-guarded registry. A stream's synchronous `onTermination` unregisters a dead follower without spawning a task. Both cleanup paths (handler exit and stream termination) can run at the same time safely.
- [Client/Client.swift](Client/Client.swift): a client whose lifecycle is one `MMClientConnection.with(...)` bracket. Acquire connects and starts the inbound loop. Dispose closes and waits for the loop. All steps share the connection, with **one pattern per function**:
  - `verify`: automatic schema verification.
  - `discover`: discovery and `SchemaDifference`.
  - `append`/`read`: unary calls.
  - `follow`: server → client stream with a graceful STOP.
  - `importLines`: client → server stream.
  - `sync`: duplex stream, both directions on one call.
  - `appendDenied`: a deliberate authorization denial.

- [CLI/CLI.swift](CLI/CLI.swift): the generated command-line tool. For the schema's `CLI(.enabled)` entry, the `MMCLIGeneratorPlugin` (applied to this target only) generates every subcommand, with names, help, and argument shapes. The tool is one declaration, `MMCLI { Name(...); Abstract(...); Commands([...]); Contract(...); Endpoint(...); Format(...) }`, like the daemon's `MMService { ... }`. `Name`/`Abstract`/`Commands` define the root command. For fields they do not cover, add a full `Configuration(...)`; the parts merge onto it. The contract claim verifies every invocation from the hello fingerprint. `Endpoint` makes `--socket` optional. `Format` entries control `--output text`. The `CLI(.command("add", aliases: ["append"]))` overlay renames `journal.append` to `journal add` without changing the wire method.

## Run it

Use two terminals:

```sh
swift run mm-example-daemon            # terminal 1: listens on /tmp/mm-example.sock
swift run mm-example-client            # terminal 2
```

Or call the daemon with the generated CLI:

```sh
swift run mm-example-cli journal add "hello" journal.notes   # Endpoint(...) supplies the socket
swift run mm-example-cli journal read journal.notes --output text
swift run mm-example-cli journal --help
```

`journal.notes` is the target entity. The daemon declares entities in its ACL tree (Daemon.swift), not the schema. The schema provides the verbs (`add`, `read`, options, help). Which journals exist, and who may access them, is runtime state. With `journal.system`, the entity's ACL alone denies the same command.

The daemon and the client accept an optional socket path to replace `/tmp/mm-example.sock`. Stop the daemon with Ctrl-C (SIGINT), or with `kill -TERM` for a graceful drain that removes the socket file.

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

Compare the output with the sources:

- Discovery lists only methods _you_ can traverse. The ACL gives ownership to the daemon's uid, and the kernel reports your uid through peer credentials. No token crosses the wire. The builtins (`server.schema`, `server.entity`) appear because the ACL tree gives the `server` entity read for owner and group. Without that entry they disappear (no ACL means invisible). `server.schema` still answers discovery, because its root-targeted request path is the documented exception. The schema difference lists both builtins as server-only, because this build's contract declares only `journal`.
- `journal.follow` is an ordinary method with a `ResponseStream`, correlated to one call. The router authorizes it once at open (a `read` on the target, like `journal.read`). Consuming elements grants credit back to the socket, so a slow reader pauses the server's producer and memory stays bounded. Fan-out to followers across connections is _application_ code (`JournalStore.broadcast`), not library policy. The library provides the correlated, flow-controlled stream.
- The `follow` section has two roles in two scopes (in real use, the follower is usually another process). The **consumer** only listens and sends STOP when the line it waits for arrives. The **producer** only sends unary appends and knows nothing about followers. STOP is graceful and advisory: the call still ends with its terminal, a `FollowSummary` of what was delivered. The handler watches `sink.stopRequested()` in a structured sibling of its relay loop, so it sees STOP quickly even on a quiet journal. Otherwise the stream stays open until the next unrelated append.
- `journal.import` is the reverse: a `RequestStream`. The client sends `ImportLine` elements through the credit-gated writer, calls `finish()` to END its direction, and waits for the `ImportSummary` terminal. Each imported line is an append, so the read-back shows all three.
- `journal.sync` is a `RequestStream` **and** a `ResponseStream` on one correlated call. The `outbound` half sends lines. The `inbound` half returns each line's `ChangeEvent`. Each direction has its own credit window, and both share one `SyncSummary` terminal. The client reads `inbound` with `withStream(_:each:_:)`: the element handler runs in a structured sibling while the body sends. Every duplex consumer needs this shape: waiting for each echo before the next send removes the pipelining the two windows provide.
- The denial happens before any request payload is read. The router authorizes the open envelope's entity slot first: the entity is call metadata, not payload.

## Where to go deeper

- [Wire protocol specification](../Sources/MMWire/MMWire.docc/WireProtocol.md): the byte-level wire specification.
- [Integration guide](../Sources/MMServer/MMServer.docc/IntegrationGuide.md): the production version: SQLite-backed ACL provider, hardening options, operational defaults.
- [Remote access](../Sources/MMServer/MMServer.docc/RemoteAccess.md): running this over SSH Unix-socket forwarding with peer credentials intact.

# ``MMClient``

The typed client: unary and streaming calls with msgid multiplexing, credit-based flow control, and schema discovery.

## Overview

The simplest way to connect is the bracket, ``MMClientConnection/with(_:configuration:eventLoopGroup:logger:_:)``. One scope handles connect, the inbound loop, your body, close, and the join:

```swift
let reply = await MMClientConnection.with(.unix(path: socketPath)) { connection in
    await connection.call(Journal.append, on: notes, request)
}
```

`with` is a shorthand for ``MMClientConnection/open(_:configuration:eventLoopGroup:logger:)``, which returns the **live** connection as an FPBracket resource:

- Acquire connects and starts the inbound loop.
- Dispose closes the connection, joins the loop, and returns the loop's outcome as the release verdict.

It composes with other bracketed resources through `flatMap`/`BracketAsyncDo`.

The bracket returns `.failure` if connect failed **or** the connection did not survive the scope (a transport error or protocol violation while the body ran). A clean EOF or the bracket's own close releases successfully. Per-call failures stay in the body's return value.

One connection multiplexes many calls. Calls are matched by msgid, and ``MMClientConfiguration/maxInFlightCalls`` limits how many run at once. Open one connection per unit of work, not per call.

Put custom coordination, such as stream drainers or staged teardown, *inside* the bracket body as structured child tasks (`async let`, a local group). The bracket still owns the lifecycle around it.

Daemons connect manually instead:

- ``MMClientConnection/connect(to:configuration:eventLoopGroup:logger:)`` sets up the transport and exchanges hellos. Version negotiation picks the lower version. A fingerprint mismatch never disconnects: ``ServerInfo`` reports it, and it should trigger discovery.
- `MMClientService` runs the inbound loop under a `ServiceGroup`. It is a separate product, so plain clients and CLIs do not link swift-service-lifecycle.

```swift
let connection = try await MMClientConnection.connect(
    to: .unix(path: "/var/run/echo/rpc.sock")).get()
let group = ServiceGroup(configuration: .init(
    services: [.init(service: MMClientService(connection: connection))],
    gracefulShutdownSignals: [.sigterm],
    logger: logger
))
try await group.run()
```

`call(_:on:_:)` has overloads for all four method shapes. The open envelope carries the `on:` entity. The default is root, which means an entity-less call. This is valid only for a route whose server-side `Accepts` names exactly one concrete entity; the server infers and authorizes the target. Any other route answers `.denied`.

Unary calls return `Result<Response, MMCallError>` directly. Streaming calls return handles:

- ``InboundStreamHandle`` for server streams: an `AsyncSequence` of elements (iterating grants credit), plus `result()`, `stop()`, and `cancel()`.
- ``OutboundStreamHandle`` for client streams: credit-gated `send(_:)`, one-shot `finish()`, and `result()`.
- ``BidirectionalStreamHandle``: independent `inbound`/`outbound` halves that share one terminal.

``StreamSendOutcome`` reports `.peerStopped`, `.callEnded`, and `.connectionClosed` as typed, graceful outcomes, not errors.

To consume a stream while the same task makes other calls, use ``withStream(_:each:_:)``. It runs `each` in a structured sibling task, which enforces the head-of-line rule. It returns only after the body finishes and the sequence ends, so it joins both for you.

``MMClientConnection/discoverSchema(scope:)`` fetches the server's contract through the builtin `server.schema`, filtered by your traversal rights. ``SchemaDifference`` compares it with the locally compiled declaration: signatures and named types, without descriptions. Use the result to decide how to degrade gracefully.

The connection lifecycle is intentionally simple. ``ClientState`` is `.connected`, then `.closed(reason:)`; observe it with `stateUpdates()`. There is no reconnection: a closed connection stays closed. Retry policy belongs to the application.

## Topics

### Connection

- ``MMClientConnection``
- ``MMClientConfiguration``
- ``ServerInfo``
- ``ClientState``

### Streaming handles

- ``InboundStreamHandle``
- ``OutboundStreamHandle``
- ``BidirectionalStreamHandle``
- ``StreamSendOutcome``

### Discovery and schema verification

- ``SchemaDifference``

### Errors

- ``MMClientError``
- ``MMCallError``

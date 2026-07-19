# ``MMClient``

The typed client: unary and streaming calls with msgid multiplexing, credit-based flow control, and schema discovery.

## Overview

The simple shape is the bracket, ``MMClientConnection/with(_:configuration:eventLoopGroup:logger:_:)`` — one scope owns connect, the inbound loop, your body, close, and the join:

```swift
let reply = await MMClientConnection.with(.unix(path: socketPath)) { connection in
    await connection.call(Journal.append, on: notes, request)
}
```

`with` is sugar over ``MMClientConnection/open(_:configuration:eventLoopGroup:logger:)`` — the **live** connection as an FPBracket resource (acquire connects and starts the inbound loop; dispose closes and joins it, returning the loop's outcome as the release verdict), composable with other bracketed resources via `flatMap`/`BracketAsyncDo`. The bracket's `.failure` therefore means connect failed **or** the connection did not survive the scope — a transport error or protocol violation while the body ran; a clean EOF or the bracket's own close releases successfully, leaving per-call failures in the body's value. One connection multiplexes many calls (msgid-correlated, bounded by ``MMClientConfiguration/maxInFlightCalls``): open one per unit of work, not per call.

Custom choreography — stream drainers, staged teardown — lives *inside* the bracket body as structured children (`async let`, a local group); the bracket still owns the lifecycle around it.

Daemons connect manually instead: ``MMClientConnection/connect(to:configuration:eventLoopGroup:logger:)`` bootstraps the transport and exchanges hellos (version negotiation is min-wins; a fingerprint mismatch is a ``ServerInfo`` verdict that should trigger discovery, never a disconnect), and ``MMClientConnectionService`` runs the inbound loop under a swift-service-lifecycle `ServiceGroup`:

```swift
let connection = try await MMClientConnection.connect(
    to: .unix(path: "/var/run/echo/rpc.sock")).get()
let group = ServiceGroup(configuration: .init(
    services: [.init(service: MMClientConnectionService(connection: connection))],
    gracefulShutdownSignals: [.sigterm],
    logger: logger
))
try await group.run()
```

`call(_:on:_:)` is overloaded for all four method shapes; the `on:` entity rides the open envelope. Unary calls return `Result<Response, MMCallError>` directly. Streaming calls return handles: ``InboundStreamHandle`` for server streams (an `AsyncSequence` of elements — iterating grants credit — plus `result()`, `stop()`, and `cancel()`), ``OutboundStreamHandle`` for client streams (credit-gated `send(_:)`, one-shot `finish()`, `result()`), and ``BidirectionalStreamHandle`` with independent `inbound`/`outbound` halves sharing one terminal. ``StreamSendOutcome`` surfaces `.peerStopped`, `.callEnded`, and `.connectionClosed` as typed, graceful outcomes rather than errors. To consume a stream while the same task drives other calls, ``withStream(_:each:_:)`` runs `each` in a structured sibling (the head-of-line rule as an API shape) and returns only after both the body finished and the sequence ended — the join is built in.

``MMClientConnection/discoverSchema(scope:)`` fetches the server's contract through the builtin `server.schema` (filtered by your traversal rights), and ``SchemaDifference`` diffs it against the locally compiled declaration — signatures and named types both, descriptions stripped — as the decision input for graceful degradation.

Connection lifecycle is deliberately simple: ``ClientState`` is `.connected` then `.closed(reason:)`, observed via `stateUpdates()`. Reconnection is out of scope by design — a closed connection stays closed, and retry policy belongs to the application.

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

### Lifecycle integration

- ``MMClientConnectionService``

### Errors

- ``MMClientError``
- ``MMCallError``

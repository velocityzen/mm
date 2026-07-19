# ``MMClient``

The typed client: unary and streaming calls with msgid multiplexing, credit-based flow control, and schema discovery.

## Overview

``MMClientConnection/connect(to:configuration:eventLoopGroup:logger:)`` bootstraps the transport and exchanges hellos (version negotiation is min-wins; a fingerprint mismatch is a ``ServerInfo`` verdict that should trigger discovery, never a disconnect). The host then runs the inbound loop as a structured child — either `run()` in its own task group, or ``MMClientConnectionService`` dropped into a swift-service-lifecycle `ServiceGroup`:

```swift
let connection = try await MMClientConnection.connect(
    to: .unix(path: "/tmp/echo.sock")).get()
await withTaskGroup(of: Void.self) { tasks in
    tasks.addTask { _ = await connection.run() }

    let main = try! EntityName.parse("echo.main").get()
    let reply = await connection.call(
        Echo.run, on: main, Echo.RunRequest(value: 42))
    // reply: Result<Echo.RunResponse, MMCallError>

    await connection.close()
}
```

`call(_:on:_:)` is overloaded for all four method shapes; the `on:` entity rides the open envelope. Unary calls return `Result<Response, MMCallError>` directly. Streaming calls return handles: ``InboundStreamHandle`` for server streams (an `AsyncSequence` of elements — iterating grants credit — plus `result()`, `stop()`, and `cancel()`), ``OutboundStreamHandle`` for client streams (credit-gated `send(_:)`, one-shot `finish()`, `result()`), and ``BidirectionalStreamHandle`` with independent `inbound`/`outbound` halves sharing one terminal. ``StreamSendOutcome`` surfaces `.peerStopped`, `.callEnded`, and `.connectionClosed` as typed, graceful outcomes rather than errors.

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

# ``MMClient``

The typed client: unary and streaming calls with msgid multiplexing, credit-based flow control, and schema discovery.

## Overview

``MMClient`` is the client as an FPBracket resource, declared with a builder the same way the server's `MMService` is:

```swift
let journal = MMClient {
    Configuration(endpoint: .unix(path: socketPath))
    Schema(.complete([Journal.contract]))
}

let outcome = await journal { connection in
    if case .failure(let error) = await connection.call(Journal.append, on: notes, request) {
        logger.warning("journal.append failed: \(error)")  // the connection is still up
    }
    return .success(())
}
```

- Acquire connects and starts the inbound loop.
- The body makes the calls on the live ``MMClientConnection``.
- Dispose closes the connection, joins the loop, and returns the loop's outcome as the release verdict.

There is no connection outside the bracket, so there is nothing to leak. ``ClientPart`` lists the builder elements: exactly one `Configuration` (the endpoint and tunables), and at most one `Schema` and `Log`. ``MMClient`` also has a parameter initializer taking an endpoint and an ``MMClientConfiguration``.

The bracket returns `.failure` if connect failed **or** the connection did not survive the scope (a transport error or protocol violation while the body ran). A clean EOF or the bracket's own close releases successfully. A call's own failure (``MMCallError``) leaves the connection up, so handle it in the body, where the call was made, and the bracket's failure means only the connection.

One connection multiplexes many calls. Calls are matched by msgid, and ``MMClientConfiguration/maxInFlightCalls`` limits how many run at once. Run the bracket once per unit of work, not per call.

Put custom coordination, such as stream drainers or staged teardown, *inside* the bracket body as structured child tasks (`async let`, a local group). The bracket still owns the lifecycle around it.

Daemons compose the client with their other resources, and run the result with their lifecycle (fp-swift-service, for example):

```swift
let withDaemon = BracketAsyncDo<DaemonError>()
    .bind { withStore().mapError(DaemonError.store) }
    .bind { _ in journal.mapError(DaemonError.client) }
let result = await Service(withDaemon, shutdownSignals: [SIGTERM, SIGINT])()
```

The bracket runs on the caller's actor (fp-swift-bracket 2), and so do the connection's calls and stream handles (the module builds with `NonisolatedNonsendingByDefault`), so `@MainActor` code can use them directly. Only `withStream`'s `each` runs in a task of its own (`@concurrent`). It is not `Sendable`: build it where it runs, or hand it to `Service`, which takes it as `sending`.

Acquire sends the client hello and requires the server's hello as the first frame. Version negotiation picks the lower version. A fingerprint mismatch never disconnects: ``ServerInfo`` reports it, and it should trigger discovery.

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

- ``MMClient``
- ``ClientPart``
- ``ClientBuilder``
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

# ``MMServer``

The server: router, authorization, peer-credential capture, streaming handlers, and `MMService`, the server as a bracket.

## Overview

You declare a whole daemon as data, then run it as a resource:

```swift
let server = MMService {
    Configuration(endpoint: .unix(path: "/tmp/echo.sock"))
    ACLProvider {
        Entity("echo", owner: getuid(), group: getgid(), mode: 0o700) {
            Entity("main")
        }
    }
    For(Echo.self) {
        On(Echo.run) { auth, request in
            .success(Echo.RunResponse(value: request.value))
        }
    }
}

// BracketAsync<[SocketAddress], MMServiceError>: acquire binds and starts
// accepting, dispose drains and joins. Compose it with your own resources,
// run it with your lifecycle (here fp-swift-service, SIGTERM/SIGINT to drain).
let withService = Service(server, shutdownSignals: [SIGTERM, SIGINT])
let result = await withService()
```

``MMService`` binds its endpoints (Unix domain sockets, TCP, or both at once), exchanges hellos, and dispatches through the ``Router`` in a fixed order:

1. Route lookup.
2. Parse the open envelope's entity slot.
3. Traversal `x` on every ancestor.
4. Target ACL check.
5. Params decode and handler call.

No payload bytes are read before authorization passes. Handlers receive an ``MMContext`` whose `entity` is the call's already-authorized envelope target.

Register handlers with `On` in the service builder, or `Handle` on a bare ``Router``, for all four method shapes. Streaming handlers get a credit-gated ``MMResponseSink`` to send elements, an ``MMRequestStream`` of inbound elements, or both. ``StreamSendOutcome`` reports `.peerStopped` and `.callEnded` as typed, graceful outcomes, not errors. `For(_:_:)` adds a startup check for a namespace: if a declared method has no handler, the daemon does not start.

Authorization decisions come from an ``EntityACLProvider``, the host's dynamic source of rules. Its requirements, like every handler, are `@concurrent`: they run in connection tasks, off any actor. For static rules, use ``InMemoryACLProvider`` or the declarative `ACLProvider { Entity(...) { ... } }` tree. On Unix sockets, peer identity comes from kernel credentials. If the server cannot read them, it closes the connection without dispatch. A missing ACL is a denial that does not reveal whether the entity exists.

``MMService`` is the server as a bracket. Its acquire returns once every endpoint is bound and listening, so startup ordering is bracket composition: a resource composed after it (`flatMap`, `BracketAsyncDo`) starts only once the server accepts connections, and stops before the server drains. The resource it yields is the bound addresses, one per endpoint. Every server automatically registers the builtins `server.schema` and `server.entity`. The client is declared the same way, as an `MMClient` bracket.

The <doc:IntegrationGuide> shows how to embed all of this in a production daemon, including a SQLite-backed ACL provider and hardening settings. <doc:RemoteAccess> covers SSH socket forwarding, systemd and launchd recipes, and TCP caveats.

## Topics

### Guides

- <doc:IntegrationGuide>
- <doc:RemoteAccess>

### The service

- ``MMService``
- ``MMServerConfiguration``
- ``MMEndpoint``
- ``MMServiceError``

### Declarative service builder

- ``ServerBuilder``
- ``ServerPart``
- ``Configuration(_:)``
- ``ACLProvider(_:)-(EntityACLProvider)``
- ``ACLProvider(_:)-(()->[ACLEntry])``
- ``Log(_:)-(Logger)``
- ``Log(label:level:)``
- ``Log(_:)-((Logger.Level,Logger.Message)->Void)``
- ``For(_:_:)``
- ``Types(_:)``

### Routing and handlers

- ``Router``
- ``Route``
- ``Accepts``
- ``RouterBuilder``
- ``RouteGroup``
- ``Handle(_:_:_:)-(Method<Request,Response>,_,_)``
- ``Handle(_:_:_:)-(ServerStreamMethod<Request,Element,Response>,_,_)``
- ``Handle(_:_:_:)-(ClientStreamMethod<Request,Element,Response>,_,_)``
- ``Handle(_:_:_:)-(BidirectionalStreamMethod<Request,RequestElement,ResponseElement,Response>,_,_)``
- ``On(_:_:_:)-(Method<Request,Response>,_,_)``
- ``On(_:_:_:)-(ServerStreamMethod<Request,Element,Response>,_,_)``
- ``On(_:_:_:)-(ClientStreamMethod<Request,Element,Response>,_,_)``
- ``On(_:_:_:)-(BidirectionalStreamMethod<Request,RequestElement,ResponseElement,Response>,_,_)``
- ``MMContext``

### Streaming

- ``MMRequestStream``
- ``MMResponseSink``
- ``StreamSendOutcome``

### Authorization

- ``EntityACLProvider``
- ``InMemoryACLProvider``
- ``ACLProviderError``
- ``ACLEntry``
- ``ACLBuilder``
- ``Entity(_:owner:group:mode:_:)``

### Logging

- ``MMLogContext``

### Errors

- ``ServerError``

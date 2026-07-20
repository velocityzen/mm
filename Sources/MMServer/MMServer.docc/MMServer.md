# ``MMServer``

The server: router, authorization, peer-credential capture, streaming handlers, and the `MMService` bootstrap.

## Overview

A whole daemon is declared as data and run inside a swift-service-lifecycle `ServiceGroup`:

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
```

``MMService`` binds the endpoint (Unix domain socket or TCP), exchanges hellos, and dispatches through the ``Router``. Dispatch order is fixed: route lookup, parse the open envelope's entity slot, traversal `x` on every ancestor, target ACL check, and only then params decode and handler invocation — zero payload bytes are interpreted before authorization passes. Handlers receive an ``MMContext`` whose `entity` is the call's already-authorized envelope target.

Handlers are registered with `On` inside the service builder (or `Handle` on a bare ``Router``) in all four method shapes. Streaming handlers get a credit-gated ``MMResponseSink`` to push elements and/or an ``MMRequestStream`` of inbound elements; ``StreamSendOutcome`` reports `.peerStopped` and `.callEnded` as typed, graceful outcomes. `For(_:_:)` enrolls a namespace's startup cross-check: every declared method needs a handler, or the daemon refuses to boot.

Authorization is asked of an ``EntityACLProvider`` — the host's dynamic authority, with ``InMemoryACLProvider`` and the declarative `ACLProvider { Entity(...) { ... } }` tree as the static form. Peer identity comes from kernel credentials on Unix sockets; a capture failure closes the connection with no dispatch, and a missing ACL is a denial that never leaks existence.

Startup ordering on top of ServiceLifecycle (which has none) uses ``ServiceReadiness``, ``GatedService``, and the `Ready(_:)` builder part firing at bind. Every server auto-registers the builtins `server.schema` and `server.entity`.

The <doc:IntegrationGuide> walks through embedding all of this in a production daemon (including a SQLite-backed ACL provider and hardening knobs); <doc:RemoteAccess> covers SSH socket forwarding, systemd/launchd recipes, and TCP caveats.

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
- ``OnBind(_:)``
- ``Ready(_:)``
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

### Lifecycle and readiness

- ``ServiceReadiness``
- ``GatedService``

### Logging

- ``MMLogContext``

### Errors

- ``ServerError``

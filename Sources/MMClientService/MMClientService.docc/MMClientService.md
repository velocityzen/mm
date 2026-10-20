# ``MMClientService``

The swift-service-lifecycle adapter for `MMClientConnection`: run a daemon-style client's inbound loop as a managed service in a `ServiceGroup`.

## Overview

This adapter lives in its own product so plain clients and schema-generated CLIs depend on `MMClient` alone and never link swift-service-lifecycle or the swift-async-algorithms it pulls in. Tools and tests use the bracket, `MMClientConnection.with`. Long-lived daemons connect manually and hand the connection to ``MMClientService/MMClientService``:

```swift
import MMClient
import MMClientService
import ServiceLifecycle

let connection = try await MMClientConnection.connect(
    to: .unix(path: "/var/run/echo/rpc.sock")).get()
let group = ServiceGroup(configuration: .init(
    services: [.init(service: MMClientService(connection: connection))],
    gracefulShutdownSignals: [.sigterm],
    logger: logger
))
try await group.run()
```

## Topics

### Lifecycle integration

- ``MMClientService/MMClientService``

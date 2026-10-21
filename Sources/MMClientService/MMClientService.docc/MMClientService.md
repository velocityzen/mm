# ``MMClientService``

The swift-service-lifecycle adapter for `MMClientConnection`. It runs the inbound loop of a daemon-style client as a managed service in a `ServiceGroup`.

## Overview

This adapter is a separate product. Plain clients and schema-generated CLIs depend only on `MMClient`. They never link swift-service-lifecycle or swift-async-algorithms, which swift-service-lifecycle depends on. Tools and tests use the bracket, `MMClientConnection.with`. Long-lived daemons connect manually and pass the connection to ``MMClientService/MMClientService``:

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

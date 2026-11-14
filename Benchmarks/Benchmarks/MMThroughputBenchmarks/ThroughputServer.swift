import Benchmark
import Logging
import MMSchema
import MMServer
import MMWire

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Runs `body` while an MMService serves every throughput call on the Unix
/// socket at `path`. The benchmark's own user owns the one entity the calls
/// target, so every call passes authorization the way a daemon's owner does.
func withThroughputServer<T>(
    at path: String,
    _ body: () async -> Result<T, ThroughputFailure>
) async -> Result<T, ThroughputFailure> {
    var logger = Logger(label: "mm.throughput.server")
    logger.logLevel = .warning
    let entity = try! EntityName.parse(throughputEntity).get()
    let server = MMService(
        configuration: MMServerConfiguration(endpoint: .unix(path: path)),
        namespaces: [Throughput.self],
        aclProvider: InMemoryACLProvider([
            entity: EntityACL(owner: getuid(), group: getgid(), mode: 0o700)
        ]),
        logger: logger
    ) {
        throughputRoutes(Throughput.Scalar.self)
        throughputRoutes(Throughput.Record.self)
        throughputRoutes(Throughput.Listing.self)
    }
    let withServer = server.mapError { ThroughputFailure.server("\($0)") }
    return await withServer { _ in await body() }
}

/// `Payload`'s three calls: `echo` answers with its request, `send` counts
/// the elements it receives, and `receive` sends as many as asked.
private func throughputRoutes<Payload: ThroughputPayload>(_ payload: Payload.Type) -> [Route] {
    [
        Handle(Payload.echo) { request, _ in .success(request) },
        Handle(Payload.send) { _, elements, _ in
            var received = 0
            for await element in elements {
                blackHole(element)
                received += 1
            }
            return .success(Throughput.Count(count: received))
        },
        Handle(Payload.receive) { request, sink, _ in
            let sample = Payload.sample
            var sent = 0
            for _ in 0..<request.count {
                guard case .sent = await sink.send(sample) else { break }
                sent += 1
            }
            return .success(Throughput.Count(count: sent))
        },
    ]
}

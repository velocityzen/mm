import Benchmark
import Logging
import MMClient
import MMSchema
import MMWire

/// `Payload`'s messages end to end: an MMClient and an MMService on one Unix
/// socket, through the public API. Each run connects a new client to a new
/// server; the measurement covers the messages only.
///
/// One-way, a client stream sends the elements and the server counts them
/// (`clientToServer`), or a server stream sends them and the client iterates
/// them (`serverToClient`); both wait for the stream's terminal response.
/// Two-way, the client awaits each call before it makes the next one, or
/// keeps `concurrentCalls` calls in flight (`concurrent`).
func totalBenchmarks<Payload: ThroughputPayload>(_ payload: Payload.Type) {
    let sample = Payload.sample

    Benchmark("OneWay.total.clientToServer.\(Payload.shape)") { benchmark in
        let count = benchmark.scaledIterations.count
        try await withThroughputConnection { connection, entity in
            benchmark.startMeasurement()
            let stream = await connection.call(
                Payload.send,
                on: entity,
                Throughput.Count(count: count)
            )
            for _ in 0..<count {
                guard case .sent = await stream.send(sample) else {
                    preconditionFailure("the client stream ended before every element was sent")
                }
            }
            await stream.finish()
            let outcome = await stream.result()
            benchmark.stopMeasurement()
            guard case .success(let received) = outcome, received.count == count else {
                preconditionFailure("the server received \(outcome) of \(count) elements")
            }
        }
    }

    Benchmark("OneWay.total.serverToClient.\(Payload.shape)") { benchmark in
        let count = benchmark.scaledIterations.count
        try await withThroughputConnection { connection, entity in
            benchmark.startMeasurement()
            let stream = await connection.call(
                Payload.receive,
                on: entity,
                Throughput.Count(count: count)
            )
            var received = 0
            for await element in stream {
                blackHole(element)
                received += 1
            }
            let outcome = await stream.result()
            benchmark.stopMeasurement()
            guard case .success(let sent) = outcome, sent.count == count, received == count else {
                preconditionFailure("received \(received) of \(count) elements, then \(outcome)")
            }
        }
    }

    Benchmark("TwoWay.total.\(Payload.shape)") { benchmark in
        let count = benchmark.scaledIterations.count
        try await withThroughputConnection { connection, entity in
            benchmark.startMeasurement()
            for _ in 0..<count {
                blackHole(try await echo(sample, on: entity, through: connection))
            }
            benchmark.stopMeasurement()
        }
    }

    Benchmark("TwoWay.total.concurrent.\(Payload.shape)") { benchmark in
        let count = benchmark.scaledIterations.count
        try await withThroughputConnection { connection, entity in
            benchmark.startMeasurement()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for lane in 0..<concurrentCalls {
                    let calls = count / concurrentCalls + (lane < count % concurrentCalls ? 1 : 0)
                    group.addTask {
                        for _ in 0..<calls {
                            blackHole(try await echo(sample, on: entity, through: connection))
                        }
                    }
                }
                try await group.waitForAll()
            }
            benchmark.stopMeasurement()
        }
    }
}

/// How many calls the `concurrent` benchmarks keep in flight: the client's
/// and the server's default cap.
private let concurrentCalls = 16

/// One `echo` call; a failed call is a broken benchmark.
private func echo<Payload: ThroughputPayload>(
    _ sample: Payload,
    on entity: EntityName,
    through connection: MMClientConnection
) async throws -> Payload {
    switch await connection.call(Payload.echo, on: entity, sample) {
        case .success(let echoed):
            return echoed
        case .failure(let error):
            throw ThroughputFailure.run("\(Payload.echo.name) failed: \(error)")
    }
}

/// Runs `body` with a client connected to a new throughput server, and the
/// entity its calls target.
private func withThroughputConnection(
    _ body: (MMClientConnection, EntityName) async throws -> Void
) async throws {
    let path = socketPath("total")
    let entity = try EntityName.parse(throughputEntity).get()
    var logger = Logger(label: "mm.throughput.client")
    logger.logLevel = .warning
    let withClient = MMClient(endpoint: .unix(path: path), logger: logger)
        .mapError { ThroughputFailure.client("\($0)") }
    let outcome = await withThroughputServer(at: path) {
        await withClient { connection in
            do {
                try await body(connection, entity)
                return .success(())
            } catch {
                return .failure(error as? ThroughputFailure ?? .run("\(error)"))
            }
        }
    }
    try outcome.get()
}

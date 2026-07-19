import MMClient
import NIOConcurrencyHelpers

/// The client-side run-loop choreography shared by every "connected client"
/// harness: runs `connection.run()` as a structured child, executes `body`
/// (deadline-bounded) against `context` — the connection itself, or a harness
/// wrapper around it — closes the connection, joins the loop under its own
/// sibling deadline, and returns both results. Neither a broken client nor a
/// broken server can hang a test.
public func withClientRunLoop<Context: Sendable, T: Sendable>(
    connection: MMClientConnection,
    context: Context,
    bodySeconds: Double = 10,
    joinSeconds: Double = 15,
    _ body: @escaping @Sendable (Context) async throws -> T
) async throws -> (result: T, runResult: Result<Void, MMClientError>) {
    let runResult = NIOLockedValueBox<Result<Void, MMClientError>?>(nil)
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            let result = await connection.run()
            runResult.withLockedValue { $0 = result }
        }
        // A sibling deadline bounds the run() join: if the loop fails to
        // observe the close, the group throws instead of hanging the test.
        group.addTask {
            try await Task.sleep(
                for: .seconds(joinSeconds), tolerance: nil, clock: ContinuousClock())
            throw DeadlineExceeded()
        }
        let result: T
        do {
            result = try await withDeadline(seconds: bodySeconds) { try await body(context) }
        } catch {
            await connection.close()
            group.cancelAll()
            try? await group.waitForAll()
            throw error
        }
        await connection.close()
        _ = try await group.next()  // run() finished, or DeadlineExceeded
        group.cancelAll()  // stop the deadline child
        try? await group.waitForAll()  // its CancellationError is expected
        guard let finished = runResult.withLockedValue({ $0 }) else {
            throw DeadlineExceeded()
        }
        return (result, finished)
    }
}

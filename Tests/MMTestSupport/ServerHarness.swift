import FP
import FPBracket
import MMServer
import NIOCore

/// Why a ``withListeningServer(_:seconds:onBodyError:_:)`` run failed: the
/// server's bracket (bind, or a stop that failed) or the test body.
private enum ServerRunFailure: Error {
    case server(MMServiceError)
    case body(any Error)

    var underlying: any Error {
        switch self {
            case .server(let error): error
            case .body(let error): error
        }
    }
}

/// Runs the server's bracket (`service.start()`, the same bracket an
/// ``MMService`` initializer builds): acquire binds (the server is listening once
/// `body` starts), `body` runs with the bound address, then dispose drains
/// gracefully and joins. The whole bracket call is under one deadline, so a
/// shutdown bug cannot hang the test run: past it, the run is cancelled and
/// the drain becomes a teardown. When `body` throws, `onBodyError` runs before
/// the drain — the hook for opening test gates a failed body may have left
/// parked handlers on.
///
/// Rethrows the body's error, or the server's ``MMServiceError`` (a body
/// success does not hide a failed stop).
package func withListeningServer<T: Sendable>(
    _ service: ServerRuntime,
    seconds: Double = 60,
    onBodyError: @escaping @Sendable () async -> Void = {},
    _ body: @escaping @Sendable (SocketAddress) async throws -> T
) async throws -> T {
    let result = try await withDeadline(seconds: seconds) {
        let withServer = service.start().mapError(ServerRunFailure.server)
        return await withServer { address in
            await Result.fromAsync { try await body(address) }
                .mapError(ServerRunFailure.body)
                .tapErrorAsync { _ in await onBodyError() }
        }
    }
    return try result.mapError(\.underlying).get()
}

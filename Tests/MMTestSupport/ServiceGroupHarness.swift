import Logging
import ServiceLifecycle

/// Boots `service` in a `ServiceGroup`, waits (bounded) for `ready`, runs
/// `body`, then triggers graceful shutdown and joins. The whole group run is
/// itself under a deadline so a shutdown bug cannot hang the test run. When
/// `body` throws, `onBodyError` runs before the shutdown — the hook for
/// opening test gates a failed body may have left parked handlers on.
public func withServiceGroup<T: Sendable>(
    _ service: some Service,
    logger: Logger? = nil,
    ready: @escaping @Sendable () async throws -> Void,
    onBodyError: @escaping @Sendable () async -> Void = {},
    _ body: (ServiceGroup) async throws -> T
) async throws -> T {
    let groupLogger =
        logger
        ?? {
            var quiet = Logger(label: "mm.test.group")
            quiet.logLevel = .error
            return quiet
        }()
    let group = ServiceGroup(
        configuration: .init(services: [.init(service: service)], logger: groupLogger)
    )
    return try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
            try await withDeadline(seconds: 60) { try await group.run() }
        }
        try await withDeadline { try await ready() }
        let result: T
        do {
            result = try await body(group)
        } catch {
            await onBodyError()
            await group.triggerGracefulShutdown()
            try? await tasks.waitForAll()
            throw error
        }
        await group.triggerGracefulShutdown()
        try await tasks.waitForAll()
        return result
    }
}

/// Thrown when a ``withDeadline(seconds:_:)`` bound elapses before its body
/// finishes.
public struct DeadlineExceeded: Error {
    public init() {}
}

/// Bounds any await with a `ContinuousClock` deadline so a broken peer hangs
/// a test for at most `seconds`, never forever. The deadline branch is a
/// bounded race, not a synchronization sleep.
public func withDeadline<T: Sendable>(
    seconds: Double = 10,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds), tolerance: nil, clock: ContinuousClock())
            throw DeadlineExceeded()
        }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        group.cancelAll()
        return first
    }
}

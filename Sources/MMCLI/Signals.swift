import UnixSignals

/// Structured SIGINT handling for streaming commands: first Ctrl-C asks the
/// call to wind down gracefully, an optional second one escalates.
public enum MMCLISignals {
    private enum Event<T: Sendable>: Sendable {
        case finished(T)
        case watcherDrained
    }

    /// Runs `body` with a sibling SIGINT watcher.
    ///
    /// Both run as children of one task group — fully structured, no
    /// free-floating tasks. The first SIGINT invokes `onFirst` (a streaming
    /// command passes its graceful STOP there), the second invokes `onSecond`
    /// when given. Signals never end `body`: it always runs to its own
    /// completion (`onFirst`/`onSecond` are what nudge it to finish). When
    /// `body` returns, the watcher is cancelled and the value returned; a
    /// `body` error cancels the watcher and propagates.
    public static func withGracefulSigint<T: Sendable>(
        onFirst: @Sendable @escaping () async -> Void,
        onSecond: (@Sendable () async -> Void)? = nil,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: Event<T>.self) { tasks in
            tasks.addTask {
                let signals = await UnixSignalsSequence(trapping: .sigint)
                var sigintCount = 0
                for await _ in signals {
                    sigintCount += 1
                    switch sigintCount {
                        case 1:
                            await onFirst()
                        case 2:
                            await onSecond?()
                        default:
                            // Further SIGINTs are absorbed here on purpose:
                            // the default action would kill the process
                            // mid-drain. body's own completion ends the run.
                            continue
                    }
                }
                // Cancellation ended the signal sequence (body finished).
                return .watcherDrained
            }
            tasks.addTask {
                .finished(try await body())
            }
            // A body error rethrows out of next() and the group cancels the
            // watcher on exit. The watcher draining first (only on
            // cancellation races) just means body's event is next.
            while let event = try await tasks.next() {
                if case .finished(let value) = event {
                    tasks.cancelAll()
                    return value
                }
            }
            // Unreachable: the body child always yields .finished or throws.
            throw CancellationError()
        }
    }
}

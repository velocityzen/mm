/// The shared register-or-immediate continuation park with a synchronous
/// cancel hand-off — the one suspension shape behind the unary response wait,
/// the writer wait, the inbound-demand park, and the outbound-credit park.
///
/// `register` runs inside `withCheckedContinuation`, under the caller's own
/// lock: it either stores the continuation in the caller's state and returns
/// nil (parking), or declines to park by returning the immediate value. On
/// task cancellation `takeParkedOnCancel` runs *synchronously* (the reason
/// every caller keeps this state in a lock, not an actor): in one locked
/// mutation it marks whatever sticky flag makes the caller's register↔cancel
/// race deterministic and removes the stored continuation, which then resumes
/// with `cancelled`.
///
/// Single-resume rule: exactly one of the three paths touches the
/// continuation — `register` returning a value (resumed here, never stored),
/// the caller's own signal (resumed by the caller after removing it from
/// state), or `takeParkedOnCancel` (removed and resumed here). The
/// checked continuation traps if a caller breaks the discipline.
func withParkedContinuation<Value: Sendable>(
    register: (CheckedContinuation<Value, Never>) -> Value?,
    takeParkedOnCancel: @escaping @Sendable () -> CheckedContinuation<Value, Never>?,
    cancelled: Value
) async -> Value {
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            if let immediate = register(continuation) {
                continuation.resume(returning: immediate)
            }
        }
    } onCancel: {
        takeParkedOnCancel()?.resume(returning: cancelled)
    }
}

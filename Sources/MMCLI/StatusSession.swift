import ArgumentParser
import ProgramStatus
import Synchronization

/// One invocation's record on the terminal: ``MMCLIRunner`` opens it around
/// the command and reports `working` at the start and `done`, `error`, or
/// `idle` at the end. Bound as a task-local for the command's task tree, so
/// the places that learn something on the way report into it without
/// threading it through: the input readers (`blocked`), the stderr writer
/// (the failure's line), and the SIGINT watcher (interrupted).
final class MMCLIStatusSession: Sendable {
    /// The running invocation's session; nil without
    /// ``ProgramStatusReporting(app:)``, or outside ``MMCLIRunner``.
    @TaskLocal static var current: MMCLIStatusSession?

    private struct State {
        /// The last line written to stderr: a failure's reason.
        var diagnostic: String?
        var interrupted = false
    }

    let programStatus: MMCLIProgramStatus
    /// What the command does, such as `journal.read on journal.notes`.
    let activity: String?
    private let state = Mutex(State())

    init(_ programStatus: MMCLIProgramStatus, activity: String?) {
        self.programStatus = programStatus
        self.activity = activity
    }

    /// `method on entity`, the way failures name a call; just the method when
    /// the entity is left to the server.
    static func activity(method: String?, entity: String) -> String? {
        method.map { entity.isEmpty ? $0 : "\($0) on \(entity)" }
    }

    func start() {
        self.programStatus.report(.working(self.activity))
    }

    /// Reports `blocked` when `input` is the terminal: the command waits for
    /// the user to type lines.
    func awaitLines(from input: MMCLIInput) {
        guard input.isTerminal else { return }
        let waiting = "waiting for lines, Ctrl-D ends"
        let message = self.activity.map { "\($0): \(waiting)" } ?? waiting
        self.programStatus.report(.blocked(message, kind: .question))
    }

    func diagnose(_ message: String) {
        self.state.withLock { $0.diagnostic = message }
    }

    func interrupt() {
        self.state.withLock { $0.interrupted = true }
    }

    func finish<T>(_ outcome: Result<T, any Error>) {
        let state = self.state.withLock { $0 }
        self.programStatus.report(
            Self.report(
                for: outcome.map { _ in () },
                interrupted: state.interrupted,
                diagnostic: state.diagnostic,
                activity: self.activity
            )
        )
    }

    /// The record a finished command leaves. Pure, so tests pin the mapping:
    ///
    /// - success → `done`, or `idle` when Ctrl-C wound it down;
    /// - exit 130 or cancellation → `idle`;
    /// - any other failure → `error`, with the line it wrote to stderr.
    static func report(
        for outcome: Result<Void, any Error>,
        interrupted: Bool,
        diagnostic: String?,
        activity: String?
    ) -> StatusReport {
        switch outcome {
            case .success:
                return interrupted ? .idle(activity) : .done(activity)
            case .failure(let error as ExitCode) where error.rawValue == 0:
                return interrupted ? .idle(activity) : .done(activity)
            case .failure(let error as ExitCode) where error.rawValue == 130:
                return .idle(activity)
            case .failure(is CancellationError):
                return .idle(activity)
            case .failure(let error as ExitCode):
                return .error(diagnostic ?? activity ?? "exit code \(error.rawValue)")
            case .failure(let error):
                return .error(diagnostic ?? String(describing: error))
        }
    }
}

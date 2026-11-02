import ProgramStatus

/// The tool's [Program Status Protocol](https://github.com/velocityzen/ProgramStatus)
/// reporting (OSC 7501): the terminal learns whether a command is working,
/// done, blocked on the user, or failed, and can show it on the tab or notify.
/// Declared with ``ProgramStatusReporting(app:)`` and ``Status(_:_:)`` entries
/// in the ``MMCLI(_:)`` block; a tool without it writes nothing to the
/// terminal.
///
/// Reports go to the controlling terminal (`/dev/tty`), so they reach the user
/// even when stdout and stderr are redirected, and are skipped when there is
/// none (CI, cron). Each one is collapsed onto one line and cut to the
/// protocol's limits first, so a multi-line remote error or a long line still
/// arrives.
public struct MMCLIProgramStatus: Sendable {
    let send: @Sendable (StatusReport) -> Void
    var statuses: [ObjectIdentifier: @Sendable (Any) -> StatusReport?]

    /// Reports through `reporter`, with the per-type `statuses`.
    public init(reporter: ProgramStatusReporter, statuses: [MMCLIStatusEntry] = []) {
        let reporter = Self.validated(reporter)
        self.init(send: { reporter.send($0) }, statuses: statuses)
    }

    /// Reports to `send`; tests collect the reports here.
    init(send: @escaping @Sendable (StatusReport) -> Void, statuses: [MMCLIStatusEntry] = []) {
        self.send = send
        self.statuses = Dictionary(
            statuses.map { ($0.key, $0.report) },
            uniquingKeysWith: { _, second in second }
        )
    }

    /// These with `entries` added; an entry for a type already present
    /// replaces it.
    func adding(_ entries: [MMCLIStatusEntry]) -> MMCLIProgramStatus {
        var added = self
        for entry in entries {
            added.statuses[entry.key] = entry.report
        }
        return added
    }

    /// Sends one report, fitted to the protocol's limits.
    func report(_ report: StatusReport) {
        self.send(Self.fitted(report))
    }

    /// Sends the report `value`'s ``Status(_:_:)`` entry makes of it, if its
    /// type has one and the entry returns a report.
    func report<T>(_ value: T) {
        guard let report = self.statuses[ObjectIdentifier(T.self)]?(value) else { return }
        self.report(report)
    }
}

extension MMCLIProgramStatus {
    /// Decoded UTF-8 bytes the protocol accepts for a `msg` and a `title`.
    static let messageBytes = 2048
    static let titleBytes = 192

    /// The report with its message and title each on one line and cut to fit.
    static func fitted(_ report: StatusReport) -> StatusReport {
        StatusReport(
            state: report.state,
            id: report.id,
            app: report.app,
            title: report.title.flatMap { Self.fitted($0, bytes: Self.titleBytes) },
            message: report.message.flatMap { Self.fitted($0, bytes: Self.messageBytes) }
        )
    }

    /// `text` on one line, at most `limit` bytes of UTF-8, ending in `…` when
    /// cut; nil when nothing is left of it.
    static func fitted(_ text: String, bytes limit: Int) -> String? {
        let line = StatusText.singleLine(text)
        guard !line.isEmpty else { return nil }
        guard line.utf8.count > limit else { return line }

        let ellipsis = "…"
        var budget = limit - ellipsis.utf8.count
        var kept = ""
        for character in line {
            let size = character.utf8.count
            guard size <= budget else { break }
            kept.append(character)
            budget -= size
        }
        return kept + ellipsis
    }

    /// The reporter, when its `app` is one the protocol accepts. Every report
    /// carries it, so an invalid one would silently drop them all: it stops
    /// the tool at startup instead.
    static func validated(_ reporter: ProgramStatusReporter) -> ProgramStatusReporter {
        if case .failure(let error) = StatusEncoder.encode(.idle(app: reporter.app)) {
            preconditionFailure("ProgramStatusReporting: \(error.localizedDescription)")
        }
        return reporter
    }
}

/// Turns on Program Status Protocol reporting for the tool, as `app`: a stable
/// identifier of 1 to 32 characters of `[A-Za-z0-9_.+-]`, such as the tool's
/// name. See ``MMCLIProgramStatus``.
///
/// While a command runs, its record on the terminal is:
///
/// - `working`, with the call it makes (`journal.read on journal.notes`), from
///   the moment it connects;
/// - `blocked` (`question`) while it waits for lines typed into the terminal:
///   a request stream, or `--input -`, read from a terminal stdin;
/// - `done` when it succeeds, `error` with the line it wrote to stderr when it
///   fails, and `idle` when Ctrl-C ended it;
/// - whatever a ``Status(_:_:)`` entry makes of each value it prints.
///
/// ```swift
/// await MMCLI {
///     Name("journal")
///     Commands([Journal.Command.self])
///     ProgramStatusReporting(app: "journal")
///     Status(ChangeEvent.self) { event in .done(event.line, title: event.entity) }
/// }
/// ```
public func ProgramStatusReporting(app: String) -> MMCLIPart {
    ProgramStatusReporting(ProgramStatusReporter(app: app))
}

/// ``ProgramStatusReporting(app:)`` with a reporter of your own, to write
/// somewhere other than the controlling terminal or to end sequences with BEL.
public func ProgramStatusReporting(_ reporter: ProgramStatusReporter) -> MMCLIPart {
    MMCLIPart(kind: .programStatus(MMCLIProgramStatus(reporter: reporter)))
}

/// One per-type status rule; see ``Status(_:_:)``.
public struct MMCLIStatusEntry: Sendable {
    let key: ObjectIdentifier
    let report: @Sendable (Any) -> StatusReport?
}

/// Declares the report a value of `type` makes when the command prints it:
/// each element of a stream, such as an event a server pushes, and each
/// response. The report replaces the command's record, so the terminal can
/// notify on every event a `follow` delivers. Return nil to leave the record
/// as it is. Takes effect with ``ProgramStatusReporting(app:)``.
///
/// A response's report comes after the command's own `done` or `idle`, so it
/// is the record the command leaves behind.
///
/// ```swift
/// Status(ChangeEvent.self) { event in
///     event.line.isEmpty ? nil : .done(event.line, title: event.entity)
/// }
/// ```
public func Status<T: Encodable & Sendable>(
    _ type: T.Type,
    _ report: @Sendable @escaping (T) -> StatusReport?
) -> MMCLIStatusEntry {
    MMCLIStatusEntry(
        key: ObjectIdentifier(T.self),
        report: { value in (value as? T).flatMap(report) }
    )
}

/// ``Status(_:_:)`` with the type inferred from the closure's parameter:
///
/// ```swift
/// Status { (event: ChangeEvent) in .done(event.line) }
/// ```
public func Status<T: Encodable & Sendable>(
    _ report: @Sendable @escaping (T) -> StatusReport?
) -> MMCLIStatusEntry {
    Status(T.self, report)
}

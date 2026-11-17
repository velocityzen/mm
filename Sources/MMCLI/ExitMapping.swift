import ArgumentParser
import MMClient
import MMSchema

/// Maps per-call failures to process exits: one line to stderr, one
/// sysexits-style code. Generated commands funnel every `Result` through
/// ``unwrap(_:method:entity:)`` and let the thrown `ExitCode` end the process.
public enum MMCLIFailure {
    /// The exit code for a call error. Pure — the sanctioned place to decide
    /// codes, kept free of IO so tests pin the whole mapping.
    ///
    /// - `denied` → 77 (EX_NOPERM)
    /// - `unknownMethod` → 64 (EX_USAGE)
    /// - `malformedParams`, `invalidRequest` → 65 (EX_DATAERR)
    /// - `remote` (application `MMError`) → 1
    /// - `remoteInternal`, `encode`, `decode`, `streamViolation`,
    ///   `tooManyInFlight` → 70 (EX_SOFTWARE)
    /// - `transport`, `connectionClosed` → 69 (EX_UNAVAILABLE)
    /// - `cancelled` → 130 (128 + SIGINT)
    public static func code(for error: MMCallError) -> ExitCode {
        switch error {
            case .denied:
                return ExitCode(77)
            case .unknownMethod:
                return ExitCode(64)
            case .malformedParams, .invalidRequest:
                return ExitCode(65)
            case .remote:
                return ExitCode(1)
            case .remoteInternal, .encode, .decode, .streamViolation, .tooManyInFlight:
                return ExitCode(70)
            case .transport, .connectionClosed:
                return ExitCode(69)
            case .cancelled:
                return ExitCode(130)
        }
    }

    /// The one-line stderr message for a call error. Pure, like
    /// ``code(for:)``.
    static func message(for error: MMCallError, method: String, entity: String) -> String {
        // An omitted entity (server-side inference) reads as such, not as a
        // dangling "on ".
        let entity = entity.isEmpty ? "(inferred entity)" : entity
        switch error {
            case .denied:
                return "denied: \(method) on \(entity)"
            case .unknownMethod:
                return "unknown method \(method) — try `discover`"
            case .malformedParams(let object):
                // The server's message names the failing field when it can:
                // `malformed params: limit: is 0, less than the minimum 1`.
                return "\(method): \(object.message)"
            case .invalidRequest(let path, let problem):
                return
                    "\(method): invalid request: \(SchemaValueError(path: path, problem: problem))"
            case .remote(let object):
                return "error \(object.code): \(object.message)"
            case .remoteInternal:
                return "remote internal error in \(method) on \(entity)"
            case .streamViolation(let object):
                return "stream violation in \(method): \(object.message)"
            case .encode(let wireError):
                return "request encoding failed for \(method): \(wireError)"
            case .decode(let wireError):
                return "response decoding failed for \(method): \(wireError)"
            case .tooManyInFlight:
                return "too many in-flight calls on this connection"
            case .transport(let description):
                return "transport failed: \(description)"
            case .connectionClosed:
                return "connection closed before \(method) completed"
            case .cancelled:
                return "cancelled"
        }
    }

    /// Writes the one-line diagnosis to stderr and returns the exit code for
    /// the command to throw.
    public static func exit(
        for error: some MMCLIReportableFailure,
        method: String,
        entity: String
    ) -> ExitCode {
        MMCLIOutput.note(error.message(method: method, entity: entity))
        return error.exitCode
    }

    /// The funnel generated commands call: a success passes through, a
    /// failure is rendered to stderr and thrown as its `ExitCode` — a
    /// declared error's the one its contract pins.
    public static func unwrap<T, Failure: MMCLIReportableFailure>(
        _ result: Result<T, Failure>,
        method: String,
        entity: String
    ) throws -> T {
        switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw Self.exit(for: error, method: method, entity: entity)
        }
    }

    /// Parses a user-supplied entity argument, turning a schema-level parse
    /// failure into the `ValidationError` swift-argument-parser expects.
    public static func entity(_ raw: String) throws -> EntityName {
        switch EntityName.parse(raw) {
            case .success(let name):
                return name
            case .failure(let error):
                throw ValidationError("invalid entity '\(raw)': \(error)")
        }
    }

    /// The entity a call with a declared target targets, checked before
    /// connecting. An omitted or empty argument means the target's one
    /// entity when it names exactly one, as the server infers it, else root.
    /// An entity the target does not admit, root included, is refused with
    /// a message naming the target: the server would deny it.
    public static func entity(
        _ argument: String?,
        method: String,
        target: [EntityPattern]
    ) throws -> (argument: String, entity: EntityName) {
        let parsed = try entity(argument ?? "")
        // The server reads the target as its contract states it, each
        // pattern once, so a doubled pattern still names one entity.
        let sole = EntityPattern.soleEntity(of: EntityPattern.normalized(target))
        let name = parsed.isRoot ? (sole ?? parsed) : parsed
        if let refusal = targetRefusal(name, method: method, target: target) {
            throw ValidationError(refusal)
        }
        return (name.rawValue, name)
    }

    /// Why the declared target refuses `entity`, or nil when it admits it.
    static func targetRefusal(
        _ entity: EntityName,
        method: String,
        target: [EntityPattern]
    ) -> String? {
        guard !EntityPattern.admits(target, entity) else { return nil }
        let listed = EntityPattern.listed(target)
        return entity.isRoot
            ? "\(method) needs a target entity within \(listed)"
            : "entity '\(entity.rawValue)' is outside \(method)'s target \(listed)"
    }
}

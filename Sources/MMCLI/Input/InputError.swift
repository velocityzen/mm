import ArgumentParser
import Foundation
import MMClient

/// A failure of an input-driven command (a request field declared
/// `cli: .input`): its input could not be read, or one of its calls failed.
/// It is the error type of ``MMCLIInput``, ``MMCLIInputLines`` and
/// ``MMCLIInputCall``, so an `Input(...)` body's stages share one failure
/// channel.
public enum MMCLIError: LocalizedError, Sendable {
    /// `--input <path>` could not be opened.
    case inputUnreadable(path: String, reason: String)
    /// Reading the input failed partway through.
    case inputReadFailed(source: String, reason: String)
    /// An input line was longer than the limit ``MMCLIInput/lines(maximumLength:)`` set.
    case lineTooLong(limit: Int)
    /// A call failed. It is reported like any generated command's failure.
    case call(MMCallError, method: String, entity: String)

    public var errorDescription: String? {
        switch self {
            case .inputUnreadable(let path, let reason):
                return "cannot read --input \(path): \(reason)"
            case .inputReadFailed(let source, let reason):
                return "reading \(source) failed: \(reason)"
            case .lineTooLong(let limit):
                return "input line longer than \(limit) bytes"
            case .call(let error, let method, let entity):
                return MMCLIFailure.message(for: error, method: method, entity: entity)
        }
    }

    /// The process exit code: sysexits-style, like ``MMCLIFailure/code(for:)``.
    ///
    /// - `inputUnreadable` → 66 (EX_NOINPUT)
    /// - `inputReadFailed` → 74 (EX_IOERR)
    /// - `lineTooLong` → 65 (EX_DATAERR)
    /// - `call` → ``MMCLIFailure/code(for:)``
    public var exitCode: ExitCode {
        switch self {
            case .inputUnreadable:
                return ExitCode(66)
            case .inputReadFailed:
                return ExitCode(74)
            case .lineTooLong:
                return ExitCode(65)
            case .call(let error, _, _):
                return MMCLIFailure.code(for: error)
        }
    }
}

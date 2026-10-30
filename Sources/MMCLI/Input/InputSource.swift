import ArgumentParser
import FP
import FPBracket
import NIOPosix

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Where a `cli: .input` field's bytes come from: the value given on the
/// command line, a file (`--input <path>`), or standard input
/// (`--input -`). Hand-written commands can use it as well:
/// ``from(value:path:name:)`` checks the two arguments, and ``open()``
/// yields the ``MMCLIInput``.
public enum MMCLIInputSource: Sendable, Hashable {
    case value(String)
    case file(path: String)
    case standardInput

    /// The source the two arguments describe: exactly one of them must be
    /// given. `name` is the value's placeholder in the message.
    public static func from(
        value: String?,
        path: String?,
        name: String
    ) -> Result<MMCLIInputSource, ValidationError> {
        switch (value, path) {
            case (let value?, nil):
                return .success(.value(value))
            case (nil, "-"?):
                return .success(.standardInput)
            case (nil, let path?):
                return .success(.file(path: path))
            case (nil, nil):
                return .failure(ValidationError("Missing expected argument '<\(name)>' (or --input <path>)"))
            case (.some, .some):
                return .failure(ValidationError("'<\(name)>' and --input are mutually exclusive"))
        }
    }

    /// The input as a scoped resource. A file is opened on acquire and closed
    /// on dispose. A value and stdin own nothing to close. A file that cannot
    /// be opened fails acquire with ``MMCLIError/inputUnreadable(path:reason:)``.
    public func open() -> BracketAsync<MMCLIInput, MMCLIError> {
        switch self {
            case .value(let text):
                return .of(MMCLIInput(text: text))
            case .standardInput:
                return .of(.standardInput)
            case .file(let path):
                return BracketAsync(
                    acquire: { await Self.openFile(path) },
                    dispose: { input in
                        await input.close()
                        return .success(())
                    }
                )
        }
    }

    /// Opens on the blocking pool: opening a FIFO waits for its writer.
    private static func openFile(_ path: String) async -> Result<MMCLIInput, MMCLIError> {
        await Result.fromAsync {
            try await NIOThreadPool.singleton.runIfActive { Self.blockingOpen(path) }
        }
        .mapError { MMCLIError.inputUnreadable(path: path, reason: "\($0)") }
        .flatMap { $0 }
        .map { MMCLIInput(descriptor: $0, name: path) }
    }

    private static func blockingOpen(_ path: String) -> Result<CInt, MMCLIError> {
        let descriptor = systemOpen(path)
        guard descriptor >= 0 else {
            return .failure(.inputUnreadable(path: path, reason: String(cString: strerror(errno))))
        }
        return .success(descriptor)
    }
}

/// `open(2)`, out of reach of the `open()` member's name.
private func systemOpen(_ path: String) -> CInt {
    open(path, O_RDONLY | O_CLOEXEC)
}

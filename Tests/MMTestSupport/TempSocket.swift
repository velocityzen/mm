import Foundation  // Tests only: mkdtemp template under NSTemporaryDirectory().

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A harness-level failure (setup plumbing, not the code under test).
public struct TestHarnessFailure: Error {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// `mkdtemp(3)` under the system temp directory; the short "s" socket name
/// keeps the full path well inside `sun_path`'s limit.
public func makeTempSocketPath(prefix: String = "mm-") throws -> String {
    var template = Array((NSTemporaryDirectory() + prefix + "XXXXXX").utf8CString)
    let directory = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
        return String(cString: base)
    }
    guard let directory else {
        throw TestHarnessFailure(description: "mkdtemp failed, errno \(errno)")
    }
    return directory + "/s"
}

/// Scopes a fresh temp socket path to `body` and cleans up afterwards — the
/// socket file (left behind on failure paths where the server never unlinked
/// it) and the `mkdtemp` directory — pass or fail, so test runs leave no
/// debris under the system temp directory.
public func withTempSocketPath<T>(
    prefix: String = "mm-",
    _ body: (String) async throws -> T
) async throws -> T {
    let path = try makeTempSocketPath(prefix: prefix)
    defer {
        unlink(path)
        rmdir(String(path.dropLast("/s".count)))
    }
    return try await body(path)
}

/// The synchronous variant, for tests that never suspend.
public func withTempSocketPath<T>(
    prefix: String = "mm-",
    _ body: (String) throws -> T
) throws -> T {
    let path = try makeTempSocketPath(prefix: prefix)
    defer {
        unlink(path)
        rmdir(String(path.dropLast("/s".count)))
    }
    return try body(path)
}

import Foundation  // Tests only: mkdtemp template under NSTemporaryDirectory().
import Logging
import MMClient
import MMSchema
import MMServer
import MMWire
import NIOCore
import ServiceLifecycle

@testable import MMCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Bounded waits (no sleeps)

struct CLITestFailure: Error {
    let description: String
}

/// Bounds any await with a `ContinuousClock` deadline so a broken server
/// hangs a test for at most `seconds`, never forever.
func withCLIDeadline<T: Sendable>(
    seconds: Double = 10,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds), tolerance: nil, clock: ContinuousClock())
            throw CLITestFailure(description: "deadline exceeded")
        }
        guard let first = try await group.next() else {
            throw CLITestFailure(description: "deadline exceeded")
        }
        group.cancelAll()
        return first
    }
}

// MARK: - Temp socket paths

/// `mkdtemp(3)` under the system temp directory; the short "s" socket name
/// keeps the full path well inside `sun_path`'s limit.
private func makeCLITempSocketPath() throws -> String {
    var template = Array((NSTemporaryDirectory() + "mm-cli-XXXXXX").utf8CString)
    let directory = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
        return String(cString: base)
    }
    guard let directory else {
        throw CLITestFailure(description: "mkdtemp failed, errno \(errno)")
    }
    return directory + "/s"
}

/// Scopes a fresh temp socket path to `body` and cleans up afterwards, pass
/// or fail, so test runs leave no debris under the system temp directory.
private func withCLITempSocketPath<T>(_ body: (String) async throws -> T) async throws -> T {
    let path = try makeCLITempSocketPath()
    defer {
        unlink(path)
        rmdir(String(path.dropLast("/s".count)))
    }
    return try await body(path)
}

// MARK: - Wire fixtures

struct CLIEchoRequest: Codable, Hashable, Sendable {
    var value: Int
    var note: String?

    enum CodingKeys: Int, CodingKey {
        case value = 0
        case note = 1
    }
}

struct CLIEchoResponse: Codable, Hashable, Sendable {
    var value: Int
    var note: String?

    enum CodingKeys: Int, CodingKey {
        case value = 0
        case note = 1
    }
}

struct CLIFollowRequest: Codable, Hashable, Sendable {
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case count = 0
    }
}

/// An empty opening request (the `SchemaRequest` pattern: self-described so
/// the probe never has to synthesize a no-field decode).
struct CLIImportRequest: Codable, Hashable, Sendable, SchemaDescribable {
    init() {}

    static var schema: TypeSchema { .structure(fields: []) }
}

struct CLIStreamItem: Codable, Hashable, Sendable {
    var value: Int

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }
}

struct CLIStreamSummary: Codable, Hashable, Sendable {
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case count = 0
    }
}

enum CLITestMethods {
    static let echo = Method<CLIEchoRequest, CLIEchoResponse>(name: "echo.run", access: .write)
    /// Streams `count` items (values `0..<count`), then a success summary.
    static let follow = ServerStreamMethod<CLIFollowRequest, CLIStreamItem, CLIStreamSummary>(
        name: "box.follow", access: .read
    )
    /// Streams `count` items, then a fixed **application error** terminal.
    static let followFailing = ServerStreamMethod<
        CLIFollowRequest, CLIStreamItem, CLIStreamSummary
    >(
        name: "box.followFail", access: .read
    )
    /// Consumes elements to END, answers with the count consumed.
    static let importItems = ClientStreamMethod<CLIImportRequest, CLIStreamItem, CLIStreamSummary>(
        name: "box.import", access: .write
    )
    /// Echoes each inbound element outbound; terminal carries the count.
    static let pipe = BidirectionalStreamMethod<
        CLIImportRequest, CLIStreamItem, CLIStreamItem, CLIStreamSummary
    >(
        name: "box.pipe", access: .write
    )
}

func cliTestEntity(_ raw: String) -> EntityName {
    switch EntityName.parse(raw) {
        case .success(let name):
            return name
        case .failure(let error):
            fatalError("invalid test entity '\(raw)': \(error)")
    }
}

/// The ACL world: `box` and `echo` fully ours; `locked` owned by us with no
/// bits at all — the denial fixture (first matching class wins, and the
/// owner class grants nothing).
private func cliTestACLs() -> [EntityName: EntityACL] {
    let uid = getuid()
    let gid = getgid()
    return [
        cliTestEntity("box"): EntityACL(owner: uid, group: gid, mode: 0o700),
        cliTestEntity("echo"): EntityACL(owner: uid, group: gid, mode: 0o700),
        cliTestEntity("locked"): EntityACL(owner: uid, group: gid, mode: 0o000),
        // The builtins' method-name prefixes: x here makes rpc.schema and
        // entity.stat visible in this peer's filtered discovery response.
        cliTestEntity("rpc"): EntityACL(owner: uid, group: gid, mode: 0o700),
        cliTestEntity("entity"): EntityACL(owner: uid, group: gid, mode: 0o700),
    ]
}

// MARK: - Server harness

private func makeCLITestService(
    socketPath: String,
    onBind: @escaping @Sendable (SocketAddress) -> Void
) -> MMService {
    var logger = Logger(label: "mm.clitest.server")
    logger.logLevel = .warning
    return MMService(
        configuration: MMServerConfiguration(endpoint: .unix(path: socketPath)),
        aclProvider: InMemoryACLProvider(cliTestACLs()),
        logger: logger,
        onBind: onBind
    ) {
        Handle(CLITestMethods.echo) { request, _ in
            .success(CLIEchoResponse(value: request.value, note: request.note))
        }
        Handle(CLITestMethods.follow) { request, sink, _ in
            var produced = 0
            for value in 0..<request.count {
                switch await sink.send(CLIStreamItem(value: value)) {
                    case .sent:
                        produced += 1
                    case .peerStopped, .callEnded:
                        return .success(CLIStreamSummary(count: produced))
                }
            }
            return .success(CLIStreamSummary(count: produced))
        }
        Handle(CLITestMethods.followFailing) { request, sink, _ in
            for value in 0..<request.count {
                switch await sink.send(CLIStreamItem(value: value)) {
                    case .sent:
                        continue
                    case .peerStopped, .callEnded:
                        return .failure(MMErrorObject(code: 64, message: "follow failure"))
                }
            }
            return .failure(MMErrorObject(code: 64, message: "follow failure"))
        }
        Handle(CLITestMethods.importItems) { _, elements, _ in
            var consumed = 0
            for await _ in elements { consumed += 1 }
            return .success(CLIStreamSummary(count: consumed))
        }
        Handle(CLITestMethods.pipe) { _, elements, sink, _ in
            var echoed = 0
            for await element in elements {
                switch await sink.send(element) {
                    case .sent:
                        echoed += 1
                    case .peerStopped, .callEnded:
                        return .success(CLIStreamSummary(count: echoed))
                }
            }
            return .success(CLIStreamSummary(count: echoed))
        }
    }
}

/// Boots the test service on a fresh temp socket, waits (bounded) for the
/// bind, hands `body` ready-made `MMCLIOptions` pointing at the socket, then
/// triggers graceful shutdown and joins — everything deadline-bounded.
func withCLIServer<T: Sendable>(
    _ body: @escaping @Sendable (MMCLIOptions) async throws -> T
) async throws -> T {
    try await withCLITempSocketPath { path in
        let (bound, boundContinuation) = AsyncStream<SocketAddress>.makeStream()
        let service = makeCLITestService(socketPath: path) { address in
            boundContinuation.yield(address)
            boundContinuation.finish()
        }
        var groupLogger = Logger(label: "mm.clitest.group")
        groupLogger.logLevel = .error
        let group = ServiceGroup(
            configuration: .init(services: [.init(service: service)], logger: groupLogger)
        )
        return try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask {
                try await withCLIDeadline(seconds: 60) { try await group.run() }
            }
            _ = try await withCLIDeadline { await bound.first(where: { _ in true }) }
            // Parsed, not memberwise-constructed: ArgumentParser property
            // wrappers trap when read before a parse has populated them.
            let optionsForBody = try MMCLIOptions.parse(["--socket", path])
            let result: T
            do {
                result = try await withCLIDeadline(seconds: 30) { try await body(optionsForBody) }
            } catch {
                await group.triggerGracefulShutdown()
                try? await tasks.waitForAll()
                throw error
            }
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
            return result
        }
    }
}

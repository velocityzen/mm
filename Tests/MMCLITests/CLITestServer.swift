import Logging
import MMClient
import MMSchema
import MMServer
import MMTestSupport
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
// withDeadline and withTempSocketPath come from MMTestSupport.

struct CLITestFailure: Error {
    let description: String
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
        // The builtins' method-name prefixes: x here makes server.schema and
        // server.entity visible in this peer's filtered discovery response.
        cliTestEntity("server"): EntityACL(owner: uid, group: gid, mode: 0o700),
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
                        return .failure(MMError(code: 64, message: "follow failure"))
                }
            }
            return .failure(MMError(code: 64, message: "follow failure"))
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
/// triggers graceful shutdown and joins — the shared
/// ``withServiceGroup(_:logger:ready:onBodyError:_:)`` choreography.
@discardableResult
func withCLIServer<T: Sendable>(
    _ body: @escaping @Sendable (MMCLIOptions) async throws -> T
) async throws -> T {
    try await withTempSocketPath(prefix: "mm-cli-") { path in
        let (bound, boundContinuation) = AsyncStream<SocketAddress>.makeStream()
        let service = makeCLITestService(socketPath: path) { address in
            boundContinuation.yield(address)
            boundContinuation.finish()
        }
        return try await withServiceGroup(
            service,
            ready: { _ = await bound.first(where: { _ in true }) }
        ) { _ in
            // Parsed, not memberwise-constructed: ArgumentParser property
            // wrappers trap when read before a parse has populated them.
            let optionsForBody = try MMCLIOptions.parse(["--socket", path])
            return try await withDeadline(seconds: 30) { try await body(optionsForBody) }
        }
    }
}

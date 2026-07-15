import Logging
import MMSchema
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded

@testable import MMClient

// MARK: - Deadlines (no test may hang)

struct DeadlineExceeded: Error {}

/// The failure of a `Result`, or nil on success — exact typed assertions for
/// results whose success side is not `Equatable` (`Void`, the connection).
func failure<T, E>(_ result: Result<T, E>) -> E? {
    guard case .failure(let error) = result else { return nil }
    return error
}

/// Bounds any await with a `ContinuousClock` deadline so a broken client hangs
/// a test for at most `seconds`, never forever. The deadline branch is a
/// bounded race, not a synchronization sleep.
func withDeadline<T: Sendable>(
    seconds: Double = 10,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds), tolerance: nil, clock: ContinuousClock())
            throw DeadlineExceeded()
        }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        group.cancelAll()
        return first
    }
}

// MARK: - Wire fixtures

struct BoxRequest: Codable, Hashable, Sendable {
    var value: UInt8

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }
}

struct BoxResponse: Codable, Hashable, Sendable {
    var value: UInt8

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }
}

/// A request with an arbitrarily sized payload, for outbound-cap tests.
struct PadRequest: Codable, Hashable, Sendable {
    var blob: [UInt8]

    enum CodingKeys: Int, CodingKey {
        case blob = 0
    }
}

/// A stream element: a single-int payload (map key 0), like the server
/// fixtures' `StreamItem`.
struct StreamElement: Codable, Hashable, Sendable {
    var value: Int

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }
}

/// A stream terminal summary (map key 0), like the server fixtures'
/// `StreamSummary`.
struct StreamSummary: Codable, Hashable, Sendable {
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case count = 0
    }
}

enum ClientTestMethods {
    static let boxGet = Method<BoxRequest, BoxResponse>(name: "box.get", access: .read)
    static let boxPad = Method<PadRequest, BoxResponse>(name: "box.pad", access: .write)

    static let follow = ServerStreamMethod<BoxRequest, StreamElement, StreamSummary>(
        name: "box.follow", access: .read)
    static let importer = ClientStreamMethod<BoxRequest, StreamElement, StreamSummary>(
        name: "box.import", access: .write)
    static let pipe = BidirectionalStreamMethod<
        BoxRequest, StreamElement, StreamElement, StreamSummary
    >(
        name: "box.pipe", access: .write)
}

func entity(_ raw: String) -> EntityName {
    try! EntityName.parse(raw).get()
}

func boxRequest(_ value: UInt8) -> BoxRequest {
    BoxRequest(value: value)
}

// MARK: - Byte helpers

func framed(_ payload: ByteBuffer) -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt32(payload.readableBytes), endianness: .little)
    buffer.writeImmutableBuffer(payload)
    return buffer
}

func framed(_ payload: [UInt8]) -> ByteBuffer {
    framed(ByteBuffer(bytes: payload))
}

func helloFrame(_ hello: MMHello) -> ByteBuffer {
    framed(try! hello.encode().get())
}

func allBytes(_ buffer: ByteBuffer) -> [UInt8] {
    Array(buffer.readableBytesView)
}

func encodedParams<T: Encodable>(_ value: T) -> ByteBuffer {
    try! MMPackEncoder().encode(value).get()
}

/// Strips the 4-byte LE length prefix and decodes the envelope.
func decodeFrame(_ frame: ByteBuffer) throws -> MMEnvelope {
    var copy = frame
    guard
        let length = copy.readInteger(endianness: .little, as: UInt32.self),
        let payload = copy.readSlice(length: Int(length)),
        copy.readableBytes == 0
    else {
        throw MMWireError.truncated
    }
    return try MMEnvelope.decode(from: payload).get()
}

func requestParts(of frame: ByteBuffer) throws -> (
    msgid: UInt32, method: String, params: ByteBuffer
) {
    guard case .request(let msgid, let method, _, let params) = try decodeFrame(frame) else {
        throw MMWireError.unknownEnvelope
    }
    return (msgid, method, params)
}

// MARK: - Stream frame helpers (inbound = server → client)

/// A framed stream item `[3, msgid, seq, item]` carrying a `StreamElement`.
func itemFrame(msgid: UInt32, seq: UInt32, value: Int) -> ByteBuffer {
    framed(
        try! MMEnvelope.item(
            msgid: msgid, seq: seq, item: encodedParams(StreamElement(value: value))
        ).encoded().get()
    )
}

/// A framed inbound END `[4, msgid, 0]`.
func endFrame(msgid: UInt32) -> ByteBuffer {
    framed(try! MMEnvelope.end(msgid: msgid).encoded().get())
}

/// A framed inbound STOP `[5, msgid, code]`.
func stopFrame(msgid: UInt32, code: UInt32 = 0) -> ByteBuffer {
    framed(try! MMEnvelope.stop(msgid: msgid, code: code).encoded().get())
}

/// A framed inbound credit grant `[2, msgid, credits]`.
func creditFrame(msgid: UInt32, credits: UInt32) -> ByteBuffer {
    framed(try! MMEnvelope.credit(msgid: msgid, credits: credits).encoded().get())
}

/// A framed nil-error terminal `[0, msgid, nil, summary]`.
func summaryTerminalFrame(msgid: UInt32, count: Int) -> ByteBuffer {
    framed(
        try! MMEnvelope.response(
            msgid: msgid, error: nil, result: encodedParams(StreamSummary(count: count))
        ).encoded().get()
    )
}

/// Reads the next outbound frame and decodes it as an envelope of any kind.
func readOutboundEnvelope(_ client: ConnectedClient) async throws -> MMEnvelope {
    let frame = try await withDeadline {
        try await client.channel.waitForOutboundWrite(as: ByteBuffer.self)
    }
    return try decodeFrame(frame)
}

func responseFrame(msgid: UInt32, result: some Encodable) -> ByteBuffer {
    framed(
        try! MMEnvelope.response(msgid: msgid, error: nil, result: encodedParams(result))
            .encoded().get()
    )
}

func errorFrame(msgid: UInt32, _ errorObject: MMErrorObject) -> ByteBuffer {
    framed(try! MMEnvelope.response(msgid: msgid, error: errorObject, result: nil).encoded().get())
}

func quietLogger() -> Logger {
    var logger = Logger(label: "mm.test.client")
    logger.logLevel = .error
    return logger
}

// MARK: - Client harness over NIOAsyncTestingChannel

/// A client pipeline assembled on a `NIOAsyncTestingChannel` — identical
/// handler stack to a real connect (via `configurePipeline`) but driven
/// deterministically: tests write inbound frames and read outbound frames as
/// raw framed bytes. The server hello has not been fed yet.
struct PendingHarness {
    let loop: NIOAsyncTestingEventLoop
    let channel: NIOAsyncTestingChannel
    let wrapped: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    let serverHello: EventLoopFuture<MMHello>
    /// The client's first outbound frame (its hello), already captured — proof
    /// the client speaks first, and available for exact byte assertions.
    let clientHelloFrame: ByteBuffer
}

func connectPipeline(
    configuration: MMClientConfiguration = MMClientConfiguration()
) async throws -> PendingHarness {
    let loop = NIOAsyncTestingEventLoop()
    let channel = NIOAsyncTestingChannel(loop: loop)
    let helloPromise = loop.makePromise(of: MMHello.self)
    let wrapped = try await loop.executeInContext {
        try MMClientConnection.configurePipeline(
            channel: channel,
            configuration: configuration,
            helloPromise: helloPromise
        )
    }
    try await channel.connect(to: SocketAddress(unixDomainSocketPath: "/mm-client-test")).get()
    // No inbound has been written: whatever comes out first was sent first.
    let clientHelloFrame = try await withDeadline {
        try await channel.waitForOutboundWrite(as: ByteBuffer.self)
    }
    return PendingHarness(
        loop: loop,
        channel: channel,
        wrapped: wrapped,
        serverHello: helloPromise.futureResult,
        clientHelloFrame: clientHelloFrame
    )
}

/// Tears down a harness whose channel never got a `run()`: finishes the
/// wrapped writer via the scoped teardown so nothing trips NIOAsyncWriter's
/// deinit precondition.
func discard(_ harness: PendingHarness) async {
    try? await harness.wrapped.executeThenClose { _, _ in }
}

func establish(
    _ harness: PendingHarness,
    configuration: MMClientConfiguration = MMClientConfiguration()
) async -> Result<MMClientConnection, MMClientError> {
    await MMClientConnection.establish(
        channel: harness.wrapped,
        serverHello: harness.serverHello,
        configuration: configuration,
        logger: quietLogger()
    )
}

struct ConnectedClient: Sendable {
    let loop: NIOAsyncTestingEventLoop
    let channel: NIOAsyncTestingChannel
    let connection: MMClientConnection

    func readRequestFrame() async throws -> (msgid: UInt32, method: String, params: ByteBuffer) {
        let frame = try await withDeadline {
            try await self.channel.waitForOutboundWrite(as: ByteBuffer.self)
        }
        return try requestParts(of: frame)
    }
}

/// Flips the testing channel to unwritable and propagates the writability
/// event on the loop, so the `NIOAsyncChannel` outbound writer suspends
/// subsequent writes (outbound backpressure).
func makeUnwritable(_ client: ConnectedClient) async throws {
    client.channel.isWritable = false
    try await client.loop.executeInContext {
        client.channel.pipeline.fireChannelWritabilityChanged()
    }
}

/// Connects a client over a testing channel (default server hello: version 1,
/// fingerprint 0), runs `run()` as a structured child, executes `body`, closes
/// the connection, joins the loop task, and returns both results.
func withRunningConnection<T: Sendable>(
    configuration: MMClientConfiguration = MMClientConfiguration(),
    serverHello: MMHello = MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0),
    _ body: @escaping @Sendable (ConnectedClient) async throws -> T
) async throws -> (result: T, runResult: Result<Void, MMClientError>) {
    let harness = try await connectPipeline(configuration: configuration)
    try await harness.channel.writeInbound(helloFrame(serverHello))
    let connection = try await establish(harness, configuration: configuration).get()
    let client = ConnectedClient(
        loop: harness.loop,
        channel: harness.channel,
        connection: connection
    )
    let runResult = NIOLockedValueBox<Result<Void, MMClientError>?>(nil)
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            let result = await connection.run()
            runResult.withLockedValue { $0 = result }
        }
        // A sibling deadline bounds the run() join: if the loop fails to
        // observe the close, the group throws instead of hanging the test.
        group.addTask {
            try await Task.sleep(for: .seconds(15), tolerance: nil, clock: ContinuousClock())
            throw DeadlineExceeded()
        }
        let result: T
        do {
            result = try await withDeadline { try await body(client) }
        } catch {
            await connection.close()
            group.cancelAll()
            try? await group.waitForAll()
            throw error
        }
        await connection.close()
        _ = try await group.next()  // run() finished, or DeadlineExceeded
        group.cancelAll()  // stop the deadline child
        try? await group.waitForAll()  // its CancellationError is expected
        guard let finished = runResult.withLockedValue({ $0 }) else {
            throw DeadlineExceeded()
        }
        return (result, finished)
    }
}

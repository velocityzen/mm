// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif
    import HegelTesting
    import Logging
    import MMSchema
    import MMTestSupport
    import MMWire
    import NIOCore
    import NIOEmbedded
    import Testing

    @testable import MMClient

    /// A transport error as NIO or the wire layer reports it, drawn as data
    /// so a case prints and shrinks; ``error`` builds the real value.
    enum TransportErrorShape: Sendable, Hashable {
        case io(errorNumber: Int32)
        case pathTooLong
        case unsupportedAddress
        case unparsableAddress(String)
        case connectTimeout(nanoseconds: Int64)
        case channelClosed
        case endOfFile
        case wire(MMWireError)
        case opaque

        struct Opaque: Error {}

        var error: any Error {
            switch self {
                case .io(let errorNumber):
                    return IOError(errnoCode: errorNumber, reason: "connect")
                case .pathTooLong:
                    return SocketAddressError.unixDomainSocketPathTooLong
                case .unsupportedAddress:
                    return SocketAddressError.unsupported
                case .unparsableAddress(let text):
                    return SocketAddressError.failedToParseIPString(text)
                case .connectTimeout(let nanoseconds):
                    return ChannelError.connectTimeout(.nanoseconds(nanoseconds))
                case .channelClosed:
                    return ChannelError.ioOnClosedChannel
                case .endOfFile:
                    return ChannelError.eof
                case .wire(let error):
                    return error
                case .opaque:
                    return Opaque()
            }
        }

        /// The cause a failed connect names, by the table the
        /// documentation of ``MMTransportCause`` gives.
        var connectCause: MMTransportCause {
            switch self {
                case .io(let errorNumber):
                    let named: [Int32: MMTransportCause] = [
                        ECONNREFUSED: .refused, ENOENT: .socketMissing, ENOTDIR: .socketMissing,
                        EACCES: .permissionDenied, EPERM: .permissionDenied, ETIMEDOUT: .timedOut,
                    ]
                    return named[errorNumber] ?? .other(errorNumber: errorNumber)
                case .pathTooLong, .unsupportedAddress, .unparsableAddress:
                    return .invalidAddress
                case .connectTimeout:
                    return .timedOut
                case .channelClosed, .endOfFile, .wire, .opaque:
                    return .other(errorNumber: nil)
            }
        }

        /// Whether a connect that failed this way can work on a later try:
        /// only a denied permission and an address that can never work are
        /// final, and nothing calls for an immediate retry.
        var connectHint: MMRetryHint {
            switch self {
                case .io(let errorNumber) where errorNumber == EACCES || errorNumber == EPERM:
                    return .never
                case .pathTooLong, .unsupportedAddress, .unparsableAddress:
                    return .never
                default:
                    return .later
            }
        }

        /// Whether the error ending an established connection is the
        /// oversized-frame refusal, the one failure there that a new
        /// connection meets again.
        var isOversizedFrame: Bool {
            if case .wire(.frameTooLarge) = self { return true }
            return false
        }
    }

    enum RetryHintGenerators {
        /// errno values with a cause of their own; others a connect or a
        /// read can report, and the edges of the domain; and any value.
        static let errorNumbers: Gen<Int32> = .oneOf(
            .element(of: [ECONNREFUSED, ENOENT, ENOTDIR, EACCES, EPERM, ETIMEDOUT]),
            .element(of: [
                ECONNRESET, EPIPE, EBADF, EINTR, ENETUNREACH, EHOSTUNREACH, 0, -1, .min, .max,
            ]),
            .integer()
        )

        static let wireErrors: Gen<MMWireError> = Gen { tc in
            switch try tc.draw(.int(in: 0...4)) {
                case 0, 1:
                    return .frameTooLarge(
                        length: try tc.draw(.integer()),
                        limit: try tc.draw(.integer())
                    )
                case 2: return .truncated
                case 3: return .badMatter
                default: return .invalidFormat(byte: try tc.draw(.integer()))
            }
        }

        static let shapes: Gen<TransportErrorShape> = Gen { tc in
            switch try tc.draw(.int(in: 0...10)) {
                case 0...3:
                    return .io(errorNumber: try tc.draw(errorNumbers))
                case 4: return .pathTooLong
                case 5: return .unsupportedAddress
                case 6: return .unparsableAddress(try tc.draw(.string(count: 0...8)))
                case 7: return .connectTimeout(nanoseconds: try tc.draw(.integer()))
                case 8: return try tc.draw(.element(of: [.channelClosed, .endOfFile, .opaque]))
                default: return .wire(try tc.draw(wireErrors))
            }
        }
    }

    @Suite("Retry hint properties", .hegel)
    struct RetryHintProperties {
        /// A failed connect names the cause its error's errno or type
        /// gives, and its hint is final only for a denied permission or an
        /// address that can never work. An error ending an established
        /// connection is the connection lost, hinting an immediate retry,
        /// except an oversized frame, which is final.
        ///
        /// Mutation check: EPERM left out of permission denied, a refusal
        /// hinting now, an oversized frame read as lost, fails here.
        @Test
        func failuresHintByTheirCause() throws {
            try property(
                reaching: ["an errno"],
                reachingAfter: [
                    "a named errno": 1_000, "an address that can never work": 1_000,
                    "an oversized frame": 1_000,
                ]
            ) { tc in
                let shape = try tc.draw(RetryHintGenerators.shapes, named: "error")
                let error = shape.error
                if case .io(let errorNumber) = shape {
                    try tc.event("an errno")
                    if shape.connectCause != .other(errorNumber: errorNumber) {
                        try tc.event("a named errno")
                    }
                }
                if shape.connectCause == .invalidAddress {
                    try tc.event("an address that can never work")
                }
                if shape.isOversizedFrame { try tc.event("an oversized frame") }

                let connectCause = MMTransportCause.connectFailure(error)
                #expect(connectCause == shape.connectCause)
                let connectFailure = MMClientError.transport(
                    cause: connectCause,
                    description: String(describing: error)
                )
                #expect(connectFailure.retryHint == shape.connectHint)

                let loopCause = MMTransportCause.connectionFailure(error)
                #expect(loopCause == (shape.isOversizedFrame ? .oversizedFrame : .lost))
                let loopFailure = MMClientError.transport(
                    cause: loopCause,
                    description: String(describing: error)
                )
                #expect(loopFailure.retryHint == (shape.isOversizedFrame ? .never : .now))
            }
        }

        /// A TCP connect that tried several addresses names the cause of
        /// the first failure that has one of its own, else the first
        /// failure's, else no errno at all when no address was tried.
        ///
        /// Mutation check: the last known cause taken, or the first failure
        /// taken whatever it is, fails here.
        @Test
        func severalAddressesNameTheFirstKnownCause() throws {
            try property(
                reaching: ["the first is known"],
                reachingAfter: [
                    "a known cause after another": 1_000, "no address tried": 1_000,
                    "no known cause": 1_000,
                ]
            ) { tc in
                let shapes = try tc.draw(
                    .array(of: RetryHintGenerators.shapes, count: 0...4),
                    named: "failures"
                )
                let known = shapes.first { shape in
                    if case .other = shape.connectCause { return false }
                    return true
                }
                switch (shapes.first, known) {
                    case (nil, _): try tc.event("no address tried")
                    case (_, nil): try tc.event("no known cause")
                    case (let first?, let known?) where first == known:
                        try tc.event("the first is known")
                    default: try tc.event("a known cause after another")
                }
                let expected =
                    known?.connectCause ?? shapes.first?.connectCause ?? .other(errorNumber: nil)
                #expect(MMTransportCause.firstKnown(shapes.map(\.error)) == expected)
            }
        }

        /// The hint of every client error: a transport failure's comes from
        /// its cause, and a bad hello, an unsupported version and a
        /// protocol violation never connect again.
        ///
        /// Mutation check: a protocol violation hinting later, a lost
        /// connection hinting later, fails here.
        @Test
        func clientErrorsHintByTheirKind() throws {
            try property(reaching: ["a transport failure"]) { tc in
                let causes: Gen<MMTransportCause> = .oneOf(
                    .element(of: [
                        .refused, .socketMissing, .permissionDenied, .invalidAddress, .timedOut,
                        .closedBeforeHello, .lost, .oversizedFrame,
                    ]),
                    Gen<Int32?>.optional(RetryHintGenerators.errorNumbers).map {
                        .other(errorNumber: $0)
                    }
                )
                let error: MMClientError
                switch try tc.draw(.int(in: 0...4), named: "kind") {
                    case 0: error = .badHello
                    case 1: error = .versionUnsupported(serverVersion: try tc.draw(.integer()))
                    case 2: error = .protocolViolation(description: "frame")
                    default:
                        error = .transport(cause: try tc.draw(causes), description: "failure")
                        try tc.event("a transport failure")
                }
                tc.note("error: \(error)")
                let expected: MMRetryHint
                switch error {
                    case .transport(.lost, _):
                        expected = .now
                    case .transport(.permissionDenied, _), .transport(.invalidAddress, _),
                        .transport(.oversizedFrame, _):
                        expected = .never
                    case .transport:
                        expected = .later
                    case .badHello, .versionUnsupported, .protocolViolation:
                        expected = .never
                }
                #expect(error.retryHint == expected)
            }
        }
    }

    /// How a drawn connection ends.
    enum CloseEvent: Sendable, Hashable, CaseIterable {
        /// The server closed the connection (EOF).
        case peerClosed
        /// This client's idle timeout reaped it.
        case idleTimeout
        /// The application called `close()` while the loop ran.
        case closedByApplication
        /// The application called `close()` before the loop ever ran.
        case closedBeforeRun
        /// The task running the loop was cancelled.
        case loopCancelled
        /// The server sent a frame longer than the client's limit.
        case oversizedFrame
        /// The server sent a frame that is not an envelope.
        case undecodableEnvelope
        /// The transport failed underneath the loop.
        case transportFailed

        /// The close state the event leaves, as reason kind and hint.
        var expected: CloseModel {
            switch self {
                case .peerClosed, .idleTimeout:
                    return CloseModel(reason: .clean, retry: .now)
                case .closedByApplication, .closedBeforeRun, .loopCancelled:
                    return CloseModel(reason: .clean, retry: .never)
                case .oversizedFrame:
                    return CloseModel(reason: .transport(.oversizedFrame), retry: .never)
                case .undecodableEnvelope:
                    return CloseModel(reason: .protocolViolation, retry: .never)
                case .transportFailed:
                    return CloseModel(reason: .transport(.lost), retry: .now)
            }
        }
    }

    /// A close state with the transport description dropped.
    struct CloseModel: Sendable, Hashable {
        enum Reason: Sendable, Hashable {
            case clean
            case badHello
            case versionUnsupported
            case protocolViolation
            case transport(MMTransportCause)
        }

        var reason: Reason
        var retry: MMRetryHint

        init(reason: Reason, retry: MMRetryHint) {
            self.reason = reason
            self.retry = retry
        }

        init?(_ state: ClientState) {
            guard case .closed(let reason, let retry) = state else { return nil }
            self.init(reason: Self.reason(of: reason), retry: retry)
        }

        static func reason(of error: MMClientError?) -> Reason {
            switch error {
                case nil: return .clean
                case .badHello: return .badHello
                case .versionUnsupported: return .versionUnsupported
                case .protocolViolation: return .protocolViolation
                case .transport(let cause, _): return .transport(cause)
            }
        }
    }

    @Suite("Close state properties", .hegel)
    struct CloseStateProperties {
        /// Every close of an established connection carries the hint of
        /// what ended it: the server's close and the idle timeout hint an
        /// immediate retry, a close the application asked for hints none,
        /// an oversized frame and a protocol violation are final, and a
        /// transport failure is the connection lost. The state, a state
        /// subscriber's last value and the loop's result agree, and a later
        /// close changes none of them.
        ///
        /// Mutation check: a requested close left unrecorded, a cancelled
        /// loop read as the server's close, a clean close always hinting
        /// now, a loop failure left unclassified, fails here.
        @Test
        func everyCloseCarriesTheHintOfWhatEndedIt() async throws {
            try await property(
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: CloseEvent.allCases.map { ("\($0)", 1_000) }
                )
            ) { tc in
                let event = try tc.draw(.element(of: CloseEvent.allCases), named: "event")
                let subscribesFirst = try tc.draw(.bool(), named: "subscribes first")
                let closesAgain = try tc.draw(.bool(), named: "closes again")
                let errorNumber = try tc.draw(RetryHintGenerators.errorNumbers, named: "errno")
                try tc.event("\(event)")

                let configuration = MMClientConfiguration(
                    maxFrameLength: 64,
                    // Long enough that only the event's own idle signal reaps.
                    idleTimeout: event == .idleTimeout ? .hours(1) : nil
                )
                let pipeline = try await ClosePipeline.open(configuration: configuration)
                let connection = pipeline.connection
                let states = subscribesFirst ? connection.stateUpdates() : nil

                let run: Result<Void, MMClientError>
                if event == .closedBeforeRun {
                    await connection.close()
                    run = await connection.run()
                } else {
                    let loop = Task { await connection.run() }
                    try await pipeline.end(with: event, errorNumber: errorNumber, loop: loop)
                    run = try await withDeadline { await loop.value }
                }
                let closed = CloseModel(connection.state)
                #expect(closed == event.expected)
                switch run {
                    case .success: #expect(event.expected.reason == .clean)
                    case .failure(let error):
                        #expect(CloseModel.reason(of: error) == event.expected.reason)
                }

                if closesAgain {
                    await connection.close()
                    #expect(CloseModel(connection.state) == closed)
                }
                let observed = try await withDeadline { () -> [ClientState] in
                    var seen: [ClientState] = []
                    for await state in states ?? connection.stateUpdates() {
                        seen.append(state)
                    }
                    return seen
                }
                #expect(observed.last.flatMap { CloseModel($0) } == event.expected)
            }
        }
    }

    /// An established connection on a testing channel, which the property
    /// ends the way a drawn event says.
    struct ClosePipeline {
        let loop: NIOAsyncTestingEventLoop
        let channel: NIOAsyncTestingChannel
        let connection: MMClientConnection

        static func open(configuration: MMClientConfiguration) async throws -> ClosePipeline {
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
            try await channel.connect(to: SocketAddress(unixDomainSocketPath: "/mm-close")).get()
            _ = try await withDeadline {
                try await channel.waitForOutboundWrite(as: ByteBuffer.self)
            }
            let hello = try MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0)
                .encode().get()
            try await channel.writeInbound(Self.framed(hello))
            let connection = try await MMClientConnection.establish(
                channel: wrapped,
                serverHello: helloPromise.futureResult,
                configuration: configuration,
                logger: Logger(
                    label: "mm.property.close",
                    factory: { _ in SwiftLogNoOpLogHandler() }
                )
            ).get()
            return ClosePipeline(loop: loop, channel: channel, connection: connection)
        }

        static func framed(_ payload: ByteBuffer) -> ByteBuffer {
            var buffer = ByteBuffer()
            buffer.writeInteger(UInt32(payload.readableBytes), endianness: .little)
            buffer.writeImmutableBuffer(payload)
            return buffer
        }

        func end(
            with event: CloseEvent,
            errorNumber: Int32,
            loop runLoop: Task<Result<Void, MMClientError>, Never>
        ) async throws {
            switch event {
                case .peerClosed:
                    try await self.channel.close()
                case .idleTimeout:
                    // The idle signal the timeout raises; it reads the real
                    // clock, so the testing loop's time can't raise it.
                    let channel = self.channel
                    try await self.loop.executeInContext {
                        channel.pipeline.fireUserInboundEventTriggered(
                            IdleStateHandler.IdleStateEvent.all
                        )
                    }
                case .closedByApplication:
                    // A call reaches the wire only through the running
                    // loop's writer, so once its request is out the close
                    // takes the running loop's path; it ends the call.
                    let connection = self.connection
                    let call = Task {
                        await connection.call(
                            methodName: "probe.wait",
                            entity: try EntityName.parse("probe").get(),
                            encodeRequest: { MMPackEncoder().encode(0) }
                        )
                    }
                    _ = try await withDeadline {
                        try await self.channel.waitForOutboundWrite(as: ByteBuffer.self)
                    }
                    await connection.close()
                    let outcome = try await withDeadline { try await call.value }
                    guard case .failure(.connectionClosed) = outcome else {
                        Issue.record("the call ended \(outcome)")
                        return
                    }
                case .closedBeforeRun:
                    preconditionFailure("closed before the loop starts")
                case .loopCancelled:
                    runLoop.cancel()
                case .oversizedFrame:
                    var oversized = ByteBuffer()
                    oversized.writeInteger(UInt32(1_000_000), endianness: .little)
                    // The testing channel also rethrows the decoder's error.
                    _ = try? await self.channel.writeInbound(oversized)
                case .undecodableEnvelope:
                    // 0xc1 is the reserved MessagePack byte: never an envelope.
                    try await self.channel.writeInbound(Self.framed(ByteBuffer(bytes: [0xc1])))
                case .transportFailed:
                    let channel = self.channel
                    try await self.loop.executeInContext {
                        channel.pipeline.fireErrorCaught(
                            IOError(errnoCode: errorNumber, reason: "read")
                        )
                    }
            }
        }
    }

#endif

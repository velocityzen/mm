// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import Logging
    import MMClient
    import MMSchema
    import MMServer
    import MMTestSupport
    import MMWire
    import NIOConcurrencyHelpers
    import NIOCore
    import Testing

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif

    // MARK: - Fixtures

    /// What the fixtures' own MessagePack code refuses: a negative number
    /// when it writes one, an odd number when it reads one, and a string
    /// that holds no number.
    enum OwnCodeRefusal: Error, Equatable {
        case negative(Int)
        case odd(Int)
        case notANumber(String)
    }

    /// Writes `number` the fixtures' own way, as its digits in a string,
    /// and refuses a negative number.
    func writeOwnCoded<Writer: MMPackWriter>(_ number: Int, to writer: inout Writer) throws {
        guard number >= 0 else { throw OwnCodeRefusal.negative(number) }
        writer.writeString(String(number))
    }

    /// Reads a number written the fixtures' own way, and refuses an odd one.
    func readOwnCoded<Reader: MMPackReader>(from reader: inout Reader) throws -> Int {
        let number = try readDigits(from: &reader)
        guard number.isMultiple(of: 2) else { throw OwnCodeRefusal.odd(number) }
        return number
    }

    /// Reads a number's digits from a string.
    func readDigits<Reader: MMPackReader>(from reader: inout Reader) throws -> Int {
        let text = try reader.readString()
        guard let number = Int(text) else { throw OwnCodeRefusal.notANumber(text) }
        return number
    }

    /// A number with MessagePack code of its own. Generated code writes the
    /// bytes `Codable` writes; this code writes the number's digits as a
    /// string, where `Codable` writes a map. So a test can tell from the
    /// bytes which of the two a coder picked, and from a failure too: the
    /// own code refuses what ``OwnCodeRefusal`` lists. The protocols are
    /// public, so a hand-written conformance like this one is legal.
    struct OwnCodedNumber: Codable, Hashable, Sendable, MMPackCodable, NumberFixture {
        var number: Int

        init(number: Int) {
            self.number = number
        }

        init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {
            self.number = try readOwnCoded(from: &reader)
        }

        func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {
            try writeOwnCoded(self.number, to: &writer)
        }
    }

    /// ``OwnCodedNumber`` with `Codable` alone.
    struct CodableNumber: Codable, Hashable, Sendable, NumberFixture {
        var number: Int
    }

    /// A request with MessagePack code of its own: an array of two strings,
    /// `number` by the fixtures' rules, then the `reply` the server answers
    /// with, which has no rules.
    struct OwnCodedRequest: Codable, Hashable, Sendable, MMPackCodable, RequestFixture {
        var number: Int
        var reply: Int

        init(number: Int, reply: Int) {
            self.number = number
            self.reply = reply
        }

        init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {
            let count = try reader.readArrayHeader(depth: depth)
            guard count == 2 else { throw MMWireError.invalidArity(expected: 2, got: count) }
            self.number = try readOwnCoded(from: &reader)
            self.reply = try readDigits(from: &reader)
        }

        func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {
            writer.writeArrayHeader(count: 2)
            try writeOwnCoded(self.number, to: &writer)
            writer.writeString(String(self.reply))
        }
    }

    /// ``OwnCodedRequest`` with `Codable` alone.
    struct CodableRequest: Codable, Hashable, Sendable, RequestFixture {
        var number: Int
        var reply: Int
    }

    /// A number fixture, own-coded or not, for the code the two kinds share.
    protocol NumberFixture: Codable, Hashable, Sendable {
        init(number: Int)
        var number: Int { get }
    }

    /// A request fixture, own-coded or not: `number` for the request's own
    /// rules, and the number the server replies with.
    protocol RequestFixture: Codable, Hashable, Sendable {
        init(number: Int, reply: Int)
        var reply: Int { get }
    }

    /// Any number, often one at a boundary of the fixtures' rules or of
    /// `Int`.
    let fixtureNumbers: Gen<Int> = .oneOf(
        .int(),
        .element(of: [0, 1, -1, 2, -2, .max, .min])
    )

    /// Any even number: one the fixtures' own code reads, if it could write
    /// it.
    let evenFixtureNumbers: Gen<Int> = fixtureNumbers.map { $0 & ~1 }

    /// Any number, often one the fixtures' own code both writes and reads:
    /// even and not negative.
    let oftenReadableFixtureNumbers: Gen<Int> = .oneOf(
        fixtureNumbers,
        evenFixtureNumbers.map { $0 & .max }
    )

    /// A type's coders called directly, not picked: its own code, or
    /// `Codable`. The oracle every pick is checked against.
    struct DirectCoders<Value: Sendable>: Sendable {
        let encode: @Sendable (Value) -> Result<ByteBuffer, MMWireError>
        let decode: @Sendable (ByteBuffer) -> Result<Value, MMWireError>
    }

    extension DirectCoders where Value: MMPackCodable {
        /// The type's own code.
        static var ownCode: Self {
            Self(
                encode: { encodedThroughGeneratedCode($0) },
                decode: { decodedThroughGeneratedCode(Value.self, from: $0) }
            )
        }
    }

    extension DirectCoders where Value: Codable {
        /// The type's `Codable` conformance.
        static var codable: Self {
            Self(
                encode: { encodedThroughCodable($0) },
                decode: { decodedThroughCodable(Value.self, from: $0) }
            )
        }
    }

    // MARK: - Picking a coder

    /// The two ways the coders pick a type's code: a check on every value,
    /// or once for the type, returning a coder.
    enum Pick: String, CaseIterable, Sendable {
        case checkPerValue = "a check per value"
        case resolvedOnce = "a coder resolved once"
    }

    /// Encodes `value` with the coder `pick` picks.
    func encoded<Value: Encodable & SendableMetatype>(
        _ value: Value,
        by pick: Pick
    ) -> Result<ByteBuffer, MMWireError> {
        switch pick {
            case .checkPerValue: MMPackEncoder().encodeCheckingForGeneratedCode(value)
            case .resolvedOnce: MMPackEncoder().encoding(Value.self)(value)
        }
    }

    /// Decodes `bytes` as `type` with the coder `pick` picks.
    func decoded<Value: Decodable & SendableMetatype>(
        _ type: Value.Type,
        from bytes: ByteBuffer,
        by pick: Pick
    ) -> Result<Value, MMWireError> {
        switch pick {
            case .checkPerValue: MMPackDecoder().decodeCheckingForGeneratedCode(type, from: bytes)
            case .resolvedOnce: MMPackDecoder().decoding(type)(bytes)
        }
    }

    /// ``encoded(_:by:)``, never specialized or inlined: it runs as it does
    /// for a caller that doesn't know the type, with the check for generated
    /// code made at run time. A call from a concrete type, specialized in an
    /// optimized build, makes the check at compile time.
    @inline(never)
    @_semantics("optimize.sil.specialize.generic.never")
    func encodedUnspecialized<Value: Encodable & SendableMetatype>(
        _ value: Value,
        by pick: Pick
    ) -> Result<ByteBuffer, MMWireError> {
        encoded(value, by: pick)
    }

    /// ``decoded(_:from:by:)``, never specialized or inlined; see
    /// ``encodedUnspecialized(_:by:)``.
    @inline(never)
    @_semantics("optimize.sil.specialize.generic.never")
    func decodedUnspecialized<Value: Decodable & SendableMetatype>(
        _ type: Value.Type,
        from bytes: ByteBuffer,
        by pick: Pick
    ) -> Result<Value, MMWireError> {
        decoded(type, from: bytes, by: pick)
    }

    /// The types the pick property draws: own-coded or not, alone, optional,
    /// in an array, which has no generated code, and in a request.
    enum PickedType: String, CaseIterable, Sendable {
        case ownCodedNumber = "an own-coded number"
        case codableNumber = "a Codable number"
        case optionalOwnCodedNumber = "an optional own-coded number"
        case optionalCodableNumber = "an optional Codable number"
        case arrayOfOwnCodedNumbers = "an array of own-coded numbers"
        case ownCodedRequest = "an own-coded request"
        case codableRequest = "a Codable request"
    }

    /// Where the bytes a pick decodes come from: what the direct coder or
    /// `Codable` wrote, or either one changed.
    enum DecodedBytes: String, CaseIterable, Sendable {
        case written = "bytes the direct coder wrote"
        case writtenByCodable = "bytes Codable wrote"
        case changed = "changed bytes"
    }

    /// An encode's outcome as a constant label for the statistics report.
    func writeOutcome(_ result: Result<ByteBuffer, MMWireError>) -> String {
        switch result {
            case .success: "written"
            case .failure(let error):
                "refused to write with \(String(describing: error).prefix { $0 != "(" })"
        }
    }

    /// Draws a value from `values` and checks every pick of its coder,
    /// specialized and not, against `direct`: the same bytes or the same
    /// failure for the value, and the same value or the same failure for
    /// bytes the direct coder or `Codable` wrote, changed or not.
    func expectPicksAgree<Value: Codable & Sendable & Equatable>(
        _ values: Gen<Value>,
        direct: DirectCoders<Value>,
        in tc: TestCase
    ) throws {
        let value = try #draw(values, from: tc)
        let written = direct.encode(value)
        try tc.event(writeOutcome(written))
        for pick in Pick.allCases {
            #expect(encoded(value, by: pick) == written, "\(pick.rawValue)")
            #expect(
                encodedUnspecialized(value, by: pick) == written,
                "\(pick.rawValue), unspecialized"
            )
        }

        // Often the bytes the direct coder wrote: the own code's refusal to
        // read an odd number shows only on bytes it wrote.
        let source = try #draw(
            .oneOf(.element(of: [DecodedBytes.written]), .element(of: DecodedBytes.allCases)),
            from: tc
        )
        try tc.event(source.rawValue)
        let codableBytes = try encodedThroughCodable(value).get()
        let bytes: ByteBuffer
        switch (source, written) {
            case (.written, .success(let directBytes)):
                bytes = directBytes
            case (.written, .failure), (.writtenByCodable, _):
                bytes = codableBytes
            case (.changed, _):
                let original = try #draw(
                    .element(of: [(try? written.get()) ?? codableBytes, codableBytes]),
                    from: tc
                )
                let changes = try #draw(mutations, from: tc)
                bytes = ByteBuffer(bytes: mutated(Array(original.readableBytesView), by: changes))
        }
        let read = direct.decode(bytes)
        try tc.event(outcome(read))
        for pick in Pick.allCases {
            #expect(decoded(Value.self, from: bytes, by: pick) == read, "\(pick.rawValue)")
            #expect(
                decodedUnspecialized(Value.self, from: bytes, by: pick) == read,
                "\(pick.rawValue), unspecialized"
            )
        }
    }

    @Suite("The coders pick a type's own MessagePack code", .hegel, .offTheCooperativePool)
    struct CoderPickProperties {
        /// Each way of picking a type's coder, a check per value or a coder
        /// resolved once, and each called where the type is concrete or not,
        /// picks the type's own code when it has some and `Codable` when it
        /// has none: it writes what that code writes, reads what it reads,
        /// and fails where it fails, with its error.
        ///
        /// Mutation-checked: each of the four pick functions made to pick
        /// `Codable` always fails this every time.
        @Test
        func everyPickUsesTheTypesOwnCode() throws {
            try property(
                reaching: ["bytes the direct coder wrote", "decoded", "written"],
                reachingAfter: [
                    "a Codable number": 1_000,
                    "a Codable request": 1_000,
                    "an array of own-coded numbers": 1_000,
                    "an optional Codable number": 1_000,
                    "an optional own-coded number": 1_000,
                    "an own-coded number": 1_000,
                    "an own-coded request": 1_000,
                    "bytes Codable wrote": 1_000,
                    "changed bytes": 1_000,
                    "failed with decodingFailed": 1_000,
                    "failed with keyNotFound": 1_000,
                    "failed with typeMismatch": 1_000,
                    "refused to write with encodingFailed": 1_000,
                ]
            ) { tc in
                let type = try #draw(.element(of: PickedType.allCases), from: tc)
                try tc.event(type.rawValue)
                let ownCodedNumbers = fixtureNumbers.map(OwnCodedNumber.init(number:))
                let codableNumbers = fixtureNumbers.map(CodableNumber.init(number:))
                switch type {
                    case .ownCodedNumber:
                        try expectPicksAgree(ownCodedNumbers, direct: .ownCode, in: tc)
                    case .codableNumber:
                        try expectPicksAgree(codableNumbers, direct: .codable, in: tc)
                    case .optionalOwnCodedNumber:
                        try expectPicksAgree(.optional(ownCodedNumbers), direct: .ownCode, in: tc)
                    case .optionalCodableNumber:
                        try expectPicksAgree(.optional(codableNumbers), direct: .codable, in: tc)
                    case .arrayOfOwnCodedNumbers:
                        try expectPicksAgree(
                            .array(of: ownCodedNumbers, count: 0...17),
                            direct: .codable,
                            in: tc
                        )
                    case .ownCodedRequest:
                        try expectPicksAgree(
                            Hegel.zip(fixtureNumbers, fixtureNumbers).map(OwnCodedRequest.init),
                            direct: .ownCode,
                            in: tc
                        )
                    case .codableRequest:
                        try expectPicksAgree(
                            Hegel.zip(fixtureNumbers, fixtureNumbers).map(CodableRequest.init),
                            direct: .codable,
                            in: tc
                        )
                }
            }
        }
    }

    // MARK: - Calls

    /// The entity every call targets.
    let coderEntity = try! EntityName.parse("coders").get()

    /// What the stream handlers share with a test, one call at a time: the
    /// numbers the next server stream sends, and the numbers the last client
    /// stream's handler received.
    final class StreamExchange: Sendable {
        private struct State {
            var toSend: [Int] = []
            var received: [Int]?
        }

        private let state = NIOLockedValueBox(State())

        /// Sets what the next server stream sends, and forgets what the last
        /// client stream received.
        func prepare(toSend numbers: [Int]) {
            self.state.withLockedValue { $0 = State(toSend: numbers, received: nil) }
        }

        var toSend: [Int] { self.state.withLockedValue { $0.toSend } }

        var received: [Int]? {
            get { self.state.withLockedValue { $0.received } }
            set { self.state.withLockedValue { $0.received = newValue } }
        }
    }

    /// A type's name as a segment of a method name, which takes lowercase
    /// letters only.
    func methodNameSegment<Value>(_: Value.Type) -> String {
        String(describing: Value.self).lowercased()
    }

    /// The unary call from one request kind to one reply kind.
    func unaryMethod<Request: RequestFixture, Reply: NumberFixture>(
        _: Request.Type,
        _: Reply.Type
    ) -> Method<Request, Reply> {
        Method(
            name: "coders.\(methodNameSegment(Request.self)).\(methodNameSegment(Reply.self))",
            access: .read
        )
    }

    /// The stream calls for one request kind and one number kind, the
    /// number as each element and as the reply.
    struct StreamMethods<Request: RequestFixture, Element: NumberFixture>: Sendable {
        let serverStream: ServerStreamMethod<Request, Element, Element>
        let clientStream: ClientStreamMethod<Request, Element, Element>
        let bidirectional: BidirectionalStreamMethod<Request, Element, Element, Element>

        init() {
            let prefix =
                "coders.\(methodNameSegment(Request.self)).\(methodNameSegment(Element.self))"
            self.serverStream = ServerStreamMethod(name: "\(prefix).serverStream", access: .read)
            self.clientStream = ClientStreamMethod(name: "\(prefix).clientStream", access: .read)
            self.bidirectional = BidirectionalStreamMethod(
                name: "\(prefix).bidirectional",
                access: .read
            )
        }
    }

    /// The unary route: replies with the request's `reply`.
    func unaryRoute<Request: RequestFixture, Reply: NumberFixture>(
        _: Request.Type,
        _: Reply.Type
    ) -> Route {
        Handle(unaryMethod(Request.self, Reply.self)) { request, _ in
            .success(Reply(number: request.reply))
        }
    }

    /// The stream routes. The server stream sends the exchange's numbers
    /// until a send ends, the client stream records what it received in
    /// the exchange, and the bidirectional stream sends back each element
    /// it receives. Each replies with the request's `reply`.
    func streamRoutes<Request: RequestFixture, Element: NumberFixture>(
        _ methods: StreamMethods<Request, Element>,
        exchange: StreamExchange
    ) -> [Route] {
        [
            Handle(methods.serverStream) { request, sink, _ in
                for number in exchange.toSend {
                    guard case .sent = await sink.send(Element(number: number)) else { break }
                }
                return .success(Element(number: request.reply))
            },
            Handle(methods.clientStream) { request, elements, _ in
                var received: [Int] = []
                for await element in elements {
                    received.append(element.number)
                }
                exchange.received = received
                return .success(Element(number: request.reply))
            },
            Handle(methods.bidirectional) { request, elements, sink, _ in
                for await element in elements {
                    guard case .sent = await sink.send(element) else { break }
                }
                return .success(Element(number: request.reply))
            },
        ]
    }

    /// A logger that keeps the calls' expected failures out of the test log.
    func quietLogger(_ label: String) -> Logger {
        var logger = Logger(label: label)
        logger.logLevel = .critical
        return logger
    }

    /// Runs `body` with a client connected to a server, on a socket of its
    /// own, that serves every call the call properties make.
    func withCoderChoiceServer(
        _ body: @escaping @Sendable (MMClientConnection, StreamExchange) async throws -> Void
    ) async throws {
        let exchange = StreamExchange()
        try await withTempSocketPath(prefix: "mm-coders-") { path in
            let server = ServerRuntime(
                configuration: MMServerConfiguration(endpoint: .unix(path: path)),
                aclProvider: InMemoryACLProvider([
                    coderEntity: EntityACL(owner: getuid(), group: getgid(), mode: 0o700)
                ]),
                logger: quietLogger("mm.property.coders.server")
            ) {
                unaryRoute(OwnCodedRequest.self, OwnCodedNumber.self)
                unaryRoute(OwnCodedRequest.self, CodableNumber.self)
                unaryRoute(CodableRequest.self, OwnCodedNumber.self)
                unaryRoute(CodableRequest.self, CodableNumber.self)
                streamRoutes(StreamMethods<OwnCodedRequest, OwnCodedNumber>(), exchange: exchange)
                streamRoutes(StreamMethods<OwnCodedRequest, CodableNumber>(), exchange: exchange)
                streamRoutes(StreamMethods<CodableRequest, OwnCodedNumber>(), exchange: exchange)
                streamRoutes(StreamMethods<CodableRequest, CodableNumber>(), exchange: exchange)
            }
            try await withListeningServer(server, seconds: 3_600) { _ in
                let connection = try await MMClientConnection.connect(
                    to: .unix(path: path),
                    logger: quietLogger("mm.property.coders.client")
                ).get()
                _ = try await withClientRunLoop(
                    connection: connection,
                    context: exchange,
                    bodySeconds: 3_600,
                    joinSeconds: 30
                ) { exchange in
                    try await body(connection, exchange)
                }
            }
        }
    }

    /// Where a call's request fails, by its coders called directly: the
    /// client's encode, then the server's decode. `nil` when it gets
    /// through.
    func requestFailure<Request>(
        _ request: Request,
        coders: DirectCoders<Request>
    ) -> MMCallError? {
        switch coders.encode(request) {
            case .failure(let error):
                return .encode(error)
            case .success(let bytes):
                if case .failure = coders.decode(bytes) {
                    return .malformedParams(
                        MMError(code: MMErrorCode.malformedParams.code, message: "")
                    )
                }
                return nil
        }
    }

    /// `result` with the server's message on a refused read left out: what
    /// it names depends on the bytes, and these properties check only which
    /// side refused.
    func ignoringRefusalMessage<Reply>(
        _ result: Result<Reply, MMCallError>
    ) -> Result<Reply, MMCallError> {
        result.mapError { error in
            guard case .malformedParams(let object) = error else { return error }
            return .malformedParams(MMError(code: object.code, message: ""))
        }
    }

    /// What a call whose request got through returns for `reply`, by the
    /// reply's coders called directly: the server's encode, then the
    /// client's decode.
    func expectedReply<Reply: NumberFixture>(
        _ reply: Int,
        coders: DirectCoders<Reply>
    ) -> Result<Reply, MMCallError> {
        switch coders.encode(Reply(number: reply)) {
            case .failure: .failure(.remoteInternal)
            case .success(let bytes): coders.decode(bytes).mapError { .decode($0) }
        }
    }

    /// A call's outcome as a constant label for the statistics report.
    func callOutcome<Reply>(_ result: Result<Reply, MMCallError>) -> String {
        switch result {
            case .success: "replied"
            case .failure(.encode): "the client refused to write the request"
            case .failure(.malformedParams): "the server refused to read the request"
            case .failure(.remoteInternal): "the server refused to write the reply"
            case .failure(.decode): "the client refused to read the reply"
            case .failure(let error): "failed with \(error)"
        }
    }

    /// Makes one unary call with a drawn request and checks its reply
    /// against the coders called directly.
    func expectUnaryCall<Request: RequestFixture, Reply: NumberFixture>(
        request requestCoders: DirectCoders<Request>,
        reply replyCoders: DirectCoders<Reply>,
        through connection: MMClientConnection,
        in tc: TestCase
    ) async throws {
        let request = try Request(
            number: #draw(fixtureNumbers, from: tc),
            reply: #draw(fixtureNumbers, from: tc)
        )
        let expected =
            requestFailure(request, coders: requestCoders).map { .failure($0) }
            ?? expectedReply(request.reply, coders: replyCoders)
        try tc.event(callOutcome(expected))
        let method = unaryMethod(Request.self, Reply.self)
        let result = try await tc.withStallDetection(after: hangLimit) { _ in
            await connection.call(method, on: coderEntity, request)
        }
        #expect(ignoringRefusalMessage(result) == expected)
    }

    /// The stream call shapes.
    enum StreamShape: String, CaseIterable, Sendable {
        case serverStream = "a server stream"
        case clientStream = "a client stream"
        case bidirectional = "a bidirectional stream"
    }

    /// Makes one stream call of `shape` with a drawn request and drawn
    /// elements, and checks the elements each side reads and the reply
    /// against the coders called directly.
    func expectStreamCall<Request: RequestFixture, Element: NumberFixture>(
        _ shape: StreamShape,
        methods: StreamMethods<Request, Element>,
        request requestCoders: DirectCoders<Request>,
        element elementCoders: DirectCoders<Element>,
        through connection: MMClientConnection,
        exchange: StreamExchange,
        in tc: TestCase
    ) async throws {
        let request = try Request(
            number: #draw(fixtureNumbers, from: tc),
            reply: #draw(fixtureNumbers, from: tc)
        )
        let failure = requestFailure(request, coders: requestCoders)
        let expected =
            failure.map { .failure($0) } ?? expectedReply(request.reply, coders: elementCoders)
        try tc.event(callOutcome(expected))
        let window = Int(MMStreamFlowControl.initialWindow)
        // Whether an element gets past each side's encode, and what the
        // other side reads.
        let writes = { (number: Int) in elementCoders.encode(Element(number: number)) }
        let reads = { (number: Int) in try? writes(number).flatMap(elementCoders.decode).get() }

        switch shape {
            case .serverStream:
                // The server sends up to the first element it can't write,
                // and the client drops each one it can't read.
                let numbers = try #draw(
                    .array(of: oftenReadableFixtureNumbers, count: 0...window),
                    from: tc
                )
                exchange.prepare(toSend: numbers)
                let sent = numbers.prefix { (try? writes($0).get()) != nil }
                if sent.count < numbers.count {
                    try tc.event("the server refused to write an element")
                }
                let expectedElements = failure == nil ? sent.compactMap(reads) : []
                if expectedElements.count < sent.count {
                    try tc.event("the client refused to read an element")
                }
                if !expectedElements.isEmpty { try tc.event("the client read an element") }
                let (elements, result) = try await tc.withStallDetection(after: hangLimit) { _ in
                    let handle = await connection.call(
                        methods.serverStream,
                        on: coderEntity,
                        request
                    )
                    var elements: [Element] = []
                    for await element in handle {
                        elements.append(element)
                        if elements.count > numbers.count { break }
                    }
                    return (elements, await handle.result())
                }
                #expect(elements == expectedElements)
                #expect(ignoringRefusalMessage(result) == expected)

            case .clientStream, .bidirectional:
                // The client sends each element it can write; the server
                // reads every one of them, since they are even.
                let numbers = try #draw(.array(of: evenFixtureNumbers, count: 0...window), from: tc)
                exchange.prepare(toSend: [])
                let sendable = failure == nil ? numbers : []
                // Each send's outcome by name: both modules have a
                // `StreamSendOutcome`, and the client's can't be qualified.
                let expectedOutcomes = sendable.map {
                    (try? writes($0).get()) == nil ? "callEnded" : "sent"
                }
                let sent = sendable.filter { (try? writes($0).get()) != nil }
                if sent.count < sendable.count {
                    try tc.event("the client refused to write an element")
                }
                if shape == .clientStream {
                    let (outcomes, result) = try await tc.withStallDetection(after: hangLimit) {
                        _ in
                        let handle = await connection.call(
                            methods.clientStream,
                            on: coderEntity,
                            request
                        )
                        var outcomes: [String] = []
                        for number in sendable {
                            outcomes.append("\(await handle.send(Element(number: number)))")
                        }
                        if failure == nil { await handle.finish() }
                        return (outcomes, await handle.result())
                    }
                    #expect(outcomes == expectedOutcomes)
                    #expect(ignoringRefusalMessage(result) == expected)
                    #expect(exchange.received == (failure == nil ? sent : nil))
                } else {
                    let (outcomes, elements, result) = try await tc.withStallDetection(
                        after: hangLimit
                    ) { _ in
                        let handle = await connection.call(
                            methods.bidirectional,
                            on: coderEntity,
                            request
                        )
                        var outcomes: [String] = []
                        for number in sendable {
                            outcomes.append(
                                "\(await handle.outbound.send(Element(number: number)))"
                            )
                        }
                        if failure == nil { await handle.outbound.finish() }
                        var elements: [Element] = []
                        for await element in handle.inbound {
                            elements.append(element)
                            if elements.count > numbers.count { break }
                        }
                        return (outcomes, elements, await handle.inbound.result())
                    }
                    #expect(outcomes == expectedOutcomes)
                    #expect(elements == sent.map(Element.init(number:)))
                    #expect(ignoringRefusalMessage(result) == expected)
                }
        }
    }

    @Suite("Calls use their types' own MessagePack code", .hegel)
    struct CoderCallProperties {
        /// A unary call writes its request and reads it at the server, then
        /// writes its reply and reads it at the client, each through the
        /// type's own code when it has some and `Codable` when it has none,
        /// for every mix of the two. It fails at the first step that code
        /// refuses: the client's write as `.encode` with that code's error,
        /// the server's read as `.malformedParams`, the server's write as
        /// `.remoteInternal`, and the client's read as `.decode` with that
        /// code's error.
        ///
        /// Mutation-checked: `Codable` picked for any of the four steps
        /// fails this every time, and so do a response read failure reported
        /// as `.malformedParams` and a request write failure that loses its
        /// error. The rest of the suite misses the last one.
        @Test
        func unaryCallsUseTheTypesOwnCode() async throws {
            try await withCoderChoiceServer { connection, _ in
                try await property(
                    reaching: ["an own-coded request, an own-coded reply", "replied"],
                    reachingAfter: [
                        "a Codable request, a Codable reply": 1_000,
                        "a Codable request, an own-coded reply": 1_000,
                        "an own-coded request, a Codable reply": 1_000,
                        "the client refused to read the reply": 1_000,
                        "the client refused to write the request": 1_000,
                        "the server refused to read the request": 1_000,
                        "the server refused to write the reply": 1_000,
                    ]
                ) { tc in
                    let ownRequest = try #draw(.bool(), from: tc)
                    let ownReply = try #draw(.bool(), from: tc)
                    try tc.event(
                        "\(ownRequest ? "an own-coded" : "a Codable") request, "
                            + "\(ownReply ? "an own-coded" : "a Codable") reply"
                    )
                    switch (ownRequest, ownReply) {
                        case (true, true):
                            try await expectUnaryCall(
                                request: DirectCoders<OwnCodedRequest>.ownCode,
                                reply: DirectCoders<OwnCodedNumber>.ownCode,
                                through: connection,
                                in: tc
                            )
                        case (true, false):
                            try await expectUnaryCall(
                                request: DirectCoders<OwnCodedRequest>.ownCode,
                                reply: DirectCoders<CodableNumber>.codable,
                                through: connection,
                                in: tc
                            )
                        case (false, true):
                            try await expectUnaryCall(
                                request: DirectCoders<CodableRequest>.codable,
                                reply: DirectCoders<OwnCodedNumber>.ownCode,
                                through: connection,
                                in: tc
                            )
                        case (false, false):
                            try await expectUnaryCall(
                                request: DirectCoders<CodableRequest>.codable,
                                reply: DirectCoders<CodableNumber>.codable,
                                through: connection,
                                in: tc
                            )
                    }
                }
            }
        }

        /// Every stream call shape writes and reads its request, its
        /// elements in each direction and its reply through the types' own
        /// code when they have some and `Codable` when they have none, for
        /// every mix of the two. A request or a reply fails the call where
        /// that code refuses it, as a unary call does. An element the client
        /// can't write is not sent and its send ends `.callEnded`; the server
        /// stops at an element it can't write; and the client drops an
        /// element it can't read. The elements each side reads are the ones
        /// that got past both.
        ///
        /// Mutation-checked: eleven mutants that pick `Codable` for a
        /// request, for the elements in either direction or for a reply,
        /// across the three shapes and both sides, each fail this every
        /// time. The server stream's elements written through `Codable` fail
        /// it only when the client reads an element, so the server stream's
        /// elements are often ones the own code both writes and reads.
        ///
        /// It found that a stream frame reaching the client before the
        /// stream's control was installed closed the connection. With the
        /// old order, writing the opening request and installing the control
        /// 20 ms later, it fails every run.
        @Test
        func streamCallsUseTheTypesOwnCode() async throws {
            try await withCoderChoiceServer { connection, exchange in
                try await property(
                    reaching: ["a bidirectional stream", "a server stream", "replied"],
                    reachingAfter: [
                        "a client stream": 1_000,
                        "a Codable request, Codable elements": 1_000,
                        "a Codable request, own-coded elements": 1_000,
                        "an own-coded request, Codable elements": 1_000,
                        "an own-coded request, own-coded elements": 1_000,
                        "the client read an element": 1_000,
                        "the client refused to read an element": 1_000,
                        "the client refused to read the reply": 1_000,
                        "the client refused to write an element": 1_000,
                        "the client refused to write the request": 1_000,
                        "the server refused to read the request": 1_000,
                        "the server refused to write an element": 1_000,
                        "the server refused to write the reply": 1_000,
                    ]
                ) { tc in
                    let shape = try #draw(.element(of: StreamShape.allCases), from: tc)
                    let ownRequest = try #draw(.bool(), from: tc)
                    let ownElement = try #draw(.bool(), from: tc)
                    try tc.event(shape.rawValue)
                    try tc.event(
                        "\(ownRequest ? "an own-coded" : "a Codable") request, "
                            + "\(ownElement ? "own-coded" : "Codable") elements"
                    )
                    switch (ownRequest, ownElement) {
                        case (true, true):
                            try await expectStreamCall(
                                shape,
                                methods: StreamMethods<OwnCodedRequest, OwnCodedNumber>(),
                                request: .ownCode,
                                element: .ownCode,
                                through: connection,
                                exchange: exchange,
                                in: tc
                            )
                        case (true, false):
                            try await expectStreamCall(
                                shape,
                                methods: StreamMethods<OwnCodedRequest, CodableNumber>(),
                                request: .ownCode,
                                element: .codable,
                                through: connection,
                                exchange: exchange,
                                in: tc
                            )
                        case (false, true):
                            try await expectStreamCall(
                                shape,
                                methods: StreamMethods<CodableRequest, OwnCodedNumber>(),
                                request: .codable,
                                element: .ownCode,
                                through: connection,
                                exchange: exchange,
                                in: tc
                            )
                        case (false, false):
                            try await expectStreamCall(
                                shape,
                                methods: StreamMethods<CodableRequest, CodableNumber>(),
                                request: .codable,
                                element: .codable,
                                through: connection,
                                exchange: exchange,
                                in: tc
                            )
                    }
                }
            }
        }
    }

#endif

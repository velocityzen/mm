// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import Testing

    /// One element of a wire array, in every encoding that means the same.
    indirect enum WireElement: Sendable {
        /// One value, in any of these encodings, narrowest first.
        case value([[UInt8]])
        /// An array of elements, under any header that declares their count.
        case array([WireElement])

        /// The encoding a canonical writer picks: the narrowest, and of two
        /// as narrow, the unsigned one.
        var narrowest: [UInt8] {
            switch self {
                case .value(let encodings):
                    encodings.min { $0.count < $1.count }!
                case .array(let elements):
                    arrayHeaderOptions(count: elements.count)[0] + elements.flatMap(\.narrowest)
            }
        }

        var anyEncoding: Gen<[UInt8]> {
            switch self {
                case .value(let encodings):
                    .element(of: encodings)
                case .array(let elements):
                    Gen { tc in
                        try tc.draw(.element(of: arrayHeaderOptions(count: elements.count)))
                            + elements.flatMap { try tc.draw($0.anyEncoding) }
                    }
            }
        }
    }

    func arrayHeaderOptions(count: Int) -> [[UInt8]] {
        PackGenerators.headerOptions(
            count: count,
            fix: (0x90, 16),
            eightBit: nil,
            sixteenBit: 0xdc,
            thirtyTwoBit: 0xdd
        )
    }

    func integerElement(_ value: Int64) -> WireElement {
        .value(PackGenerators.integerEncodings(value))
    }

    func integerElement(_ value: UInt64) -> WireElement {
        guard let signed = Int64(exactly: value) else {
            return .value([[0xcf] + bigEndianBytes(value)])
        }
        return integerElement(signed)
    }

    func stringElement(_ text: String) -> WireElement {
        let utf8 = Array(text.utf8)
        let headers = PackGenerators.headerOptions(
            count: utf8.count,
            fix: (0xa0, 32),
            eightBit: 0xd9,
            sixteenBit: 0xda,
            thirtyTwoBit: 0xdb
        )
        return .value(headers.map { $0 + utf8 })
    }

    /// A raw slot: its bytes, exactly as given.
    func rawElement(_ slot: ByteBuffer) -> WireElement {
        .value([Array(slot.readableBytesView)])
    }

    let nilElement = WireElement.value([[0xc0]])

    /// Each kind's name, by its tag.
    let kindNames = ["response", "request", "credit", "item", "end", "stop", "cancel"]

    func tag(of envelope: MMEnvelope) -> Int {
        switch envelope {
            case .response: 0
            case .request: 1
            case .credit: 2
            case .item: 3
            case .end: 4
            case .stop: 5
            case .cancel: 6
        }
    }

    /// The fewest elements a kind's array may hold, from the spec's table.
    func fewestElements(ofKind tag: Int) -> Int {
        [4, 5, 3, 4, 3, 3, 2][tag]
    }

    /// Whether a kind decodes from an array of `count` elements: exactly its
    /// table arity, except a request also at 6, and END and CANCEL at any
    /// count from their fewest up.
    func decodes(arity count: Int, ofKind tag: Int) -> Bool {
        switch tag {
            case 1: count == 5 || count == 6
            case 4, 6: count >= fewestElements(ofKind: tag)
            default: count == fewestElements(ofKind: tag)
        }
    }

    /// The elements an envelope's meaning needs, in table order. END's
    /// reserved third element is not among them.
    func requiredElements(of envelope: MMEnvelope) -> [WireElement] {
        func unsigned(_ value: UInt32) -> WireElement { integerElement(UInt64(value)) }
        let tag = integerElement(UInt64(tag(of: envelope)))
        switch envelope {
            case .response(let msgid, let error, let result):
                return [
                    tag, unsigned(msgid), error.map(wireForm) ?? nilElement,
                    result.map(rawElement) ?? nilElement,
                ]
            case .request(let msgid, let method, let entity, let params):
                return [
                    tag, unsigned(msgid), stringElement(method), stringElement(entity),
                    rawElement(params),
                ]
            case .credit(let msgid, let credits):
                return [tag, unsigned(msgid), unsigned(credits)]
            case .item(let msgid, let seq, let item):
                return [tag, unsigned(msgid), unsigned(seq), rawElement(item)]
            case .end(let msgid), .cancel(let msgid):
                return [tag, unsigned(msgid)]
            case .stop(let msgid, let code):
                return [tag, unsigned(msgid), unsigned(code)]
        }
    }

    /// The wire form the spec's table gives an envelope: its required
    /// elements, and END's reserved 0.
    func wireForm(of envelope: MMEnvelope) -> WireElement {
        let reserved: [WireElement] =
            if case .end = envelope { [integerElement(Int64(0))] } else { [] }
        return .array(requiredElements(of: envelope) + reserved)
    }

    func errorElements(of error: MMError) -> [WireElement] {
        [integerElement(Int64(error.code)), stringElement(error.message)]
            + (error.payload.map { [rawElement($0)] } ?? [])
    }

    func wireForm(of error: MMError) -> WireElement {
        .array(errorElements(of: error))
    }

    func isNil(_ slot: ByteBuffer) -> Bool {
        Array(slot.readableBytesView) == [0xc0]
    }

    /// The envelope as decoding gives it back: a nil in the result slot or
    /// the error's payload slot reads as absent.
    func normalized(_ envelope: MMEnvelope) -> MMEnvelope {
        guard case .response(let msgid, var error, var result) = envelope else { return envelope }
        if let slot = result, isNil(slot) { result = nil }
        if let payload = error?.payload, isNil(payload) { error?.payload = nil }
        return .response(msgid: msgid, error: error, result: result)
    }

    /// How a decoding case's bytes depart from the table's wire form.
    enum DecodeVariation: CaseIterable, Sendable {
        case anyWidths, trailingElements, missingElements, unknownTag, fieldOutOfRange, errorArity,
            bytesAfter

        var label: String {
            switch self {
                case .anyWidths: "every element in any width"
                case .trailingElements: "trailing elements"
                case .missingElements: "missing elements"
                case .unknownTag: "an unknown tag"
                case .fieldOutOfRange: "a u32 field out of range"
                case .errorArity: "an error with trailing or missing elements"
                case .bytesAfter: "bytes after the envelope"
            }
        }
    }

    /// Envelope bytes and what the spec says they decode to.
    struct DecodeCase: Sendable {
        var kind: String
        var variation: DecodeVariation
        var bytes: [UInt8]
        var expected: Result<MMEnvelope, MMWireError>
    }

    enum EnvelopeGenerators {
        static let u32s: Gen<UInt32> = .oneOf(
            .integer(),
            .element(of: [0, 127, 128, 255, 256, 65_535, 65_536, .max])
        )

        /// Any text, often empty: the root entity's path.
        static let texts: Gen<String> = .oneOf(.string(), .just(""))

        static let values: Gen<[UInt8]> = PackGenerators.values(of: PackGenerators.scalarFamilies)

        /// A raw slot: any one value, often nil.
        static let slots: Gen<ByteBuffer> = Gen<[UInt8]>.oneOf(.just([0xc0]), values).map {
            ByteBuffer(bytes: $0)
        }

        static let errors: Gen<MMError> = Hegel.zip(
            .oneOf(Gen<Int>.int(), .element(of: [0, -1, -32, -33, .max, .min])),
            texts,
            .optional(slots)
        )
        .map { MMError(code: $0, message: $1, payload: $2) }

        static let responsesWithErrors: Gen<MMEnvelope> = Hegel.zip(u32s, errors, .optional(slots))
            .map {
                .response(msgid: $0, error: $1, result: $2)
            }

        /// One generator per kind, by tag, every field from its whole
        /// domain.
        static let kinds: [Gen<MMEnvelope>] = [
            Hegel.zip(u32s, .optional(errors), .optional(slots)).map {
                .response(msgid: $0, error: $1, result: $2)
            },
            Gen { tc in
                try .request(
                    msgid: tc.draw(u32s),
                    method: tc.draw(texts),
                    entity: tc.draw(texts),
                    params: tc.draw(slots)
                )
            },
            Hegel.zip(u32s, u32s).map { .credit(msgid: $0, credits: $1) },
            Hegel.zip(u32s, u32s, slots).map { .item(msgid: $0, seq: $1, item: $2) },
            u32s.map { .end(msgid: $0) },
            Hegel.zip(u32s, u32s).map { .stop(msgid: $0, code: $1) },
            u32s.map { .cancel(msgid: $0) },
        ]

        static let envelopes: Gen<MMEnvelope> = .oneOf(kinds)

        /// Any envelope, often of a kind that tolerates trailing elements:
        /// a request, END or CANCEL.
        static let envelopesForTrailingElements: Gen<MMEnvelope> = .oneOf(
            envelopes,
            .oneOf([kinds[1], kinds[4], kinds[6]])
        )

        /// Any number of trailing elements, at least one, often one or two:
        /// a request takes a sixth element but not a seventh.
        static let trailingElements: Gen<[[UInt8]]> = .oneOf(
            .array(of: values, count: 1...Int.max),
            .array(of: values, count: 1...1),
            .array(of: values, count: 2...2)
        )

        /// A tag outside 0...6 in any width: negative, past 6, or past
        /// `Int64.max`.
        static let unknownTags: Gen<[UInt8]> = .oneOf(
            Gen<Int64>.oneOf(
                .integer(in: .min ... -1),
                .integer(in: 7 ... .max),
                .element(of: [-1, 7, .max])
            )
            .flatMap { integerElement($0).anyEncoding },
            Gen<UInt64>.integer(in: UInt64(Int64.max) + 1 ... .max).flatMap {
                integerElement($0).anyEncoding
            }
        )

        /// An integer a u32 field can't hold, in any width, and the error
        /// reading it gives: a negative one is out of `UInt64`'s range, a
        /// large one out of `UInt32`'s.
        static let outOfRangeFields: Gen<([UInt8], MMWireError)> = .oneOf(
            Gen<Int64>.oneOf(.integer(in: .min ... -1), .element(of: [-1, -33, .min])).flatMap {
                value in
                integerElement(value).anyEncoding.map { ($0, .numberOutOfRange(target: "UInt64")) }
            },
            Gen<UInt64>.oneOf(
                .integer(in: UInt64(UInt32.max) + 1 ... .max),
                .element(of: [UInt64(UInt32.max) + 1, .max])
            )
            .flatMap { value in
                integerElement(value).anyEncoding.map { ($0, .numberOutOfRange(target: "UInt32")) }
            }
        )

        /// What decoding an array of `count` elements of a kind gives, when
        /// the elements its meaning needs are all there and well formed.
        static func outcome(arity count: Int, of envelope: MMEnvelope) -> Result<
            MMEnvelope, MMWireError
        > {
            let kind = tag(of: envelope)
            if count == 0 { return .failure(.unknownEnvelope) }
            guard decodes(arity: count, ofKind: kind) else {
                return .failure(.invalidArity(expected: fewestElements(ofKind: kind), got: count))
            }
            return .success(normalized(envelope))
        }

        /// An envelope's wire form, its elements in any width, with one
        /// departure from the table drawn per case.
        static let decodeCases: Gen<DecodeCase> = Gen { tc in
            // Trailing elements take half the draws: each kind tolerates a
            // different count, and a request's limit sits between one
            // trailing element and two.
            let variation = try tc.draw(
                Gen<DecodeVariation>.oneOf(
                    .element(of: DecodeVariation.allCases),
                    .just(.trailingElements)
                )
            )
            let envelopeGenerator: Gen<MMEnvelope> =
                switch variation {
                    case .errorArity: responsesWithErrors
                    case .trailingElements: envelopesForTrailingElements
                    default: envelopes
                }
            let envelope = try tc.draw(envelopeGenerator)
            let kind = tag(of: envelope)
            var elements = try requiredElements(of: envelope).map { try tc.draw($0.anyEncoding) }
            if case .end = envelope {
                // The reserved element: 0 as written, or any value, which
                // decoding skips.
                elements.append(try tc.draw(.oneOf(integerElement(Int64(0)).anyEncoding, values)))
            }
            var expected = Result<MMEnvelope, MMWireError>.success(normalized(envelope))
            var after: [UInt8] = []
            switch variation {
                case .anyWidths:
                    break
                case .trailingElements:
                    elements += try tc.draw(trailingElements)
                    expected = outcome(arity: elements.count, of: envelope)
                case .missingElements:
                    let missing = try tc.draw(Gen<Int>.int(in: 1...elements.count))
                    elements.removeLast(missing)
                    expected = outcome(arity: elements.count, of: envelope)
                case .unknownTag:
                    elements[0] = try tc.draw(unknownTags)
                    expected = .failure(.unknownEnvelope)
                case .fieldOutOfRange:
                    // The msgid, and the credits, seq or STOP code after it.
                    let fields = [2, 3, 5].contains(kind) ? [1, 2] : [1]
                    let (bytes, error) = try tc.draw(outOfRangeFields)
                    elements[try tc.draw(.element(of: fields))] = bytes
                    expected = .failure(error)
                case .errorArity:
                    guard case .response(let msgid, let error?, let result) = envelope else {
                        preconditionFailure("errorArity draws a response with an error")
                    }
                    var fields = try errorElements(of: error).map { try tc.draw($0.anyEncoding) }
                    if try tc.draw(.bool()) {
                        fields += try tc.draw(trailingElements)
                    } else {
                        fields.removeLast(try tc.draw(Gen<Int>.int(in: 1...fields.count)))
                    }
                    elements[2] =
                        try tc.draw(.element(of: arrayHeaderOptions(count: fields.count)))
                        + fields.joined()
                    if fields.count < 2 {
                        expected = .failure(.invalidArity(expected: 2, got: fields.count))
                    } else {
                        // The third element is the payload; any past it are skipped.
                        let payload = fields.count >= 3 ? ByteBuffer(bytes: fields[2]) : nil
                        let decoded = MMError(
                            code: error.code,
                            message: error.message,
                            payload: payload
                        )
                        expected = .success(
                            normalized(.response(msgid: msgid, error: decoded, result: result))
                        )
                    }
                case .bytesAfter:
                    after = try tc.draw(.bytes(count: 1...Int.max))
                    expected = .failure(
                        .decodingFailed(description: "trailing bytes after envelope")
                    )
            }
            let header = try tc.draw(.element(of: arrayHeaderOptions(count: elements.count)))
            return DecodeCase(
                kind: kindNames[kind],
                variation: variation,
                bytes: header + elements.joined() + after,
                expected: expected
            )
        }
    }

    /// Where a raw slot sits: the four kinds of slot the encoder validates.
    enum SlotPlace: CaseIterable, Sendable {
        case params, result, errorPayload, item

        var name: String {
            switch self {
                case .params: "params"
                case .result: "result"
                case .errorPayload: "error payload"
                case .item: "item"
            }
        }

        func envelope(msgid: UInt32, holding slot: ByteBuffer) -> MMEnvelope {
            switch self {
                case .params: .request(msgid: msgid, method: "method", entity: "", params: slot)
                case .result: .response(msgid: msgid, error: nil, result: slot)
                case .errorPayload:
                    .response(
                        msgid: msgid,
                        error: MMError(code: 1, message: "", payload: slot),
                        result: nil
                    )
                case .item: .item(msgid: msgid, seq: 0, item: slot)
            }
        }
    }

    @Suite("Envelope properties", .hegel, .offTheCooperativePool)
    struct EnvelopeProperties {
        /// Every kind encodes to the layout the spec's table gives it, with
        /// each integer and header at its narrowest, and decodes back to
        /// itself. A nil in the result slot or the error's payload slot
        /// comes back as absent.
        ///
        /// Mutation-checked: END writing nil as its reserved element fails
        /// this, though decoding still takes it back.
        @Test
        func everyKindRoundTrips() throws {
            try property(
                reaching: reachClaims(
                    everyRun: [],
                    deepRuns: [
                        "a nil slot that comes back absent", "cancel", "credit", "end", "item",
                        "request", "response", "stop",
                    ]
                )
            ) { tc in
                let envelope = try #draw(EnvelopeGenerators.envelopes, from: tc)
                try tc.event(kindNames[tag(of: envelope)])
                if normalized(envelope) != envelope {
                    try tc.event("a nil slot that comes back absent")
                }
                let encoded = envelope.encoded(maxDepth: .max)
                #expect(
                    encoded.map { Array($0.readableBytesView) }
                        == .success(wireForm(of: envelope).narrowest)
                )
                if case .success(let bytes) = encoded {
                    #expect(
                        MMEnvelope.decode(from: bytes, maxDepth: .max)
                            == .success(normalized(envelope))
                    )
                }
            }
        }

        /// Decoding agrees with the spec's table, whatever width each
        /// integer and header takes. Trailing elements are skipped where the
        /// table tolerates them (a request's sixth, any past END's third or
        /// CANCEL's second, any past an error's payload) and fail as an
        /// invalid arity elsewhere, as missing elements do. An unknown tag,
        /// a u32 field out of range, and bytes after the envelope each fail
        /// with their own error.
        ///
        /// Mutation-checked: a request taking any number of trailing
        /// elements fails this, and so does a u32 field that truncates
        /// instead of failing.
        @Test
        func decodingFollowsTheTable() throws {
            try property(
                reaching: reachClaims(
                    everyRun: ["decoded", "failed with invalidArity", "trailing elements"],
                    deepRuns: [
                        "a u32 field out of range", "an error with trailing or missing elements",
                        "bytes after the envelope", "cancel", "cancel trailing elements tolerated",
                        "credit", "end", "end trailing elements tolerated",
                        "every element in any width", "failed with decodingFailed",
                        "failed with numberOutOfRange", "failed with unknownEnvelope", "item",
                        "item trailing elements rejected", "missing elements", "request",
                        "request trailing elements rejected", "request trailing elements tolerated",
                        "response", "response an error with trailing or missing elements tolerated",
                        "response trailing elements rejected", "stop",
                        "stop trailing elements rejected",
                    ]
                )
            ) { tc in
                let decodeCase = try #draw(EnvelopeGenerators.decodeCases, from: tc)
                try tc.event(decodeCase.kind)
                try tc.event(decodeCase.variation.label)
                if [.trailingElements, .errorArity].contains(decodeCase.variation) {
                    let verdict =
                        if case .success = decodeCase.expected { "tolerated" } else { "rejected" }
                    try tc.event("\(decodeCase.kind) \(decodeCase.variation.label) \(verdict)")
                }
                let decoded = MMEnvelope.decode(
                    from: ByteBuffer(bytes: decodeCase.bytes),
                    maxDepth: .max
                )
                try tc.event(outcome(decoded))
                #expect(
                    decoded == decodeCase.expected,
                    "\(hex(ByteBuffer(bytes: decodeCase.bytes)))"
                )
            }
        }

        /// Encoding takes a raw slot exactly when it holds one complete value
        /// and nothing after it, within the nesting limit: past the limit it
        /// fails as too deep, and otherwise as an encoding failure. A failure
        /// writes nothing. What encodes decodes back under the same limit.
        ///
        /// Mutation-checked: a slot check that lets bytes after the value
        /// through fails this.
        @Test
        func encodingValidatesRawSlots() throws {
            try property(
                reaching: reachClaims(
                    everyRun: ["a slot with bytes after its value", "failed with encodingFailed"],
                    deepRuns: [
                        "a corrupted value", "a strict prefix of a value",
                        "a value and bytes after it", "a value with 0xc1 inserted", "a whole value",
                        "any bytes", "decoded", "error payload", "failed with nestingTooDeep",
                        "item", "params", "result",
                    ]
                )
            ) { tc in
                let slot = try #draw(PackGenerators.inputs, from: tc)
                let place = try #draw(Gen<SlotPlace>.element(of: SlotPlace.allCases), from: tc)
                let maxDepth = try #draw(PackGenerators.nestingLimits, from: tc)
                let msgid = try #draw(EnvelopeGenerators.u32s, from: tc)
                let alreadyWritten = try #draw(Gen<[UInt8]>.bytes(), from: tc)
                try tc.event(slot.kind)
                try tc.event(place.name)
                let envelope = place.envelope(msgid: msgid, holding: ByteBuffer(bytes: slot.bytes))

                var probe = ByteBuffer(bytes: slot.bytes)
                let skipped = probe.skipMessagePackValue(maxDepth: maxDepth)
                if case .success = skipped, probe.readableBytes > 0 {
                    try tc.event("a slot with bytes after its value")
                }
                var buffer = ByteBuffer(bytes: alreadyWritten)
                let encoded = envelope.encode(into: &buffer, maxDepth: maxDepth)
                try tc.event(outcome(encoded))
                switch (skipped, encoded) {
                    case (.success, .success) where probe.readableBytes == 0:
                        #expect(
                            Array(buffer.readableBytesView.prefix(alreadyWritten.count))
                                == alreadyWritten
                        )
                        let written = buffer.getSlice(
                            at: buffer.readerIndex + alreadyWritten.count,
                            length: buffer.readableBytes - alreadyWritten.count
                        )!
                        #expect(
                            MMEnvelope.decode(from: written, maxDepth: maxDepth)
                                == .success(normalized(envelope))
                        )
                    case (.failure(.nestingTooDeep), .failure(let error)):
                        #expect(error == .nestingTooDeep(limit: maxDepth))
                        #expect(Array(buffer.readableBytesView) == alreadyWritten)
                    case (_, .failure(.encodingFailed(let description))):
                        #expect(
                            failure(skipped) != nil || probe.readableBytes > 0,
                            "encoding failed on a slot that is one value: \(description)"
                        )
                        #expect(description.hasPrefix(place.name), "\(description)")
                        #expect(Array(buffer.readableBytesView) == alreadyWritten)
                    default:
                        Issue.record(
                            "skip gave \(skipped), with \(probe.readableBytes) bytes after; encode gave \(encoded)"
                        )
                }
            }
        }

        /// Any bytes decode to an envelope or a typed error, never a trap,
        /// and a decoded envelope re-encodes to bytes that decode to it.
        @Test
        func decodedEnvelopesReencode() throws {
            try property(
                reaching: reachClaims(
                    everyRun: [
                        "a corrupted envelope", "a strict prefix of an envelope",
                        "failed with truncated", "failed with typeMismatch",
                    ],
                    deepRuns: ["any bytes", "decoded", "failed with unknownEnvelope"]
                )
            ) { tc in
                let envelope = try #draw(EnvelopeGenerators.envelopes, from: tc)
                let bytes = wireForm(of: envelope).narrowest
                let input = try #draw(
                    Gen<ReaderInput>.oneOf(
                        mutations.map {
                            ReaderInput(kind: "a corrupted envelope", bytes: mutated(bytes, by: $0))
                        },
                        Gen<Int>.int(in: 0...bytes.count - 1).map {
                            ReaderInput(
                                kind: "a strict prefix of an envelope",
                                bytes: Array(bytes.prefix($0))
                            )
                        },
                        Gen<[UInt8]>.bytes().map { ReaderInput(kind: "any bytes", bytes: $0) }
                    ),
                    from: tc
                )
                try tc.event(input.kind)
                let decoded = MMEnvelope.decode(from: ByteBuffer(bytes: input.bytes))
                try tc.event(outcome(decoded))
                if case .success(let envelope) = decoded {
                    #expect(
                        envelope.encoded().flatMap { MMEnvelope.decode(from: $0) }
                            == .success(envelope),
                        "\(hex(ByteBuffer(bytes: input.bytes)))"
                    )
                }
            }
        }
    }

#endif

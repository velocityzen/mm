// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import NIOEmbedded
    import Testing

    /// A payload as the encoder is handed it: a buffer whose reader index has
    /// already passed `alreadyRead`, so only `payload` is readable. The
    /// encoder must frame the readable bytes alone.
    struct PayloadBuffer: Sendable {
        var alreadyRead: [UInt8]
        var payload: [UInt8]

        var buffer: ByteBuffer {
            var buffer = ByteBuffer(bytes: self.alreadyRead + self.payload)
            buffer.moveReaderIndex(forwardBy: self.alreadyRead.count)
            return buffer
        }
    }

    /// How a stream ends: on a frame boundary, or partway through one more
    /// frame.
    enum StreamEnding: Sendable {
        /// Right after a complete frame, or with no frame at all.
        case frameBoundary
        /// One to three bytes of a length prefix.
        case partialLengthPrefix([UInt8])
        /// A complete length prefix and fewer body bytes than it declares.
        case partialBody(declaredLength: UInt32, receivedBody: [UInt8])

        /// The unfinished frame's bytes on the wire.
        var bytes: [UInt8] {
            switch self {
                case .frameBoundary: []
                case .partialLengthPrefix(let bytes): bytes
                case .partialBody(let declaredLength, let receivedBody):
                    lengthPrefix(declaredLength) + receivedBody
            }
        }

        /// The smallest limit under which the unfinished frame is not
        /// oversized. A partial prefix declares no length yet.
        var smallestLimit: UInt32 {
            if case .partialBody(let declaredLength, _) = self { declaredLength } else { 0 }
        }

        /// A constant label for the statistics report.
        var label: String {
            switch self {
                case .frameBoundary: "ends on a frame boundary"
                case .partialLengthPrefix: "ends inside a length prefix"
                case .partialBody: "ends inside a body"
            }
        }
    }

    /// Records, for the statistics report, whether a read ends inside one of
    /// the length prefixes that start at `frameStarts`.
    func recordReadsSplittingPrefixes(
        _ chunkBoundaries: [Int],
        frameStarts: some Sequence<Int>,
        in tc: TestCase
    ) throws {
        let splitsAPrefix = frameStarts.contains { start in
            chunkBoundaries.contains { start < $0 && $0 < start + 4 }
        }
        if splitsAPrefix {
            try tc.event("a read ends inside a length prefix")
        }
    }

    /// The length prefix model: `length` as four little-endian bytes, built
    /// by hand rather than with the NIO integer writer the codec uses.
    func lengthPrefix(_ length: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24),
        ]
    }

    /// The frame model: `[u32 LE length][payload]`, the length counting the
    /// payload bytes only.
    func framed(_ payload: [UInt8]) -> [UInt8] {
        lengthPrefix(UInt32(payload.count)) + payload
    }

    /// The offset each of `payloads`' frames starts at on the wire, then the
    /// offset right after the last of them.
    func frameOffsets(_ payloads: [[UInt8]]) -> [Int] {
        payloads.reduce(into: [0]) { offsets, payload in
            offsets.append(offsets[offsets.count - 1] + 4 + payload.count)
        }
    }

    /// `byteCount` bytes cut at the ascending `chunkBoundaries` into
    /// consecutive ranges. A repeated boundary makes an empty chunk.
    func chunkRanges(byteCount: Int, chunkBoundaries: [Int]) -> [Range<Int>] {
        let edges = [0] + chunkBoundaries + [byteCount]
        return Swift.zip(edges, edges.dropFirst()).map { $0..<$1 }
    }

    func decoderChannel(maximumLength: UInt32) -> EmbeddedChannel {
        EmbeddedChannel(
            handler: ByteToMessageHandler(MMFrameDecoder(maxFrameLength: maximumLength))
        )
    }

    func encoderChannel(maximumLength: UInt32) -> EmbeddedChannel {
        EmbeddedChannel(
            handler: MessageToByteHandler(MMFrameEncoder(maxFrameLength: maximumLength))
        )
    }

    /// Reads every buffer the channel's pipeline has passed on so far.
    func emittedPayloads(_ channel: EmbeddedChannel) throws -> [[UInt8]] {
        var payloads: [[UInt8]] = []
        while let payload = try channel.readInbound(as: ByteBuffer.self) {
            payloads.append(Array(payload.readableBytesView))
        }
        return payloads
    }

    /// Feeds `wire`, which begins with `payloads`' frames, to the decoder on
    /// `channel` one chunk per read. After each chunk the decoder must have
    /// emitted exactly the payloads whose frames have fully arrived: none
    /// early, none held back for a later read.
    func deliverCompleteFrames(
        _ payloads: [[UInt8]],
        wire: [UInt8],
        in chunks: [Range<Int>],
        to channel: EmbeddedChannel
    ) throws {
        let frameEnds = frameOffsets(payloads).dropFirst()
        var emitted: [[UInt8]] = []
        for chunk in chunks {
            try channel.writeInbound(ByteBuffer(bytes: wire[chunk]))
            emitted += try emittedPayloads(channel)
            let completedFrames = frameEnds.count(where: { $0 <= chunk.upperBound })
            #expect(emitted == Array(payloads.prefix(completedFrames)), "after the chunk \(chunk)")
        }
    }

    enum FramingGenerators {
        /// Any number of payloads, each any bytes of any size.
        static let payloads: Gen<[[UInt8]]> = .array(of: .bytes())

        static let payloadBuffers: Gen<PayloadBuffer> = Hegel.zip(
            Gen<[UInt8]>.bytes(),
            Gen<[UInt8]>.bytes()
        )
        .map { PayloadBuffer(alreadyRead: $0, payload: $1) }

        /// Any `UInt32` from `smallest` up, often exactly `smallest` or
        /// `UInt32.max`.
        static func atLeast(_ smallest: UInt32) -> Gen<UInt32> {
            .oneOf(.integer(in: smallest...UInt32.max), .just(smallest), .just(UInt32.max))
        }

        /// Any limit that some length can exceed: every `UInt32` but the
        /// largest, often 0 or `UInt32.max - 1`.
        static let exceedableLimits: Gen<UInt32> = .oneOf(
            .integer(in: 0...UInt32.max - 1),
            .just(0),
            .just(UInt32.max - 1)
        )

        /// Any limit, often at, just under or below `byteCount`.
        static func limits(around byteCount: UInt32) -> Gen<UInt32> {
            var limits: [Gen<UInt32>] = [.integer(), .integer(in: 0...byteCount), .just(byteCount)]
            if byteCount > 0 {
                limits.append(.just(byteCount - 1))
            }
            return .oneOf(limits)
        }

        /// Where to cut `byteCount` bytes into chunks, ascending: anywhere,
        /// at and inside the length prefixes that start at `frameStarts`,
        /// or at every byte. A repeated position makes an empty chunk.
        static func chunkBoundaries(byteCount: Int, frameStarts: [Int]) -> Gen<[Int]> {
            let prefixPositions = frameStarts.flatMap { $0...$0 + 4 }.filter { $0 <= byteCount }
            let position: Gen<Int> = .oneOf(.int(in: 0...byteCount), .element(of: prefixPositions))
            return .oneOf(
                .array(of: position).map { $0.sorted() },
                .just(Array(stride(from: 1, to: byteCount, by: 1)))
            )
        }

        /// The stream ends on a frame boundary, inside a length prefix, or
        /// inside a body: any received body bytes, and any declared length
        /// longer than them, often by one byte or up to `UInt32.max`.
        static let streamEndings: Gen<StreamEnding> = .oneOf(
            .just(.frameBoundary),
            Gen<[UInt8]>.bytes(count: 1...3).map { StreamEnding.partialLengthPrefix($0) },
            Gen<[UInt8]>.bytes().flatMap { receivedBody in
                atLeast(UInt32(receivedBody.count) + 1).map { declaredLength in
                    StreamEnding.partialBody(
                        declaredLength: declaredLength,
                        receivedBody: receivedBody
                    )
                }
            }
        )
    }

    @Suite("Frame codec properties", .hegel, .offTheCooperativePool)
    struct FramingProperties {
        /// The encoder frames any payloads as the model does, and the decoder
        /// gives them back unchanged and in order however the wire is cut into
        /// reads, each one by the read that completes its frame. EOF on the
        /// last frame's boundary is clean.
        ///
        /// Mutation-checked: a decoder that rejects a length equal to its
        /// limit fails this with one empty payload under a limit of 0.
        @Test
        func anyPayloadsInAnyChunksComeOutTheSame() throws {
            try property(
                reaching: ["a read ends inside a length prefix", "an empty payload"],
                reachingAfter: ["the encoder's limit is the largest payload's length": 1_000]
            ) { tc in
                let payloadBuffers = try #draw(
                    .array(of: FramingGenerators.payloadBuffers),
                    from: tc
                )
                let payloads = payloadBuffers.map(\.payload)
                let largestPayload = UInt32(payloads.map(\.count).max() ?? 0)
                let encoderMaximumLength = try #draw(
                    FramingGenerators.atLeast(largestPayload),
                    from: tc
                )
                let decoderMaximumLength = try #draw(
                    FramingGenerators.atLeast(largestPayload),
                    from: tc
                )

                let encoder = encoderChannel(maximumLength: encoderMaximumLength)
                var wire: [UInt8] = []
                for payloadBuffer in payloadBuffers {
                    try encoder.writeOutbound(payloadBuffer.buffer)
                    let frame = try encoder.readOutbound(as: ByteBuffer.self)
                    let frameBytes = try #require(frame.map { Array($0.readableBytesView) })
                    #expect(frameBytes == framed(payloadBuffer.payload))
                    wire += frameBytes
                }
                #expect(try encoder.readOutbound(as: ByteBuffer.self) == nil)
                #expect(try encoder.finish().isClean)

                let chunkBoundaries = try #draw(
                    FramingGenerators.chunkBoundaries(
                        byteCount: wire.count,
                        frameStarts: frameOffsets(payloads)
                    ),
                    from: tc
                )
                try recordReadsSplittingPrefixes(
                    chunkBoundaries,
                    frameStarts: frameOffsets(payloads),
                    in: tc
                )
                if payloads.contains(where: \.isEmpty) {
                    try tc.event("an empty payload")
                }
                if encoderMaximumLength == largestPayload {
                    try tc.event("the encoder's limit is the largest payload's length")
                }
                let decoder = decoderChannel(maximumLength: decoderMaximumLength)
                try deliverCompleteFrames(
                    payloads,
                    wire: wire,
                    in: chunkRanges(byteCount: wire.count, chunkBoundaries: chunkBoundaries),
                    to: decoder
                )
                #expect(try decoder.finish().isClean)
            }
        }

        /// A declared length over the limit fails the decoder with
        /// `frameTooLarge` on the read that completes its prefix, however the
        /// prefix is split, and never earlier; the complete frames before it
        /// are all emitted first.
        @Test
        func oversizedLengthIsRejectedBeforeItsBody() throws {
            try property(
                reaching: [
                    "a read ends inside a length prefix",
                    "complete frames before the oversized one",
                ]
            ) { tc in
                let maximumLength = try #draw(FramingGenerators.exceedableLimits, from: tc)
                let declaredLength = try #draw(
                    FramingGenerators.atLeast(maximumLength + 1),
                    from: tc
                )
                let payloads = try #draw(
                    .array(of: .bytes(count: 0...Int(maximumLength))),
                    from: tc
                )
                // Body bytes reach the decoder only in the read that completes
                // the prefix, so they never decide the outcome.
                let body = try #draw(.bytes(), from: tc)
                let offsets = frameOffsets(payloads)
                let prefixEnd = offsets[offsets.count - 1] + 4
                let wire = payloads.flatMap(framed) + lengthPrefix(declaredLength) + body
                let chunkBoundaries = try #draw(
                    FramingGenerators.chunkBoundaries(byteCount: wire.count, frameStarts: offsets),
                    from: tc
                )
                try recordReadsSplittingPrefixes(
                    chunkBoundaries,
                    frameStarts: [prefixEnd - 4],
                    in: tc
                )
                if !payloads.isEmpty {
                    try tc.event("complete frames before the oversized one")
                }

                let expectedError = MMWireError.frameTooLarge(
                    length: declaredLength,
                    limit: maximumLength
                )
                let decoder = decoderChannel(maximumLength: maximumLength)
                for chunk in chunkRanges(byteCount: wire.count, chunkBoundaries: chunkBoundaries) {
                    let read = ByteBuffer(bytes: wire[chunk])
                    guard chunk.upperBound >= prefixEnd else {
                        try decoder.writeInbound(read)
                        continue
                    }
                    #expect(throws: expectedError) {
                        try decoder.writeInbound(read)
                    }
                    break
                }
                #expect(try emittedPayloads(decoder) == payloads)
                _ = try? decoder.finish(acceptAlreadyClosed: true)
            }
        }

        /// The encoder rejects a payload with `frameTooLarge` exactly when its
        /// readable byte count is over the limit, and frames every other one
        /// as the model does, a payload exactly at the limit included.
        @Test
        func encoderRejectsExactlyThePayloadsOverTheLimit() throws {
            try property(
                reaching: ["over the limit", "the payload's length is the limit"]
            ) { tc in
                let payloadBuffer = try #draw(FramingGenerators.payloadBuffers, from: tc)
                let byteCount = UInt32(payloadBuffer.payload.count)
                let maximumLength = try #draw(FramingGenerators.limits(around: byteCount), from: tc)

                if byteCount == maximumLength {
                    try tc.event("the payload's length is the limit")
                }
                let encoder = encoderChannel(maximumLength: maximumLength)
                if byteCount > maximumLength {
                    try tc.event("over the limit")
                    let expectedError = MMWireError.frameTooLarge(
                        length: byteCount,
                        limit: maximumLength
                    )
                    #expect(throws: expectedError) {
                        try encoder.writeOutbound(payloadBuffer.buffer)
                    }
                    #expect(try encoder.readOutbound(as: ByteBuffer.self) == nil)
                    _ = try? encoder.finish(acceptAlreadyClosed: true)
                } else {
                    try encoder.writeOutbound(payloadBuffer.buffer)
                    let frame = try encoder.readOutbound(as: ByteBuffer.self)
                    #expect(
                        frame.map { Array($0.readableBytesView) } == framed(payloadBuffer.payload)
                    )
                    #expect(try encoder.finish().isClean)
                }
            }
        }

        /// Complete frames are all emitted, then EOF throws `truncated`
        /// exactly when the stream stops inside a length prefix or a body,
        /// whatever length that body declares up to the limit, and finishes
        /// clean when it stops on a frame boundary.
        @Test
        func endOfFileIsTruncatedExactlyInsideAFrame() throws {
            try property(
                reaching: ["a read ends inside a length prefix", "ends inside a length prefix"],
                reachingAfter: ["ends inside a body": 1_000, "ends on a frame boundary": 1_000]
            ) { tc in
                let payloads = try #draw(FramingGenerators.payloads, from: tc)
                let streamEnding = try #draw(FramingGenerators.streamEndings, from: tc)
                let largestPayload = UInt32(payloads.map(\.count).max() ?? 0)
                let maximumLength = try #draw(
                    FramingGenerators.atLeast(max(largestPayload, streamEnding.smallestLimit)),
                    from: tc
                )
                let wire = payloads.flatMap(framed) + streamEnding.bytes
                let chunkBoundaries = try #draw(
                    FramingGenerators.chunkBoundaries(
                        byteCount: wire.count,
                        frameStarts: frameOffsets(payloads)
                    ),
                    from: tc
                )
                try tc.event(streamEnding.label)
                try recordReadsSplittingPrefixes(
                    chunkBoundaries,
                    frameStarts: frameOffsets(payloads),
                    in: tc
                )

                let decoder = decoderChannel(maximumLength: maximumLength)
                try deliverCompleteFrames(
                    payloads,
                    wire: wire,
                    in: chunkRanges(byteCount: wire.count, chunkBoundaries: chunkBoundaries),
                    to: decoder
                )
                if case .frameBoundary = streamEnding {
                    #expect(try decoder.finish().isClean)
                } else {
                    #expect(throws: MMWireError.truncated) {
                        try decoder.finish()
                    }
                    #expect(try decoder.readInbound(as: ByteBuffer.self) == nil)
                }
            }
        }

        /// Removing the decoder without EOF is not an error, and, as its
        /// `decodeLast` documents, hands the unread bytes of an unfinished
        /// frame on down the pipeline after the complete frames.
        ///
        /// Mutation-checked: handing leftovers on only once a whole length
        /// prefix has arrived fails this with one byte of a prefix.
        @Test
        func removalHandsOnTheUnfinishedFrame() throws {
            try property(
                reaching: [
                    "a read ends inside a length prefix", "ends inside a body",
                    "ends inside a length prefix",
                ],
                reachingAfter: ["ends on a frame boundary": 1_000]
            ) { tc in
                let payloads = try #draw(FramingGenerators.payloads, from: tc)
                let streamEnding = try #draw(FramingGenerators.streamEndings, from: tc)
                let largestPayload = UInt32(payloads.map(\.count).max() ?? 0)
                let maximumLength = try #draw(
                    FramingGenerators.atLeast(max(largestPayload, streamEnding.smallestLimit)),
                    from: tc
                )
                let wire = payloads.flatMap(framed) + streamEnding.bytes
                let chunkBoundaries = try #draw(
                    FramingGenerators.chunkBoundaries(
                        byteCount: wire.count,
                        frameStarts: frameOffsets(payloads)
                    ),
                    from: tc
                )
                try tc.event(streamEnding.label)
                try recordReadsSplittingPrefixes(
                    chunkBoundaries,
                    frameStarts: frameOffsets(payloads),
                    in: tc
                )

                let handler = ByteToMessageHandler(MMFrameDecoder(maxFrameLength: maximumLength))
                let decoder = EmbeddedChannel(handler: handler)
                try deliverCompleteFrames(
                    payloads,
                    wire: wire,
                    in: chunkRanges(byteCount: wire.count, chunkBoundaries: chunkBoundaries),
                    to: decoder
                )
                let removal = decoder.pipeline.syncOperations.removeHandler(handler)
                decoder.embeddedEventLoop.run()
                try removal.wait()
                let handedOn = try emittedPayloads(decoder)
                #expect(Array(handedOn.joined()) == streamEnding.bytes)
                #expect(try decoder.finish().isClean)
            }
        }
    }

#endif

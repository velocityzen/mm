// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import Logging
    import MMWire
    import NIOConcurrencyHelpers
    import NIOCore
    import Testing

    @testable import MMClient
    @testable import MMServer

    /// The element types the stream element property sends: a scalar, a
    /// string, a structure, and an optional of each kind, whose nil is a
    /// value of its own and must not read as the stream's end.
    enum StreamElementKind: String, CaseIterable, Sendable {
        case integer = "integer"
        case text = "text"
        case optionalInteger = "optional integer"
        case fixture = "fixture"
        case optionalFixture = "optional fixture"
    }

    /// What a client stream wrote through its sinks: the items it sent, with
    /// their seqs, and how many ENDs.
    final class StreamFrameRecord: Sendable {
        struct Frames: Sendable {
            var seqs: [UInt32] = []
            var items: [ByteBuffer] = []
            var ends = 0
        }

        private let frames = NIOLockedValueBox(Frames())

        var current: Frames { self.frames.withLockedValue { $0 } }

        func item(_ seq: UInt32, _ item: ByteBuffer) -> Bool {
            self.frames.withLockedValue {
                $0.seqs.append(seq)
                $0.items.append(item)
            }
            return true
        }

        func end() {
            self.frames.withLockedValue { $0.ends += 1 }
        }

        var sinks: ClientStreamSinks {
            ClientStreamSinks(
                grantCredit: { _ in },
                sendItem: { seq, item in self.item(seq, item) },
                sendEnd: { self.end() },
                sendStop: {},
                sendCancel: {}
            )
        }
    }

    /// Sends `elements` through each stream whose producer carries elements
    /// as `any Sendable`, the server's request stream and the client's
    /// response stream, and through the client's typed sending half, and
    /// checks that each reader gets them back, compared through `same`. The
    /// client's terminal carries `response` the same way.
    func expectElementsCross<Element: Codable & Sendable, Same: Equatable & Sendable>(
        _ elements: [Element],
        response: Element,
        same: @escaping @Sendable (Element) -> Same,
        in tc: TestCase
    ) async throws {
        let encoded = try elements.map { try MMPackEncoder().encode($0).get() }
        let sent = elements.map(same)

        // The server's request stream: the stream table delivers each item,
        // then the client's END finishes it.
        let (source, stream) = MMRequestStream<Element>.make(
            msgid: 1,
            decoding: checkedDecoding(MMPackDecoder().decoding(Element.self), nil),
            frameSink: { _ in true },
            metrics: MMStreamMetrics()
        )
        for item in encoded {
            #expect(source.hasCreditForItem())
            if case .failure(let error) = source.deliver(item) {
                Issue.record("the server's stream refused an item: \(error)")
            }
        }
        source.finishFromEnd()
        // One read past what was sent ends the loop: a stream that doesn't
        // end fails here instead of reading forever.
        let handled = try await tc.withStallDetection(after: hangLimit) { _ in
            var handled: [Same] = []
            for await element in stream {
                handled.append(same(element))
                if handled.count > sent.count { break }
            }
            return handled
        }
        #expect(handled == sent, "the handler read \(handled), not \(sent)")

        // The client's response stream: the inbound loop validates and
        // delivers each item, then the server's END and terminal arrive.
        let inbound = ClientStreamState.make(
            msgid: 1,
            hasResponseStream: true,
            hasRequestStream: false,
            decoders: ClientStreamDecoders(inbound: Element.self, response: Element.self),
            sinks: StreamFrameRecord().sinks,
            logger: Logger(label: "mm.property.stream-elements"),
            metrics: ClientMetrics()
        )
        for (seq, item) in encoded.enumerated() {
            guard case .deliver = inbound.validateInboundItem(seq: UInt32(seq)) else {
                Issue.record("the client refused item \(seq)")
                continue
            }
            if case .dropped = inbound.deliverInboundItem(item) {
                Issue.record("the client dropped item \(seq)")
            }
        }
        inbound.serverEndInbound()
        inbound.resolveTerminal(
            ResponseSlots(error: nil, result: try MMPackEncoder().encode(response).get())
        )
        let handle = InboundStreamHandle<Element, Never, Element, MMCallError>(state: inbound)
        let read = try await tc.withStallDetection(after: hangLimit) { _ in
            var read: [Same] = []
            for await element in handle {
                read.append(same(element))
                if read.count > sent.count { break }
            }
            return read
        }
        #expect(read == sent, "the client read \(read), not \(sent)")
        let terminal = await handle.result().map(same)
        #expect(terminal == .success(same(response)), "the terminal was \(terminal)")

        // The client's request stream: the typed half encodes each element
        // before the credit gate, inside the initial window.
        let record = StreamFrameRecord()
        let outbound = OutboundStreamHandle<Element, Never, Element, MMCallError>(
            state: ClientStreamState.make(
                msgid: 1,
                hasResponseStream: false,
                hasRequestStream: true,
                decoders: ClientStreamDecoders(inbound: Never.self, response: Element.self),
                sinks: record.sinks,
                logger: Logger(label: "mm.property.stream-elements"),
                metrics: ClientMetrics()
            ),
            encode: MMPackEncoder().encoding(Element.self)
        )
        for element in elements {
            let outcome = await outbound.send(element)
            #expect(outcome == .sent, "a send ended \(outcome)")
        }
        await outbound.finish()
        let frames = record.current
        #expect(frames.seqs == (0..<elements.count).map { UInt32($0) })
        let received = frames.items.map {
            MMPackDecoder().decode(Element.self, from: $0).map(same)
        }
        #expect(received == sent.map { .success($0) }, "the server would read \(received)")
        #expect(frames.ends == 1)
    }

    @Suite("Stream element properties", .hegel)
    struct StreamElementProperties {
        /// Any run of elements, up to the initial window and of any element
        /// type, a nil optional included, comes out of the server's request
        /// stream and the client's response stream as it went in, and then
        /// the stream ends; the client's terminal carries the response the
        /// same way, and the client's sending half sends each element as
        /// its encoding, with seqs 0, 1, 2 on. Both producers carry elements
        /// as `any Sendable` and the readers cast them back, so this pins
        /// the erasure: nothing lost, reordered or retyped, and a nil
        /// element never read as the end.
        ///
        /// Mutation check: a server or client reader that casts what the
        /// producer returns straight to `Element?`, and so reads the
        /// stream's end as one more nil element when `Element` is optional,
        /// fails here and nowhere else. The credit properties catch a reader
        /// that skips its consumption accounting or its grant.
        ///
        /// Every claim is judged once 1,000 cases have passed. A 100-case
        /// run's share of each swings far around its mean, and none keeps
        /// to a fifth of every such run: each of five kinds is a fifth of
        /// the cases, a nil comes only with the two optional kinds, and even
        /// with the count weighted to its ends and one short of the window,
        /// no elements comes up in about a seventh of the cases, and a full
        /// window and one short of it each in about a quarter.
        @Test
        func elementsCrossTheStreamsAsTheyWereSent() async throws {
            let window = Int(MMStreamFlowControl.initialWindow)
            let kindClaims = StreamElementKind.allCases.map { ("\($0.rawValue) elements", 1_000) }
            try await property(
                reachingAfter: [
                    "no elements": 1_000, "a full window": 1_000,
                    "one short of a full window": 1_000, "a nil element": 1_000,
                    "a nil response": 1_000, "a nil element last": 1_000,
                ].merging(kindClaims) { $1 }
            ) { tc in
                let kind = try #draw(.element(of: StreamElementKind.allCases), from: tc)
                // No elements and a full window are where the stream ends at
                // once and where the sender uses every credit, and one short
                // of the window leaves a credit unused, so about half the
                // counts are one of the three, and the rest any count.
                let count = try #draw(
                    .oneOf(.element(of: [0, window - 1, window]), .int(in: 0...window)),
                    from: tc
                )
                try tc.event("\(kind.rawValue) elements")
                if count == 0 { try tc.event("no elements") }
                if count == window - 1 { try tc.event("one short of a full window") }
                if count == window { try tc.event("a full window") }
                switch kind {
                    case .integer:
                        try await expectElementsCross(
                            #draw(.array(of: .int(), count: count...count), from: tc),
                            response: #draw(.int(), from: tc),
                            same: { $0 },
                            in: tc
                        )
                    case .text:
                        try await expectElementsCross(
                            #draw(.array(of: Gen<String>.string(), count: count...count), from: tc),
                            response: #draw(Gen<String>.string(), from: tc),
                            same: { $0 },
                            in: tc
                        )
                    case .optionalInteger:
                        let elements = try #draw(
                            .array(of: .optional(Gen<Int>.int()), count: count...count),
                            from: tc
                        )
                        let response = try #draw(.optional(Gen<Int>.int()), from: tc)
                        try recordNils(elements, response: response, in: tc)
                        try await expectElementsCross(
                            elements,
                            response: response,
                            same: { $0 },
                            in: tc
                        )
                    case .fixture:
                        try await expectElementsCross(
                            #draw(
                                .array(of: WireGenerators.fixture, count: count...count),
                                from: tc
                            ),
                            response: #draw(WireGenerators.fixture, from: tc),
                            same: bitwise,
                            in: tc
                        )
                    case .optionalFixture:
                        let elements = try #draw(
                            .array(of: .optional(WireGenerators.fixture), count: count...count),
                            from: tc
                        )
                        let response = try #draw(.optional(WireGenerators.fixture), from: tc)
                        try recordNils(elements, response: response, in: tc)
                        try await expectElementsCross(
                            elements,
                            response: response,
                            same: { $0.map(bitwise) },
                            in: tc
                        )
                }
            }
        }

        /// Records, for the statistics report, a nil among the elements, a
        /// nil as the last one, just before the stream's end, and a nil
        /// response.
        private func recordNils<Wrapped>(
            _ elements: [Wrapped?],
            response: Wrapped?,
            in tc: TestCase
        ) throws {
            if elements.contains(where: { $0 == nil }) { try tc.event("a nil element") }
            if case .some(.none) = elements.last { try tc.event("a nil element last") }
            if response == nil { try tc.event("a nil response") }
        }
    }

#endif

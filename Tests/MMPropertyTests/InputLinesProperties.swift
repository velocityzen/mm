// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import Testing

    @testable import MMCLI

    @Suite("Input lines properties", .hegel)
    struct InputLinesProperties {
        /// However the input's bytes are split into reads, `lines` gives the
        /// lines a direct split of the whole input gives: on `\n`, with one
        /// trailing `\r` dropped, decoded as UTF-8, empty lines kept and an
        /// unterminated last line counted. A line longer than the limit fails
        /// once, at that line, and nothing follows it. A read failure fails
        /// after the lines that came before it, unless the partial line
        /// already read is too long whatever its end, which fails as too
        /// long instead.
        ///
        /// The limit is any `Int`: its edges, either side of 0, and small
        /// limits the drawn lines sit at, one under, and one or two over,
        /// with and without a carriage return before the break. A negative
        /// limit refuses every line, but an input with no lines has none to
        /// refuse.
        ///
        /// It reads at most one element past the expected ones, so a splitter
        /// that never ends fails here instead of hanging.
        ///
        /// This property found a limit of `Int.max` overflowing the
        /// splitter's early check, and a limit of -2 or below failing an
        /// input with no lines.
        ///
        /// Mutation check: with the early refusal of a partial line a byte
        /// too soon, gone, overflowing again or firing with no byte read; the
        /// limit exclusive; the trailing `\r` kept, or looked for at the
        /// front; a failure that keeps its buffer or does not end the lines;
        /// compaction that loses the scan position; an empty last line after
        /// a final break; or returned lines counted as pending, this fails
        /// in a 100-case run.
        @Test
        func readBoundariesLeaveTheLinesAlone() async throws {
            try await property { tc in
                let source = try InputLinesSource.draw(tc)
                for label in source.labels.sorted() {
                    try tc.event(label)
                }
                let lines = MMCLIInput(reads: source.reads)
                    .lines(maximumLength: source.maximumLength)
                // One element past the expected ones is already wrong, and a
                // splitter that never ends would otherwise hang the case.
                var seen: [LineOutcome] = []
                for await element in lines {
                    seen.append(LineOutcome(element))
                    if seen.count > source.expected.count { break }
                }
                #expect(
                    seen == source.expected,
                    "limit \(source.maximumLength), reads \(source.reads.map(InputLinesSource.text))"
                )
            }
        }

        /// An interrupt between lines ends them at once: the next element is
        /// the end, even with lines still buffered from a read, and the
        /// lines before it were the input's first lines.
        ///
        /// Mutation check: a splitter that still hands out its buffered lines
        /// once interrupted fails only here, in a 100-case run.
        @Test
        func anInterruptEndsTheLinesAtOnce() async throws {
            try await property { tc in
                let source = try InputLinesSource.draw(tc)
                let taken = try #draw(Gen<Int>.int(in: 0...source.expected.count), from: tc)
                if taken == 0 {
                    try tc.event("interrupted before the first line")
                } else if taken < source.expected.count {
                    try tc.event("interrupted between lines")
                } else {
                    try tc.event("interrupted after the last line")
                }
                let input = MMCLIInput(reads: source.reads)
                var lines = input.lines(maximumLength: source.maximumLength).makeAsyncIterator()
                var seen: [LineOutcome] = []
                for _ in 0..<taken {
                    guard let element = await lines.next() else { break }
                    seen.append(LineOutcome(element))
                }
                input.interrupt()
                let afterInterrupt = await lines.next().map(LineOutcome.init)
                #expect(seen == Array(source.expected.prefix(taken)))
                #expect(afterInterrupt == nil)
            }
        }
    }

    /// One element of `lines`, comparable: a line by its UTF-8 bytes, so
    /// canonically equivalent text never passes for the same line.
    enum LineOutcome: Equatable, CustomStringConvertible {
        case line([UInt8])
        case tooLong(limit: Int)
        case readFailed(source: String, reason: String)
        case otherFailure(String)

        init(_ element: Result<String, MMCLIError>) {
            switch element {
                case .success(let text):
                    self = .line(Array(text.utf8))
                case .failure(.lineTooLong(let limit)):
                    self = .tooLong(limit: limit)
                case .failure(.inputReadFailed(let source, let reason)):
                    self = .readFailed(source: source, reason: reason)
                case .failure(let error):
                    self = .otherFailure(error.localizedDescription)
            }
        }

        var description: String {
            switch self {
                case .line(let bytes): return "line \(InputLinesSource.text(bytes))"
                case .tooLong(let limit): return "too long (limit \(limit))"
                case .readFailed(let source, let reason):
                    return "read failed (\(source): \(reason))"
                case .otherFailure(let message): return "failed: \(message)"
            }
        }
    }

    /// An input drawn as lines, split into reads, with what `lines` must
    /// give for it and the reach labels it covers.
    struct InputLinesSource {
        var maximumLength: Int
        var reads: [Result<[UInt8], MMCLIError>]
        var expected: [LineOutcome]
        var labels: Set<String>

        static let lineFeed = UInt8(ascii: "\n")
        static let carriageReturn = UInt8(ascii: "\r")

        /// The failure a drawn read fails with.
        static let readFailure = MMCLIError.inputReadFailed(source: "pipe", reason: "drawn")

        /// The edges of `Int`, and either side of 0; small limits lines are
        /// drawn around come from a range besides.
        static let limitEdges = [Int.min, -2, -1, 0, 1, Int.max - 1, Int.max]

        /// What a line's content is made of: ASCII, a bare carriage return,
        /// NUL, two-, three- and four-byte UTF-8 characters, and bytes that
        /// are not UTF-8 (a lone continuation byte, a lead byte, 0xFF).
        static let pieces: [[UInt8]] = [
            Array("a".utf8), Array("b".utf8), [carriageReturn], [0x00],
            Array("é".utf8), Array("€".utf8), Array("🎵".utf8),
            [0x80], [0xC3], [0xFF],
        ]

        /// How a line's content length is drawn.
        enum LineLength {
            /// At most the limit, so the lines go on past it.
            case fitting
            /// At the limit or one or two past it, or short.
            case any
            /// For a partial line a read failure cuts off: the limit, or
            /// one or two past it, where the splitter's early refusal turns.
            case partial
        }

        static func draw(_ tc: TestCase) throws -> InputLinesSource {
            // Small limits twice as often as the edges, so that fewer cases
            // end at the first line on a negative limit.
            let limit = try #draw(
                Gen<Int>.oneOf(.element(of: limitEdges), .int(in: 0...6), .int(in: 0...6)),
                from: tc
            )
            let failed = try #draw(Gen<Bool>.bool(probability: 1.0 / 3), from: tc)
            let fitting = try failed || #draw(Gen<Bool>.bool(), from: tc)
            let lineCount = try #draw(Gen<Int>.int(in: 0...5), from: tc)
            var bytes: [UInt8] = []
            for index in 0..<lineCount {
                let last = index == lineCount - 1
                let length: LineLength =
                    last ? (failed ? .partial : .any) : (fitting ? .fitting : .any)
                bytes += try drawContent(limit: limit, length, tc)
                let unterminated =
                    try last && #draw(Gen<Bool>.bool(probability: failed ? 0.8 : 0.5), from: tc)
                let breaks = unterminated ? ["", "\r"] : ["\n", "\r\n"]
                bytes += Array(try #draw(Gen<String>.element(of: breaks), from: tc).utf8)
            }
            let ends = try drawReadEnds(count: bytes.count, tc)

            var reads: [Result<[UInt8], MMCLIError>] = []
            var start = 0
            for end in ends {
                reads.append(.success(Array(bytes[start..<end])))
                start = end
            }
            if failed {
                reads.append(.failure(readFailure))
            }
            var source = InputLinesSource(
                maximumLength: limit,
                reads: reads,
                expected: [],
                labels: []
            )
            source.split(bytes, failed: failed, readEnds: ends)
            return source
        }

        /// A line's content: around the limit when lines can reach it,
        /// otherwise short, cut to its length whatever that cuts.
        private static func drawContent(limit: Int, _ length: LineLength, _ tc: TestCase) throws
            -> [UInt8]
        {
            let small = (0...6).contains(limit)
            let lengths: Gen<Int>
            switch (length, small) {
                case (.fitting, true):
                    lengths = .oneOf(
                        .element(of: [0, max(limit - 1, 0), limit]),
                        .int(in: 0...limit)
                    )
                case (.any, true):
                    let nearLimit = [limit - 1, limit, limit + 1, limit + 2].filter { $0 >= 0 }
                    lengths = .oneOf(.element(of: [0] + nearLimit), .int(in: 0...4))
                case (.partial, true):
                    lengths = .oneOf(.element(of: [limit, limit + 1, limit + 2]), .int(in: 0...4))
                case (_, false):
                    lengths = .int(in: 0...4)
            }
            let count = try #draw(lengths, from: tc)
            let drawn = try #draw(
                Gen<[[UInt8]]>.array(of: .element(of: pieces), count: 0...count),
                from: tc
            )
            let content = Array(drawn.joined()) + Array(repeating: UInt8(ascii: "a"), count: count)
            return Array(content.prefix(count))
        }

        /// Where each read ends: the whole input at once, a byte at a time,
        /// or cut at a few drawn places. No read is empty: a descriptor's
        /// empty read is its end.
        private static func drawReadEnds(count: Int, _ tc: TestCase) throws -> [Int] {
            guard count > 0 else { return [] }
            let shape = try #draw(Gen<Int>.int(in: 0...7), from: tc)
            switch shape {
                case 0:
                    return [count]
                case 1:
                    return Array(1...count)
                default:
                    let cuts = try #draw(
                        Gen<[Int]>.array(of: .int(in: 1...count), count: 1...4),
                        from: tc
                    )
                    return Array(Set(cuts + [count])).sorted()
            }
        }

        /// The direct split: every line in turn, the first too-long one
        /// ending them, then the last unterminated line or the read failure.
        private mutating func split(_ bytes: [UInt8], failed: Bool, readEnds: [Int]) {
            let limit = self.maximumLength
            self.labelReads(bytes, readEnds: readEnds)
            if limit < 0 {
                self.labels.insert("negative limit")
            } else if limit > Int.max - 2 {
                self.labels.insert("limit at the top of Int")
            } else if limit == 0 {
                self.labels.insert("limit 0")
            }

            var lineStart = 0
            for (index, byte) in bytes.enumerated() where byte == Self.lineFeed {
                guard self.take(bytes[lineStart..<index], readEnds: readEnds, terminated: true)
                else {
                    return
                }
                lineStart = index + 1
            }
            let rest = bytes[lineStart...]
            if failed {
                self.labels.insert(
                    rest.isEmpty ? "read failure between lines" : "read failure inside a line"
                )
                // The splitter refuses a partial line too long whatever its
                // end; no partial line is nothing to refuse.
                if !rest.isEmpty && rest.count - 1 > limit {
                    self.labels.insert("read failure after an over-long partial line")
                    self.expected.append(.tooLong(limit: limit))
                } else {
                    if !rest.isEmpty && rest.count - 1 == limit {
                        self.labels.insert("read failure after a partial line one past the limit")
                    }
                    self.expected.append(.readFailed(source: "pipe", reason: "drawn"))
                }
            } else if !rest.isEmpty {
                self.labels.insert(
                    rest.last == Self.carriageReturn
                        ? "input ends in a carriage return" : "unterminated last line"
                )
                _ = self.take(rest, readEnds: readEnds, terminated: false)
            }
            if self.expected.isEmpty {
                self.labels.insert("no lines")
            }
        }

        /// Adds one line, or its failure. Whether the lines go on.
        private mutating func take(_ line: ArraySlice<UInt8>, readEnds: [Int], terminated: Bool)
            -> Bool
        {
            let limit = self.maximumLength
            let hasReturn = line.last == Self.carriageReturn
            let content = hasReturn ? line.dropLast() : line
            if hasReturn && terminated { self.labels.insert("CRLF line break") }
            if content.contains(Self.carriageReturn) {
                self.labels.insert("carriage return inside a line")
            }
            if content.isEmpty { self.labels.insert("empty line") }
            if String(validating: content, as: UTF8.self) == nil { self.labels.insert("not UTF-8") }
            if content.count == limit {
                self.labels.insert(
                    hasReturn ? "line at the limit, then a carriage return" : "line at the limit"
                )
            }
            guard content.count <= limit else {
                self.labels.insert(
                    content.count - 1 == limit
                        ? "line one past the limit" : "line far past the limit"
                )
                // A read that ends before the line's break, past `limit + 1` bytes of it.
                if readEnds.contains(where: {
                    $0 <= line.endIndex && $0 - line.startIndex - 1 > limit
                }) {
                    self.labels.insert("too long before its line break was read")
                }
                self.expected.append(.tooLong(limit: limit))
                return false
            }
            self.expected.append(.line(Array(String(decoding: content, as: UTF8.self).utf8)))
            return true
        }

        private mutating func labelReads(_ bytes: [UInt8], readEnds: [Int]) {
            switch readEnds.count {
                case 0: self.labels.insert("empty input")
                case 1: self.labels.insert("one read")
                case bytes.count: self.labels.insert("a byte per read")
                default: self.labels.insert("several reads")
            }
            for end in readEnds where end < bytes.count {
                if bytes[end - 1] == Self.carriageReturn && bytes[end] == Self.lineFeed {
                    self.labels.insert("CRLF split between reads")
                }
                if bytes[end] & 0xC0 == 0x80 {
                    self.labels.insert("read ends before a continuation byte")
                }
            }
        }

        /// Bytes as readable text, for failure messages.
        static func text(_ bytes: [UInt8]) -> String {
            String(reflecting: String(decoding: bytes, as: UTF8.self))
        }

        static func text(_ read: Result<[UInt8], MMCLIError>) -> String {
            switch read {
                case .success(let bytes): return text(bytes)
                case .failure: return "<read failure>"
            }
        }
    }

#endif

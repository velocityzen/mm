// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import Testing

    /// A MessagePack value as the per-family readers return it. Floats keep
    /// their bit patterns and strings their UTF-8 bytes, so NaN, -0.0 and
    /// strings that are canonically equivalent but spelled differently only
    /// compare equal when they are the same bytes.
    indirect enum PackValue: Equatable, Sendable {
        case null
        case bool(Bool)
        /// Any integer `readMessagePackInt` returns.
        case integer(Int64)
        /// An integer above `Int64.max`, which only `readMessagePackUInt` returns.
        case largeUnsigned(UInt64)
        case float(bits: UInt32)
        case double(bits: UInt64)
        case string(utf8: [UInt8])
        case binary([UInt8])
        case array([PackValue])
        case map([PackEntry])
        case ext(type: Int8, payload: [UInt8])
    }

    struct PackEntry: Equatable, Sendable {
        var key: PackValue
        var value: PackValue
    }

    /// Reads one value with the per-family readers, picking each by the
    /// format byte, as a generic decoder would. A container at nesting level
    /// `maxDepth` or deeper fails with `nestingTooDeep` once its header is
    /// read, as `skipMessagePackValue` documents. On failure the reader index
    /// is restored.
    func readPackValue(from buffer: inout ByteBuffer, maxDepth: Int) -> Result<
        PackValue, MMWireError
    > {
        let start = buffer.readerIndex
        let result = readPackValue(from: &buffer, level: 0, maxDepth: maxDepth)
        if case .failure = result {
            buffer.moveReaderIndex(to: start)
        }
        return result
    }

    private func readPackValue(
        from buffer: inout ByteBuffer,
        level: Int,
        maxDepth: Int
    ) -> Result<PackValue, MMWireError> {
        guard let format = buffer.peekMessagePackFormat() else {
            return .failure(.truncated)
        }
        func elements(_ count: Int) -> Result<[PackValue], MMWireError> {
            guard level < maxDepth else {
                return .failure(.nestingTooDeep(limit: maxDepth))
            }
            var elements: [PackValue] = []
            for _ in 0..<count {
                switch readPackValue(from: &buffer, level: level + 1, maxDepth: maxDepth) {
                    case .success(let element): elements.append(element)
                    case .failure(let error): return .failure(error)
                }
            }
            return .success(elements)
        }
        switch format {
            case 0xc0:
                return buffer.readMessagePackNil().map { .null }
            case 0xc2, 0xc3:
                return buffer.readMessagePackBool().map(PackValue.bool)
            case 0x00...0x7f, 0xe0...0xff, 0xcc...0xd3:
                switch buffer.readMessagePackInt() {
                    case .success(let integer): return .success(.integer(integer))
                    case .failure(.numberOutOfRange):
                        return buffer.readMessagePackUInt().map(PackValue.largeUnsigned)
                    case .failure(let error): return .failure(error)
                }
            case 0xca:
                return buffer.readMessagePackFloat().map { .float(bits: $0.bitPattern) }
            case 0xcb:
                return buffer.readMessagePackDouble().map { .double(bits: $0.bitPattern) }
            case 0xa0...0xbf, 0xd9...0xdb:
                return buffer.readMessagePackString().map { .string(utf8: Array($0.utf8)) }
            case 0xc4...0xc6:
                return buffer.readMessagePackBinary().map { .binary(Array($0.readableBytesView)) }
            case 0xc7...0xc9, 0xd4...0xd8:
                return buffer.readMessagePackExt().map {
                    .ext(type: $0.type, payload: Array($0.payload.readableBytesView))
                }
            case 0x90...0x9f, 0xdc, 0xdd:
                return buffer.readMessagePackArrayHeader().flatMap(elements).map(PackValue.array)
            case 0x80...0x8f, 0xde, 0xdf:
                return buffer.readMessagePackMapHeader().flatMap { elements(2 * $0) }.map { flat in
                    .map(
                        stride(from: 0, to: flat.count, by: 2).map {
                            PackEntry(key: flat[$0], value: flat[$0 + 1])
                        }
                    )
                }
            default:
                // 0xc1 is the one byte MessagePack never uses.
                return .failure(.invalidFormat(byte: format))
        }
    }

    /// Writes `value` with the public writers, which pick the narrowest
    /// encoding of each value.
    func writePackValue(_ value: PackValue, into buffer: inout ByteBuffer) {
        switch value {
            case .null: buffer.writeMessagePackNil()
            case .bool(let bool): buffer.writeMessagePackBool(bool)
            case .integer(let integer): buffer.writeMessagePackInt(integer)
            case .largeUnsigned(let integer): buffer.writeMessagePackUInt(integer)
            case .float(let bits): buffer.writeMessagePackFloat(Float(bitPattern: bits))
            case .double(let bits): buffer.writeMessagePackDouble(Double(bitPattern: bits))
            // Read through validation, so these bytes are valid UTF-8.
            case .string(let utf8):
                buffer.writeMessagePackString(String(decoding: utf8, as: UTF8.self))
            case .binary(let bytes): buffer.writeMessagePackBinary(bytes: bytes)
            case .array(let elements):
                buffer.writeMessagePackArrayHeader(count: elements.count)
                for element in elements {
                    writePackValue(element, into: &buffer)
                }
            case .map(let entries):
                buffer.writeMessagePackMapHeader(count: entries.count)
                for entry in entries {
                    writePackValue(entry.key, into: &buffer)
                    writePackValue(entry.value, into: &buffer)
                }
            case .ext(let type, let payload):
                buffer.writeMessagePackExt(type: type, payload: ByteBuffer(bytes: payload))
        }
    }

    /// The length of `value`'s narrowest MessagePack encoding: the fix
    /// format when one holds it, else the narrowest length or count field,
    /// and a fixext for a payload of 1, 2, 4, 8 or 16 bytes. Floats keep
    /// their width.
    func narrowestLength(of value: PackValue) -> Int {
        func lengthField(_ count: Int) -> Int {
            count <= Int(UInt8.max) ? 1 : count <= Int(UInt16.max) ? 2 : 4
        }
        func countField(_ count: Int) -> Int {
            count < 16 ? 0 : count <= Int(UInt16.max) ? 2 : 4
        }
        switch value {
            case .null, .bool: return 1
            case .integer(let integer):
                return PackGenerators.integerEncodings(integer).map(\.count).min()!
            case .largeUnsigned: return 9
            case .float: return 5
            case .double: return 9
            case .string(let utf8):
                return 1 + (utf8.count < 32 ? 0 : lengthField(utf8.count)) + utf8.count
            case .binary(let bytes): return 1 + lengthField(bytes.count) + bytes.count
            case .ext(_, let payload):
                let fixed = [1, 2, 4, 8, 16].contains(payload.count)
                return 2 + (fixed ? 0 : lengthField(payload.count)) + payload.count
            case .array(let elements):
                return 1 + countField(elements.count) + elements.map(narrowestLength).reduce(0, +)
            case .map(let entries):
                return 1 + countField(entries.count)
                    + entries.map { narrowestLength(of: $0.key) + narrowestLength(of: $0.value) }
                    .reduce(0, +)
        }
    }

    func bigEndianBytes<Integer: FixedWidthInteger>(_ value: Integer) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    /// Bytes for a reader to read, and a constant label for how they were
    /// made, for the statistics report.
    struct ReaderInput: Sendable {
        var kind: String
        var bytes: [UInt8]
    }

    /// MessagePack values in any encoding that can hold them, and inputs made
    /// from them. Hegel shrinks toward the narrowest encodings.
    enum PackGenerators {
        /// Any header that can declare `count`.
        static func headers(
            count: Int,
            fix: (base: UInt8, limit: Int)?,
            eightBit: UInt8?,
            sixteenBit: UInt8,
            thirtyTwoBit: UInt8
        ) -> Gen<[UInt8]> {
            .element(
                of: headerOptions(
                    count: count,
                    fix: fix,
                    eightBit: eightBit,
                    sixteenBit: sixteenBit,
                    thirtyTwoBit: thirtyTwoBit
                )
            )
        }

        /// Every header that can declare `count`, narrowest first: the fix
        /// format when it holds `count`, then the 8-, 16- and 32-bit ones
        /// that do.
        static func headerOptions(
            count: Int,
            fix: (base: UInt8, limit: Int)?,
            eightBit: UInt8?,
            sixteenBit: UInt8,
            thirtyTwoBit: UInt8
        ) -> [[UInt8]] {
            var options: [[UInt8]] = []
            if let fix, count < fix.limit {
                options.append([fix.base | UInt8(count)])
            }
            if let eightBit, count <= Int(UInt8.max) {
                options.append([eightBit, UInt8(count)])
            }
            if count <= Int(UInt16.max) {
                options.append([sixteenBit] + bigEndianBytes(UInt16(count)))
            }
            options.append([thirtyTwoBit] + bigEndianBytes(UInt32(count)))
            return options
        }

        /// Every integer format that holds `value`, of either signedness.
        static func integerEncodings(_ value: Int64) -> [[UInt8]] {
            var options: [[UInt8]] = []
            if (0...127).contains(value) || (-32 ... -1).contains(value) {
                options.append([UInt8(truncatingIfNeeded: value)])
            }
            if let unsigned = UInt8(exactly: value) {
                options.append([0xcc] + bigEndianBytes(unsigned))
            }
            if let unsigned = UInt16(exactly: value) {
                options.append([0xcd] + bigEndianBytes(unsigned))
            }
            if let unsigned = UInt32(exactly: value) {
                options.append([0xce] + bigEndianBytes(unsigned))
            }
            if let unsigned = UInt64(exactly: value) {
                options.append([0xcf] + bigEndianBytes(unsigned))
            }
            if let signed = Int8(exactly: value) { options.append([0xd0] + bigEndianBytes(signed)) }
            if let signed = Int16(exactly: value) {
                options.append([0xd1] + bigEndianBytes(signed))
            }
            if let signed = Int32(exactly: value) {
                options.append([0xd2] + bigEndianBytes(signed))
            }
            options.append([0xd3] + bigEndianBytes(value))
            return options
        }

        /// Any `Int64`, often at a format's edge.
        /// The integers on either side of each format's edge.
        static let integerEdges: [Int64] = [
            0, 127, 128, -32, -33, 255, 256, -128, -129, 65_535, 65_536, -32_768, -32_769,
            Int64(UInt32.max), Int64(UInt32.max) + 1, Int64(Int32.min), Int64(Int32.min) - 1,
            .max, .min,
        ]

        static let integers: Gen<Int64> = .oneOf(.integer(), .element(of: integerEdges))

        /// String payloads: valid UTF-8 or any bytes, often 31/32 or 255/256
        /// bytes long, where a fixstr and a str8 run out.
        static let stringPayloads: Gen<[UInt8]> = .oneOf(
            Gen<String>.string().map { Array($0.utf8) },
            .bytes(),
            Gen<String>.string(of: .ascii, count: 31...32).map { Array($0.utf8) },
            Gen<String>.string(of: .ascii, count: 255...256).map { Array($0.utf8) }
        )

        /// Binary and ext payloads, often 255/256 bytes long, where a bin8
        /// and an ext8 run out.
        static let payloads: Gen<[UInt8]> = .oneOf(.bytes(), .bytes(count: 255...256))

        /// Every header that can declare an ext payload of `count` bytes: the
        /// fixext format when one holds exactly `count`, and the ext8, ext16
        /// and ext32 ones that do.
        static func extHeaders(count: Int) -> Gen<[UInt8]> {
            let fixed: [Int: UInt8] = [1: 0xd4, 2: 0xd5, 4: 0xd6, 8: 0xd7, 16: 0xd8]
            let wide = headers(
                count: count,
                fix: nil,
                eightBit: 0xc7,
                sixteenBit: 0xc8,
                thirtyTwoBit: 0xc9
            )
            guard let format = fixed[count] else { return wide }
            return .oneOf(.just([format]), wide)
        }

        /// Doubles of every kind, often NaN, -0.0, an infinity, or one a
        /// `Float` holds exactly, which `readMessagePackFloat` accepts from a
        /// float64.
        static let doubles: Gen<Double> = .oneOf(
            .double(),
            Gen<Float>.float().map(Double.init),
            .element(of: [.nan, -0.0, .infinity, -.infinity])
        )

        /// One generator per scalar family, so each can be drawn as often as
        /// a container.
        static let scalarFamilies: [Gen<[UInt8]>] = [
            .just([0xc0]),
            Gen<Bool>.bool().map { [$0 ? 0xc3 : 0xc2] },
            integers.flatMap { .element(of: integerEncodings($0)) },
            Gen<UInt64>.integer(in: UInt64(Int64.max) + 1...UInt64.max).map {
                [0xcf] + bigEndianBytes($0)
            },
            Gen<Float>.float().map { [0xca] + bigEndianBytes($0.bitPattern) },
            doubles.map { [0xcb] + bigEndianBytes($0.bitPattern) },
            stringPayloads.flatMap { payload in
                headers(
                    count: payload.count,
                    fix: (0xa0, 32),
                    eightBit: 0xd9,
                    sixteenBit: 0xda,
                    thirtyTwoBit: 0xdb
                )
                .map { $0 + payload }
            },
            payloads.flatMap { payload in
                headers(
                    count: payload.count,
                    fix: nil,
                    eightBit: 0xc4,
                    sixteenBit: 0xc5,
                    thirtyTwoBit: 0xc6
                )
                .map { $0 + payload }
            },
            Hegel.zip(Gen<Int8>.integer(), payloads).flatMap { type, payload in
                extHeaders(count: payload.count).map { $0 + [UInt8(bitPattern: type)] + payload }
            },
        ]

        /// Any number of elements, often 15 to 17, where a fixarray and a
        /// fixmap run out.
        static func counts<Element>(of element: Gen<Element>) -> Gen<[Element]> {
            .oneOf(.array(of: element), .array(of: element, count: 15...17))
        }

        /// One encoded value from the given scalar families: as often a
        /// scalar as a container nested as deep as Hegel chooses.
        static func values(of families: [Gen<[UInt8]>]) -> Gen<[UInt8]> {
            .oneOf(
                .oneOf(families),
                .recursive(leaf: .oneOf(families)) { element in
                    .oneOf(
                        counts(of: element).flatMap { elements in
                            headers(
                                count: elements.count,
                                fix: (0x90, 16),
                                eightBit: nil,
                                sixteenBit: 0xdc,
                                thirtyTwoBit: 0xdd
                            )
                            .map { $0 + elements.joined() }
                        },
                        counts(of: Hegel.zip(element, element).map { $0 + $1 }).flatMap { entries in
                            headers(
                                count: entries.count,
                                fix: (0x80, 16),
                                eightBit: nil,
                                sixteenBit: 0xde,
                                thirtyTwoBit: 0xdf
                            )
                            .map { $0 + entries.joined() }
                        }
                    )
                }
            )
        }

        /// A whole value, a value with bytes after it, a strict prefix of one,
        /// a corrupted one, or any bytes at all.
        static func inputs(of values: Gen<[UInt8]>) -> Gen<ReaderInput> {
            .oneOf(
                values.map { ReaderInput(kind: "a whole value", bytes: $0) },
                Hegel.zip(values, Gen<[UInt8]>.bytes(count: 1...Int.max)).map {
                    ReaderInput(kind: "a value and bytes after it", bytes: $0 + $1)
                },
                values.flatMap { bytes in
                    Gen<Int>.int(in: 0...bytes.count - 1).map {
                        ReaderInput(
                            kind: "a strict prefix of a value",
                            bytes: Array(bytes.prefix($0))
                        )
                    }
                },
                Hegel.zip(values, mutations).map {
                    ReaderInput(kind: "a corrupted value", bytes: mutated($0, by: $1))
                },
                // 0xc1 is the one byte no value starts with, and one replaced
                // byte rarely lands where a value starts, so it is often put
                // first.
                Hegel.zip(values, .oneOf(.just(0), .int(in: 0...Int.max))).map {
                    ReaderInput(
                        kind: "a value with 0xc1 inserted",
                        bytes: mutated($0, by: [.insert(0xc1, at: $1)])
                    )
                },
                Gen<[UInt8]>.bytes().map { ReaderInput(kind: "any bytes", bytes: $0) }
            )
        }

        /// Inputs whose values draw from a set of scalar families picked per
        /// case, all of them when none is picked. A case with few families
        /// fills its containers with them, which reaches each family's edges
        /// far more often than a draw over all nine.
        static let inputs: Gen<ReaderInput> = Gen<[Bool]>.array(
            of: .bool(),
            count: scalarFamilies.count...scalarFamilies.count
        )
        .flatMap { picked in
            let families = zip(scalarFamilies, picked).filter(\.1).map(\.0)
            return inputs(of: values(of: families.isEmpty ? scalarFamilies : families))
        }

        /// Any nesting limit, often none at all, the shallowest ones, or the
        /// default.
        static let nestingLimits: Gen<Int> = .oneOf(
            .element(of: [0, 1, 2, 128]),
            .int(in: 0...32),
            .int()
        )
    }

    /// `bytes` in a buffer whose reader index has already passed
    /// `alreadyRead`, as a reader inside a larger message sees them.
    func buffer(after alreadyRead: [UInt8], holding bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBuffer(bytes: alreadyRead + bytes)
        buffer.moveReaderIndex(forwardBy: alreadyRead.count)
        return buffer
    }

    struct NamedReader {
        let name: String
        let read: (inout ByteBuffer) -> Result<Void, MMWireError>
    }

    /// Every public MessagePack reader, its value dropped.
    func messagePackReaders(maxDepth: Int) -> [NamedReader] {
        [
            NamedReader(name: "readMessagePackNil") { $0.readMessagePackNil() },
            NamedReader(name: "readMessagePackBool") { $0.readMessagePackBool().map { _ in } },
            NamedReader(name: "readMessagePackInt") { $0.readMessagePackInt().map { _ in } },
            NamedReader(name: "readMessagePackUInt") { $0.readMessagePackUInt().map { _ in } },
            NamedReader(name: "readMessagePackDouble") { $0.readMessagePackDouble().map { _ in } },
            NamedReader(name: "readMessagePackFloat") { $0.readMessagePackFloat().map { _ in } },
            NamedReader(name: "readMessagePackString") { $0.readMessagePackString().map { _ in } },
            NamedReader(name: "readMessagePackBinary") { $0.readMessagePackBinary().map { _ in } },
            NamedReader(name: "readMessagePackArrayHeader") {
                $0.readMessagePackArrayHeader().map { _ in }
            },
            NamedReader(name: "readMessagePackMapHeader") {
                $0.readMessagePackMapHeader().map { _ in }
            },
            NamedReader(name: "readMessagePackExt") { $0.readMessagePackExt().map { _ in } },
            NamedReader(name: "skipMessagePackValue") {
                $0.skipMessagePackValue(maxDepth: maxDepth)
            },
            NamedReader(name: "readMessagePackRawValueSlice") {
                $0.readMessagePackRawValueSlice(maxDepth: maxDepth).map { _ in }
            },
        ]
    }

    /// Records, for the statistics report, the edges a read value reaches:
    /// the formats that only hold it past a fix or 8-bit length, and the
    /// values only one reader or one width returns.
    func recordShapes(of value: PackValue, in tc: TestCase) throws {
        var shapes: Set<String> = []
        func visit(_ value: PackValue, level: Int) {
            switch value {
                case .integer(let integer) where PackGenerators.integerEdges.contains(integer):
                    shapes.insert("an integer at a format's edge")
                case .largeUnsigned: shapes.insert("an integer above Int64.max")
                case .float: shapes.insert("a float32")
                case .double(let bits) where Double(bitPattern: bits).isNaN:
                    shapes.insert("a NaN float64")
                case .string(let utf8) where utf8.count > Int(UInt8.max):
                    shapes.insert("a string past str8")
                case .string(let utf8) where utf8.count >= 32: shapes.insert("a string past fixstr")
                case .binary(let bytes) where bytes.count > Int(UInt8.max):
                    shapes.insert("a binary past bin8")
                case .ext(_, let payload) where payload.count > Int(UInt8.max):
                    shapes.insert("an ext past ext8")
                case .ext: shapes.insert("an ext")
                case .array(let elements):
                    if elements.count >= 16 { shapes.insert("an array past fixarray") }
                    if level > 0 { shapes.insert("a container in a container") }
                    for element in elements { visit(element, level: level + 1) }
                case .map(let entries):
                    if entries.count >= 16 { shapes.insert("a map past fixmap") }
                    if level > 0 { shapes.insert("a container in a container") }
                    for entry in entries {
                        visit(entry.key, level: level + 1)
                        visit(entry.value, level: level + 1)
                    }
                default: break
            }
        }
        visit(value, level: 0)
        for shape in shapes.sorted() {
            try tc.event(shape)
        }
    }

    func failure<Value>(_ result: Result<Value, MMWireError>) -> MMWireError? {
        if case .failure(let error) = result { error } else { nil }
    }

    @Suite("MessagePack reader properties", .hegel, .offTheCooperativePool)
    struct MessagePackReaderProperties {
        /// Every reader, given any bytes at any reader index, returns a value
        /// or an `MMWireError`. A success consumes at least the format byte
        /// and no more than is readable; a failure leaves the reader index
        /// where it was, and a type mismatch names the format byte it found.
        ///
        /// Mutation-checked: a string reader that leaves the index past the
        /// header when the bytes are not UTF-8 fails this.
        @Test
        func readersRestoreTheIndexOnFailure() throws {
            try property(
                reaching: [
                    "readMessagePackRawValueSlice failed on its own format",
                    "readMessagePackRawValueSlice read a value",
                    "skipMessagePackValue failed on its own format",
                    "skipMessagePackValue read a value",
                ],
                reachingAfter: [
                    "a corrupted value": 1_000, "a strict prefix of a value": 1_000,
                    "a value and bytes after it": 1_000, "a value with 0xc1 inserted": 1_000,
                    "a whole value": 1_000, "any bytes": 1_000,
                    "readMessagePackArrayHeader read a value": 1_000,
                    "readMessagePackBinary failed on its own format": 1_000,
                    "readMessagePackBinary read a value": 1_000,
                    "readMessagePackDouble read a value": 1_000,
                    "readMessagePackFloat read a value": 1_000,
                    "readMessagePackInt failed on its own format": 1_000,
                    "readMessagePackInt read a value": 1_000,
                    "readMessagePackMapHeader read a value": 1_000,
                    "readMessagePackString failed on its own format": 1_000,
                    "readMessagePackUInt failed on its own format": 1_000,
                    "readMessagePackUInt read a value": 1_000,
                ]
            ) { tc in
                let input = try #draw(PackGenerators.inputs, from: tc)
                let alreadyRead = try #draw(Gen<[UInt8]>.bytes(), from: tc)
                let maxDepth = try #draw(PackGenerators.nestingLimits, from: tc)
                try tc.event(input.kind)
                let start = buffer(after: alreadyRead, holding: input.bytes)
                for reader in messagePackReaders(maxDepth: maxDepth) {
                    var buffer = start
                    switch reader.read(&buffer) {
                        case .success:
                            try tc.event("\(reader.name) read a value")
                            let consumed = buffer.readerIndex - start.readerIndex
                            #expect(
                                (1...input.bytes.count).contains(consumed),
                                "\(reader.name) consumed \(consumed)"
                            )
                        case .failure(let error):
                            #expect(
                                buffer.readerIndex == start.readerIndex,
                                "\(reader.name) failed with \(error)"
                            )
                            if case .typeMismatch(_, let format) = error {
                                #expect(format == input.bytes.first, "\(reader.name)")
                            } else if !input.bytes.isEmpty {
                                // Failing past the format byte is where the index
                                // has moved and must be put back.
                                try tc.event("\(reader.name) failed on its own format")
                            }
                    }
                }
            }
        }

        /// Skipping a value consumes exactly the bytes that reading it with
        /// the per-family readers does, and the raw value slice holds exactly
        /// those bytes. Where reading fails, skipping fails with the same
        /// error, unless reading found a string that is not UTF-8, which the
        /// skip does not validate.
        ///
        /// Mutation-checked: a skip that forgets an ext8 value's type byte
        /// fails this, and so does a skip that lets a container one level past
        /// the limit through.
        @Test
        func skipConsumesWhatReadingDoes() throws {
            try property(
                reaching: ["decoded"],
                reachingAfter: [
                    "a corrupted value": 1_000, "a strict prefix of a value": 1_000,
                    "a value and bytes after it": 1_000, "a value with 0xc1 inserted": 1_000,
                    "a whole value": 1_000, "any bytes": 1_000, "failed with invalidFormat": 1_000,
                    "failed with invalidUTF8": 1_000, "failed with nestingTooDeep": 1_000,
                    "failed with truncated": 1_000,
                ]
            ) { tc in
                let input = try #draw(PackGenerators.inputs, from: tc)
                let alreadyRead = try #draw(Gen<[UInt8]>.bytes(), from: tc)
                let maxDepth = try #draw(PackGenerators.nestingLimits, from: tc)
                try tc.event(input.kind)
                let start = buffer(after: alreadyRead, holding: input.bytes)
                var reading = start
                let read = readPackValue(from: &reading, maxDepth: maxDepth)
                var skipping = start
                let skipped = skipping.skipMessagePackValue(maxDepth: maxDepth)
                try tc.event(outcome(read))
                switch read {
                    case .success:
                        #expect(failure(skipped) == nil)
                        #expect(skipping.readerIndex == reading.readerIndex)
                    case .failure(.invalidUTF8):
                        break
                    case .failure(let error):
                        #expect(failure(skipped) == error)
                }

                var slicing = start
                let slice = slicing.readMessagePackRawValueSlice(maxDepth: maxDepth)
                #expect(failure(slice) == failure(skipped))
                #expect(slicing.readerIndex == skipping.readerIndex)
                if case .success(let slice) = slice {
                    let consumed = skipping.readerIndex - start.readerIndex
                    #expect(Array(slice.readableBytesView) == Array(input.bytes.prefix(consumed)))
                }
            }
        }

        /// A value read from any bytes writes back in its narrowest encoding,
        /// so never longer than the bytes it was read from. Reading that back
        /// gives the same value and consumes all of it, and writing it again
        /// gives the same bytes.
        ///
        /// Mutation-checked: a writer that moves 255 from uint8 to uint16
        /// fails this wherever a read value holds 255, in any encoding. That
        /// is one edge among nineteen, so it takes the nightly profile's
        /// 10,000 cases to be sure of meeting it.
        @Test
        func readValuesWriteBackCanonically() throws {
            try property(
                reaching: ["nothing read to write back", "written back as long"],
                reachingAfter: [
                    "a binary past bin8": 1_000, "a container in a container": 1_000,
                    "a corrupted value": 1_000, "a float32": 1_000,
                    "a strict prefix of a value": 1_000, "a value and bytes after it": 1_000,
                    "a value with 0xc1 inserted": 1_000, "a whole value": 1_000, "an ext": 1_000,
                    "an ext past ext8": 1_000, "an integer above Int64.max": 1_000,
                    "an integer at a format's edge": 1_000, "any bytes": 1_000,
                    "written back shorter": 1_000,
                ]
            ) { tc in
                let input = try #draw(PackGenerators.inputs, from: tc)
                try tc.event(input.kind)
                var reader = ByteBuffer(bytes: input.bytes)
                guard case .success(let value) = readPackValue(from: &reader, maxDepth: .max) else {
                    try tc.event("nothing read to write back")
                    return
                }
                try recordShapes(of: value, in: tc)
                let consumed = reader.readerIndex
                var canonical = ByteBuffer()
                writePackValue(value, into: &canonical)
                try tc.event(
                    canonical.readableBytes < consumed
                        ? "written back shorter" : "written back as long"
                )
                #expect(canonical.readableBytes == narrowestLength(of: value), "\(hex(canonical))")
                #expect(canonical.readableBytes <= consumed, "\(hex(canonical))")

                var rereader = canonical
                let reread = readPackValue(from: &rereader, maxDepth: .max)
                #expect(reread == .success(value), "\(hex(canonical))")
                #expect(rereader.readableBytes == 0)
                if case .success(let rereadValue) = reread {
                    var again = ByteBuffer()
                    writePackValue(rereadValue, into: &again)
                    #expect(again == canonical)
                }
            }
        }
    }

#endif

// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    @testable import MMWire
    import NIOCore
    import Testing

    extension ByteBuffer {
        /// The skip that `MPStructuralWalk` replaced, kept as the walk's
        /// model: one `ByteBuffer` read per format byte, length and count,
        /// and a recursive call per element. On failure the reader index
        /// stays where the failed read left it.
        mutating func skipByReads(currentDepth: Int, cap: Int) -> Result<Void, MMWireError> {
            guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
            switch format {
                case 0x00...0x7f, 0xe0...0xff, MPFormat.nilByte, MPFormat.falseByte,
                    MPFormat.trueByte:
                    return .success(())
                case MPFormat.uint8, MPFormat.int8:
                    return self.skipBytesByRead(1)
                case MPFormat.uint16, MPFormat.int16:
                    return self.skipBytesByRead(2)
                case MPFormat.uint32, MPFormat.int32, MPFormat.float32:
                    return self.skipBytesByRead(4)
                case MPFormat.uint64, MPFormat.int64, MPFormat.float64:
                    return self.skipBytesByRead(8)
                case 0xa0...0xbf:
                    return self.skipBytesByRead(Int(format & 0x1f))
                case MPFormat.str8, MPFormat.bin8:
                    return self.readLengthByRead(UInt8.self).flatMap { self.skipBytesByRead($0) }
                case MPFormat.str16, MPFormat.bin16:
                    return self.readLengthByRead(UInt16.self).flatMap { self.skipBytesByRead($0) }
                case MPFormat.str32, MPFormat.bin32:
                    return self.readLengthByRead(UInt32.self).flatMap { self.skipBytesByRead($0) }
                case MPFormat.fixext1:
                    return self.skipBytesByRead(2)
                case MPFormat.fixext2:
                    return self.skipBytesByRead(3)
                case MPFormat.fixext4:
                    return self.skipBytesByRead(5)
                case MPFormat.fixext8:
                    return self.skipBytesByRead(9)
                case MPFormat.fixext16:
                    return self.skipBytesByRead(17)
                case MPFormat.ext8:
                    return self.readLengthByRead(UInt8.self).flatMap {
                        self.skipBytesByRead($0 + 1)
                    }
                case MPFormat.ext16:
                    return self.readLengthByRead(UInt16.self).flatMap {
                        self.skipBytesByRead($0 + 1)
                    }
                case MPFormat.ext32:
                    return self.readLengthByRead(UInt32.self).flatMap {
                        self.skipBytesByRead($0 + 1)
                    }
                case 0x90...0x9f:
                    return self.skipElementsByReads(
                        count: Int(format & 0x0f),
                        containerDepth: currentDepth,
                        cap: cap
                    )
                case MPFormat.array16:
                    return self.readLengthByRead(UInt16.self).flatMap {
                        self.skipElementsByReads(count: $0, containerDepth: currentDepth, cap: cap)
                    }
                case MPFormat.array32:
                    return self.readLengthByRead(UInt32.self).flatMap {
                        self.skipElementsByReads(count: $0, containerDepth: currentDepth, cap: cap)
                    }
                case 0x80...0x8f:
                    return self.skipElementsByReads(
                        count: 2 * Int(format & 0x0f),
                        containerDepth: currentDepth,
                        cap: cap
                    )
                case MPFormat.map16:
                    return self.readLengthByRead(UInt16.self).flatMap {
                        self.skipElementsByReads(
                            count: 2 * $0,
                            containerDepth: currentDepth,
                            cap: cap
                        )
                    }
                case MPFormat.map32:
                    return self.readLengthByRead(UInt32.self).flatMap {
                        self.skipElementsByReads(
                            count: 2 * $0,
                            containerDepth: currentDepth,
                            cap: cap
                        )
                    }
                default:
                    return .failure(.invalidFormat(byte: format))
            }
        }

        private mutating func skipElementsByReads(
            count: Int,
            containerDepth: Int,
            cap: Int
        ) -> Result<Void, MMWireError> {
            guard containerDepth < cap else { return .failure(.nestingTooDeep(limit: cap)) }
            for _ in 0..<count {
                if case .failure(let error) = self.skipByReads(
                    currentDepth: containerDepth + 1,
                    cap: cap
                ) {
                    return .failure(error)
                }
            }
            return .success(())
        }

        private mutating func skipBytesByRead(_ count: Int) -> Result<Void, MMWireError> {
            guard self.readableBytes >= count else { return .failure(.truncated) }
            self.moveReaderIndex(forwardBy: count)
            return .success(())
        }

        private mutating func readLengthByRead<Length: FixedWidthInteger>(
            _ type: Length.Type
        ) -> Result<Int, MMWireError> {
            guard let length = self.readInteger(as: Length.self) else {
                return .failure(.truncated)
            }
            return .success(Int(length))
        }
    }

    enum StructuralWalkGenerators {
        /// The reader's inputs over `families`, and two times in five a
        /// container cut one byte before one of the values in it ends. Half
        /// of those are cut where a short string inside it runs out, the
        /// edge of the walk's inline steps, in a container of scalars and
        /// short strings that any limit above its depth lets the walk into.
        static let inputs: Gen<ReaderInput> = Gen<[Bool]>.array(
            of: .bool(),
            count: families.count...families.count
        )
        .flatMap { picked in
            let picked = zip(families, picked).filter(\.1).map(\.0)
            let values = PackGenerators.values(of: picked.isEmpty ? families : picked)
            let cutContainers = containers(of: .oneOf(values, shortStrings))
            return .oneOf(
                PackGenerators.inputs(of: values),
                PackGenerators.inputs(of: values),
                PackGenerators.inputs(of: values),
                cutContainers.flatMap { bytes in
                    Gen<ValueEnd>.element(of: valueEnds(in: bytes)).map { cut(bytes, at: $0) }
                },
                containers(of: .oneOf(.oneOf(picked.isEmpty ? families : picked), shortStrings))
                    .flatMap { bytes in
                        let ends = valueEnds(in: bytes)
                        let shortStringEnds = ends.filter(\.isShortStringInAContainer)
                        return Gen<ValueEnd>.element(
                            of: shortStringEnds.isEmpty ? ends : shortStringEnds
                        )
                        .map { cut(bytes, at: $0) }
                    }
            )
        }

        /// `bytes` cut one byte before `end`.
        static func cut(_ bytes: [UInt8], at end: ValueEnd) -> ReaderInput {
            ReaderInput(
                kind: end.isShortStringInAContainer
                    ? "a short string in a container cut a byte short"
                    : "a container cut a byte before one of its values ends",
                bytes: Array(bytes.prefix(end.offset - 1))
            )
        }

        /// The reader's scalar families, and strings a fixstr holds.
        static let families: [Gen<[UInt8]>] = PackGenerators.scalarFamilies + [shortStrings]

        /// Strings of one to 31 bytes, in a fixstr.
        static let shortStrings: Gen<[UInt8]> = Gen<[UInt8]>.bytes(count: 1...31).map {
            [0xa0 | UInt8($0.count)] + $0
        }

        /// Arrays and maps of one to 17 entries of `element`, in any header
        /// that can declare their count.
        static func containers(of element: Gen<[UInt8]>) -> Gen<[UInt8]> {
            .oneOf(
                Gen<[[UInt8]]>.array(of: element, count: 1...17).flatMap { elements in
                    PackGenerators.headers(
                        count: elements.count,
                        fix: (0x90, 16),
                        eightBit: nil,
                        sixteenBit: 0xdc,
                        thirtyTwoBit: 0xdd
                    )
                    .map { $0 + elements.joined() }
                },
                Gen<[[UInt8]]>.array(of: Hegel.zip(element, element).map { $0 + $1 }, count: 1...17)
                    .flatMap { entries in
                        PackGenerators.headers(
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

        /// Depths to start a walk at: the top level, any shallow one, or
        /// one beside the nesting limit, where a container's elements
        /// cross it.
        static func depths(near cap: Int) -> Gen<Int> {
            let besideTheLimit = [cap &- 1, cap, cap &+ 1].filter { $0 >= 0 }
            var depths: [Gen<Int>] = [.just(0), .int(in: 0...40)]
            if !besideTheLimit.isEmpty {
                depths.append(.element(of: besideTheLimit))
            }
            return .oneOf(depths)
        }
    }

    /// Where one value inside another ends, and whether it is a string a
    /// fixstr holds, sitting in a container.
    struct ValueEnd: Sendable {
        var offset: Int
        var isShortStringInAContainer: Bool
    }

    /// Where each value in the one complete value `bytes` holds ends, that
    /// value's own end included: the elements of its containers, and their
    /// keys and values, at any depth.
    func valueEnds(in bytes: [UInt8]) -> [ValueEnd] {
        var buffer = ByteBuffer(bytes: bytes)
        var ends: [ValueEnd] = []
        func visit(inAContainer: Bool) {
            guard let format = buffer.readInteger(as: UInt8.self) else { return }
            var elementCount: Int?
            switch format {
                case 0x90...0x9f: elementCount = Int(format & 0x0f)
                case 0x80...0x8f: elementCount = 2 * Int(format & 0x0f)
                case MPFormat.array16:
                    elementCount = buffer.readInteger(as: UInt16.self).map { Int($0) }
                case MPFormat.array32:
                    elementCount = buffer.readInteger(as: UInt32.self).map { Int($0) }
                case MPFormat.map16:
                    elementCount = buffer.readInteger(as: UInt16.self).map { 2 * Int($0) }
                case MPFormat.map32:
                    elementCount = buffer.readInteger(as: UInt32.self).map { 2 * Int($0) }
                default:
                    buffer.moveReaderIndex(to: buffer.readerIndex - 1)
                    _ = buffer.skipByReads(currentDepth: 0, cap: .max)
            }
            for _ in 0..<(elementCount ?? 0) {
                visit(inAContainer: true)
            }
            let isShortString = (0xa1...0xbf).contains(format)
            ends.append(
                ValueEnd(
                    offset: buffer.readerIndex,
                    isShortStringInAContainer: isShortString && inAContainer
                )
            )
        }
        visit(inAContainer: false)
        return ends
    }

    /// Whether the value in `bytes` starts with a container header.
    func startsWithAContainer(_ bytes: [UInt8]) -> Bool {
        guard let format = bytes.first else { return false }
        return (0x80...0x9f).contains(format)
            || (MPFormat.array16...MPFormat.map32).contains(format)
    }

    @Suite("Structural walk properties", .hegel, .offTheCooperativePool)
    struct StructuralWalkProperties {
        /// The walk that skips a value stops where the `ByteBuffer` reads it
        /// replaced did, on any bytes, from any depth, under any nesting
        /// limit: it consumes the same bytes when they hold a whole value,
        /// and otherwise fails with the same error and leaves the reader
        /// index where they left it. The public skips put the index back on
        /// failure; the depth-aware one that generated code and the coders
        /// call does not, so where it stops is part of what it returns.
        @Test
        func walkStopsWhereTheReadsDid() throws {
            try property(
                reaching: [
                    "failed with nestingTooDeep", "failed with truncated",
                    "walked to a short string in a container cut a byte short",
                    "walked a whole value",
                ],
                reachingAfter: [
                    "a corrupted value": 1_000, "a strict prefix of a value": 1_000,
                    "a short string in a container cut a byte short": 1_000,
                    "a value and bytes after it": 1_000,
                    "a container cut a byte before one of its values ends": 1_000,
                    "a value with 0xc1 inserted": 1_000, "a whole value": 1_000,
                    "any bytes": 1_000, "failed inside a container": 1_000,
                    "failed with invalidFormat": 1_000,
                    "walked a whole value from below the top level": 1_000,
                ]
            ) { tc in
                let input = try #draw(StructuralWalkGenerators.inputs, from: tc)
                let alreadyRead = try #draw(Gen<[UInt8]>.bytes(), from: tc)
                let cap = try #draw(PackGenerators.nestingLimits, from: tc)
                // A short string cut inside a container is walked from a
                // depth the limit lets into the container, where it is.
                let cutString = input.kind == "a short string in a container cut a byte short"
                let depth = try #draw(
                    cutString && cap > 0
                        ? Gen<Int>.int(in: 0...cap - 1)
                        : StructuralWalkGenerators.depths(near: cap),
                    from: tc
                )
                try tc.event(input.kind)
                let start = buffer(after: alreadyRead, holding: input.bytes)

                var walking = start
                let walked = walking.skipMessagePackValue(currentDepth: depth, cap: cap)
                var reading = start
                let read = reading.skipByReads(currentDepth: depth, cap: cap)

                switch read {
                    case .success:
                        try tc.event("walked a whole value")
                        if depth > 0 {
                            try tc.event("walked a whole value from below the top level")
                        }
                    case .failure(let error):
                        try tc.event("failed with \(error.caseName)")
                        if startsWithAContainer(input.bytes) {
                            try tc.event("failed inside a container")
                        }
                        // Everything before the cut is whole, so a truncation
                        // means the reads got as far as the cut string.
                        if cutString, error == .truncated {
                            try tc.event("walked to a short string in a container cut a byte short")
                        }
                }
                #expect(failure(walked) == failure(read), "\(hex(start))")
                #expect(walking.readerIndex == reading.readerIndex, "\(hex(start))")
            }
        }
    }

    extension MMWireError {
        /// The case's name alone, for event labels.
        fileprivate var caseName: String {
            switch self {
                case .truncated: "truncated"
                case .invalidFormat: "invalidFormat"
                case .nestingTooDeep: "nestingTooDeep"
                default: "\(self)"
            }
        }
    }

#endif

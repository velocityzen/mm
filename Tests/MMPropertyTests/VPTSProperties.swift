// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import Testing

    /// A VPTS value's components, valid or not, before `MMVPTS.init?`
    /// judges them.
    struct VPTSComponents: Sendable, Hashable {
        var year: Int64?
        var month: Int?
        var day: Int?
        var hour: Int?
        var minute: Int?
        var second: Int?
        var fraction: MMVPTS.Fraction?
        var offsetMinutes: Int?

        var value: MMVPTS? {
            MMVPTS(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second,
                fraction: fraction,
                offsetMinutes: offsetMinutes
            )
        }

        /// The date and time fields, coarsest first.
        var fields: [Int64?] {
            [
                year, month.map(Int64.init), day.map(Int64.init), hour.map(Int64.init),
                minute.map(Int64.init), second.map(Int64.init),
            ]
        }

        /// Sets the date or time field at `index`, coarsest first.
        mutating func set(field index: Int, to value: Int64?) {
            let narrow = value.map { Int(truncatingIfNeeded: $0) }
            switch index {
                case 0: year = value
                case 1: month = narrow
                case 2: day = narrow
                case 3: hour = narrow
                case 4: minute = narrow
                default: second = narrow
            }
        }

        /// The value as it decodes: a wide year carries a nanosecond
        /// fraction in the wide form, which reads back as attoseconds.
        var decodedForm: VPTSComponents {
            var decoded = self
            if needsWide(self), case .nanoseconds(let nanoseconds) = fraction {
                decoded.fraction = .attoseconds(UInt64(nanoseconds) * 1_000_000_000)
            }
            return decoded
        }
    }

    let narrowYearRange: ClosedRange<Int64> = -32768...32767

    /// Whether the spec's WIDE forms are needed: a year past the narrow range,
    /// or an attosecond fraction.
    func needsWide(_ components: VPTSComponents) -> Bool {
        if let year = components.year, !narrowYearRange.contains(year) { return true }
        if case .attoseconds = components.fraction { return true }
        return false
    }

    /// Days in a month of the proleptic Gregorian calendar.
    func daysIn(month: Int, year: Int64) -> Int {
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        switch month {
            case 2: return leap ? 29 : 28
            case 4, 6, 9, 11: return 30
            default: return 31
        }
    }

    /// The first rule from the spec's §3 and §4 that the components break,
    /// as a constant label, or nil when they make a value.
    func brokenRule(_ components: VPTSComponents) -> String? {
        let present = components.fields.map { $0 != nil }
        let depth = present.prefix { $0 }.count
        if depth == 0 { return "no date or time field" }
        if present.dropFirst(depth).contains(true) { return "a gap in the fields" }
        if components.fraction != nil && components.second == nil {
            return "a fraction without a second"
        }
        if components.offsetMinutes != nil && components.hour == nil {
            return "an offset without an hour"
        }
        if let month = components.month, !(1...12).contains(month) { return "a month out of range" }
        if let day = components.day, let year = components.year, let month = components.month,
            !(1...daysIn(month: month, year: year)).contains(day)
        {
            return "a day out of range"
        }
        if let hour = components.hour, !(0...23).contains(hour) { return "an hour out of range" }
        if let minute = components.minute, !(0...59).contains(minute) {
            return "a minute out of range"
        }
        if let second = components.second, !(0...60).contains(second) {
            return "a second out of range"
        }
        switch components.fraction {
            case .nanoseconds(let value) where value > 999_999_999: return "a fraction out of range"
            case .attoseconds(let value) where value > 999_999_999_999_999_999:
                return "a fraction out of range"
            default: break
        }
        if let offset = components.offsetMinutes, !(-1439...1439).contains(offset) {
            return "an offset out of range"
        }
        return nil
    }

    /// The spec's §2 layout of any components, in the WIDE forms or the
    /// narrow ones. Each field keeps only the low bytes its slot holds, so
    /// components that break a rule lay out as bytes that break it too.
    func vptsEncoding(of components: VPTSComponents, wide: Bool) -> [UInt8] {
        var header: UInt8 = 0
        for (bit, field) in zip([0x01, 0x02, 0x04, 0x08, 0x10, 0x20] as [UInt8], components.fields)
        where field != nil {
            header |= bit
        }
        if components.fraction != nil { header |= 0x40 }
        let extensionByte: UInt8 = (components.offsetMinutes != nil ? 0x01 : 0) | (wide ? 0x02 : 0)
        if extensionByte != 0 { header |= 0x80 }
        var bytes = [header] + (extensionByte != 0 ? [extensionByte] : [])
        if let year = components.year {
            bytes +=
                wide
                ? bigEndianBytes(UInt64(bitPattern: year) ^ (1 << 63))
                : bigEndianBytes(UInt16(truncatingIfNeeded: year &+ 32768))
        }
        for field in components.fields.dropFirst() {
            if let field { bytes.append(UInt8(truncatingIfNeeded: field)) }
        }
        switch components.fraction {
            case .nanoseconds(let value):
                bytes +=
                    wide ? bigEndianBytes(UInt64(value) &* 1_000_000_000) : bigEndianBytes(value)
            case .attoseconds(let value):
                bytes += bigEndianBytes(value)
            case nil:
                break
        }
        if let offset = components.offsetMinutes {
            bytes += bigEndianBytes(Int16(truncatingIfNeeded: offset))
        }
        return bytes
    }

    /// What the spec says bytes decode to.
    enum VPTSReading: Sendable {
        case null
        case value(VPTSComponents)
        /// Every rule the bytes break; a decoder reports one of them.
        case invalid(Set<MMVPTSDecodeFailure>)
    }

    /// Reads bytes by the spec: the §9 reference validation, the §6 size
    /// formula, then the field ranges.
    func readVPTS(_ bytes: [UInt8]) -> VPTSReading {
        guard let header = bytes.first else { return .invalid([.empty]) }
        if header == 0 { return bytes.count == 1 ? .null : .invalid([.trailingBytes]) }
        let mask = header & 0x3F
        var broken: Set<MMVPTSDecodeFailure> = []
        if mask & (mask &+ 1) != 0 { broken.insert(.nonContiguousMask) }
        if header & 0x40 != 0 && mask & 0x20 == 0 { broken.insert(.fractionWithoutSecond) }
        var extensionByte: UInt8 = 0
        if header & 0x80 != 0 {
            guard bytes.count >= 2 else { return .invalid(broken.union([.truncated])) }
            extensionByte = bytes[1]
            if extensionByte == 0 { broken.insert(.emptyExtension) }
            if extensionByte & 0xFC != 0 { broken.insert(.reservedExtensionBits) }
        }
        if extensionByte & 0x01 != 0 && mask & 0x08 == 0 { broken.insert(.offsetWithoutHour) }
        let wide = extensionByte & 0x02 != 0
        if wide && mask == 0 { broken.insert(.wideWithoutYear) }
        let size =
            1 + (header & 0x80 != 0 ? 1 : 0) + (mask & 0x01 != 0 ? (wide ? 8 : 2) : 0)
            + (mask >> 1).nonzeroBitCount + (header & 0x40 != 0 ? (wide ? 8 : 4) : 0)
            + (extensionByte & 0x01 != 0 ? 2 : 0)
        if bytes.count < size { broken.insert(.truncated) }
        if bytes.count > size { broken.insert(.trailingBytes) }
        guard broken.isEmpty else { return .invalid(broken) }

        var fields = bytes.dropFirst(header & 0x80 != 0 ? 2 : 1)
        func take(_ count: Int) -> UInt64 {
            defer { fields = fields.dropFirst(count) }
            return fields.prefix(count).reduce(0) { $0 << 8 | UInt64($1) }
        }
        var components = VPTSComponents()
        if mask & 0x01 != 0 {
            components.year = wide ? Int64(bitPattern: take(8) ^ (1 << 63)) : Int64(take(2)) - 32768
        }
        if mask & 0x02 != 0 { components.month = Int(take(1)) }
        if mask & 0x04 != 0 { components.day = Int(take(1)) }
        if mask & 0x08 != 0 { components.hour = Int(take(1)) }
        if mask & 0x10 != 0 { components.minute = Int(take(1)) }
        if mask & 0x20 != 0 { components.second = Int(take(1)) }
        if header & 0x40 != 0 {
            components.fraction = wide ? .attoseconds(take(8)) : .nanoseconds(UInt32(take(4)))
        }
        if extensionByte & 0x01 != 0 {
            components.offsetMinutes = Int(Int16(truncatingIfNeeded: take(2)))
        }
        return brokenRule(components) == nil ? .value(components) : .invalid([.invalidComponent])
    }

    /// The order of two values with the same fields present: by year, then
    /// each finer field, then the fraction.
    func chronologicalOrder(_ first: VPTSComponents, _ second: VPTSComponents) -> Int {
        for (left, right) in zip(first.fields, second.fields) where left != right {
            return (left ?? 0) < (right ?? 0) ? -1 : 1
        }
        func attoseconds(_ fraction: MMVPTS.Fraction?) -> UInt64 {
            switch fraction {
                case .nanoseconds(let value): UInt64(value) * 1_000_000_000
                case .attoseconds(let value): value
                case nil: 0
            }
        }
        let (left, right) = (attoseconds(first.fraction), attoseconds(second.fraction))
        return left == right ? 0 : left < right ? -1 : 1
    }

    func byteOrder(_ first: [UInt8], _ second: [UInt8]) -> Int {
        first == second ? 0 : first.lexicographicallyPrecedes(second) ? -1 : 1
    }

    enum FractionKind: CaseIterable, Sendable {
        case none, nanoseconds, attoseconds
    }

    enum VPTSGenerators {
        static let narrowYears: Gen<Int64> = .oneOf(
            .integer(in: narrowYearRange),
            .element(of: [-32768, 32767, 0, -1, 1900, 1970, 2000, 2023, 2024, 9999])
        )

        static let wideYears: Gen<Int64> = .oneOf(
            .integer(in: .min ... -32769),
            .integer(in: 32768 ... .max),
            .element(of: [-32769, 32768, .min, .max])
        )

        static let years: Gen<Int64> = .oneOf(narrowYears, wideYears)

        static let nanoseconds: Gen<UInt32> = .oneOf(
            .integer(in: 0...999_999_999),
            .element(of: [0, 1, 999_999_999])
        )

        static let attoseconds: Gen<UInt64> = .oneOf(
            .integer(in: 0...999_999_999_999_999_999),
            .element(of: [0, 1, 1_000_000_000, 999_999_999_999_999_999])
        )

        static let offsets: Gen<Int> = .oneOf(
            .int(in: -1439...1439),
            .element(of: [-1439, -1, 0, 1, 1439])
        )

        static func fractions(of kind: FractionKind) -> Gen<MMVPTS.Fraction?> {
            switch kind {
                case .none: .just(nil)
                case .nanoseconds: nanoseconds.map { .nanoseconds($0) }
                case .attoseconds: attoseconds.map { .attoseconds($0) }
            }
        }

        /// Valid components with `depth` date and time fields, each in its
        /// range and often at its edges, a fraction of the given kind when
        /// the second is present, and an offset or not when the hour is.
        static func validComponents(
            depth: Int,
            years: Gen<Int64>,
            fraction: FractionKind,
            offset: Bool
        ) -> Gen<VPTSComponents> {
            Gen { tc in
                var components = VPTSComponents()
                let year = try tc.draw(years)
                components.year = year
                if depth >= 2 {
                    let month = try tc.draw(
                        Gen<Int>.oneOf(.int(in: 1...12), .element(of: [1, 2, 12]))
                    )
                    components.month = month
                    if depth >= 3 {
                        let last = daysIn(month: month, year: year)
                        components.day = try tc.draw(
                            Gen<Int>.oneOf(.int(in: 1...last), .element(of: [1, last]))
                        )
                    }
                }
                if depth >= 4 {
                    components.hour = try tc.draw(
                        Gen<Int>.oneOf(.int(in: 0...23), .element(of: [0, 23]))
                    )
                }
                if depth >= 5 {
                    components.minute = try tc.draw(
                        Gen<Int>.oneOf(.int(in: 0...59), .element(of: [0, 59]))
                    )
                }
                if depth >= 6 {
                    components.second = try tc.draw(
                        Gen<Int>.oneOf(.int(in: 0...60), .element(of: [0, 59, 60]))
                    )
                    components.fraction = try tc.draw(fractions(of: fraction))
                }
                if depth >= 4 && offset { components.offsetMinutes = try tc.draw(offsets) }
                return components
            }
        }

        /// Any valid components: any precision, any fraction kind, with or
        /// without an offset.
        static let anyValidComponents: Gen<VPTSComponents> = Gen { tc in
            try tc.draw(
                validComponents(
                    depth: tc.draw(.int(in: 1...6)),
                    years: years,
                    fraction: tc.draw(.element(of: FractionKind.allCases)),
                    offset: tc.draw(.bool())
                )
            )
        }

        /// A fraction of either kind, often past its range.
        static let anyFractions: Gen<MMVPTS.Fraction> = .oneOf(
            nanoseconds.map { .nanoseconds($0) },
            attoseconds.map { .attoseconds($0) },
            Gen<UInt32>.oneOf(.integer(), .element(of: [1_000_000_000, .max])).map {
                .nanoseconds($0)
            },
            Gen<UInt64>.oneOf(.integer(), .element(of: [1_000_000_000_000_000_000, .max])).map {
                .attoseconds($0)
            }
        )

        /// An offset, often past its range.
        static let anyOffsets: Gen<Int> = .oneOf(
            offsets,
            .element(of: [-1440, 1440, .min, .max]),
            .int()
        )

        /// Components with fields present in any pattern, each in its
        /// range, at an edge just past it, or anything at all, and any
        /// fraction and offset.
        static let arbitraryComponents: Gen<VPTSComponents> = Gen { tc in
            let present = try tc.draw(Gen<[Bool]>.array(of: .bool(), count: 6...6))
            func field(_ index: Int, _ inRange: ClosedRange<Int>, _ edges: [Int]) throws -> Int? {
                guard present[index] else { return nil }
                return try tc.draw(.oneOf(.int(in: inRange), .element(of: edges), .int()))
            }
            var components = VPTSComponents()
            components.year = present[0] ? try tc.draw(years) : nil
            components.month = try field(1, 1...12, [0, 1, 2, 12, 13, -1])
            components.day = try field(2, 1...31, [0, 1, 28, 29, 30, 31, 32])
            components.hour = try field(3, 0...23, [-1, 0, 23, 24])
            components.minute = try field(4, 0...59, [-1, 0, 59, 60])
            components.second = try field(5, 0...60, [-1, 0, 59, 60, 61])
            components.fraction = try tc.draw(.optional(anyFractions))
            components.offsetMinutes = try tc.draw(.optional(anyOffsets))
            return components
        }

        /// Valid full-precision components with one rule broken: a field
        /// cleared to leave a gap, the fields cut above the second with the
        /// fraction kept, cut above the hour with the offset kept, one field
        /// moved past its range, or nothing left at all.
        static let componentsBreakingOneRule: Gen<VPTSComponents> = Gen { tc in
            let fraction = try tc.draw(Gen<FractionKind>.element(of: [.nanoseconds, .attoseconds]))
            var components = try tc.draw(
                validComponents(depth: 6, years: years, fraction: fraction, offset: true)
            )
            func cut(toDepth depth: Int) {
                for index in depth..<6 { components.set(field: index, to: nil) }
            }
            func pastRange(_ edges: [Int]) throws -> Int {
                try tc.draw(Gen<Int>.oneOf(.element(of: edges), .int()))
            }
            switch try tc.draw(Gen<Int>.int(in: 0...10)) {
                case 0:
                    components.set(field: try tc.draw(Gen<Int>.int(in: 0...4)), to: nil)
                case 1:
                    let depth = try tc.draw(Gen<Int>.int(in: 0...5))
                    cut(toDepth: depth)
                    if depth < 4 { components.offsetMinutes = nil }
                case 2:
                    cut(toDepth: try tc.draw(Gen<Int>.int(in: 0...3)))
                    components.fraction = nil
                case 3:
                    components.month = try pastRange([0, 13, -1, .min, .max])
                case 4:
                    let last = daysIn(month: components.month ?? 1, year: components.year ?? 0)
                    components.day = try pastRange([0, last + 1, 32, -1, .max])
                case 5:
                    components.hour = try pastRange([-1, 24, .max])
                case 6:
                    components.minute = try pastRange([-1, 60, .max])
                case 7:
                    components.second = try pastRange([-1, 61, .max])
                case 8:
                    components.fraction = try tc.draw(
                        Gen<MMVPTS.Fraction>.oneOf(
                            Gen<UInt32>.oneOf(
                                .integer(in: 1_000_000_000 ... .max),
                                .element(of: [1_000_000_000])
                            )
                            .map { .nanoseconds($0) },
                            Gen<UInt64>.oneOf(
                                .integer(in: 1_000_000_000_000_000_000 ... .max),
                                .element(of: [1_000_000_000_000_000_000])
                            )
                            .map { .attoseconds($0) }
                        )
                    )
                case 9:
                    components.offsetMinutes = try pastRange([-1440, 1440, .min, .max])
                default:
                    cut(toDepth: 0)
                    (components.fraction, components.offsetMinutes) = (nil, nil)
            }
            return components
        }

        /// The end of February in years where the leap rules part: every
        /// fourth year, a century, every fourth century, near zero and far
        /// from it, with day 28, 29 or 30 and finer fields often set.
        static let endsOfFebruary: Gen<VPTSComponents> = Gen { tc in
            let year = try tc.draw(
                Gen<Int64>.oneOf(
                    .element(of: [
                        2000, 1900, 2100, 2400, 2024, 2023, 1600, 1700, 0, -4, -100, -400,
                    ]),
                    Gen<Int64>.integer(in: (Int64.min / 400)...(Int64.max / 400)).map { $0 * 400 },
                    Gen<Int64>.integer(in: (Int64.min / 100)...(Int64.max / 100)).map { $0 * 100 },
                    years
                )
            )
            var components = try tc.draw(
                validComponents(
                    depth: tc.draw(.int(in: 3...6)),
                    years: .just(year),
                    fraction: tc.draw(.element(of: FractionKind.allCases)),
                    offset: tc.draw(.bool())
                )
            )
            components.month = 2
            components.day = try tc.draw(.element(of: [28, 29, 30]))
            return components
        }

        /// Components that may break any rule: half the time valid ones
        /// with one rule broken, otherwise valid ones, the end of February,
        /// or arbitrary ones.
        static let anyComponents: Gen<VPTSComponents> = .oneOf(
            componentsBreakingOneRule,
            .oneOf(anyValidComponents, endsOfFebruary, arbitraryComponents)
        )

        /// A header byte and the extension byte it calls for, each pair
        /// keeping every rule or breaking one: a gap in the fields, a
        /// fraction without a second, an empty extension, a reserved bit
        /// (bit 2, or bit 7, which the spec keeps for a further
        /// continuation byte), an offset without an hour, WIDE without a
        /// year.
        static let ruleHeaders: [[UInt8]] = [
            [0x3F], [0x7F], [0xBF, 0x01], [0x81, 0x02], [0xFF, 0x03],
            [0x05], [0x41], [0x81, 0x00], [0x81, 0x04], [0x81, 0x80], [0x87, 0x01], [0x83, 0x01],
            [0x80, 0x01], [0x80, 0x02],
        ]

        /// Any header byte, and any extension byte it calls for.
        static let anyHeaders: Gen<[UInt8]> = Gen { tc in
            let header = try tc.draw(Gen<UInt8>.integer())
            return header & 0x80 == 0 ? [header] : [header, try tc.draw(Gen<UInt8>.integer())]
        }

        /// Bytes laid out as a header and extension byte say, each field
        /// often in its range, then cut short, run on, or left exact.
        static func laidOutBytes(after headers: Gen<[UInt8]>) -> Gen<[UInt8]> {
            Gen { tc in try laidOut(after: tc.draw(headers), tc) }
        }

        static func laidOut(after prefix: [UInt8], _ tc: TestCase) throws -> [UInt8] {
            var bytes = prefix
            let header = prefix[0]
            let extensionByte = prefix.count > 1 ? prefix[1] : 0
            let mask = header & 0x3F
            let wide = extensionByte & 0x02 != 0
            func byte(_ inRange: ClosedRange<UInt8>) throws -> [UInt8] {
                [try tc.draw(Gen<UInt8>.oneOf(.integer(in: inRange), .integer()))]
            }
            if mask & 0x01 != 0 {
                let year = try tc.draw(years)
                bytes +=
                    wide
                    ? bigEndianBytes(UInt64(bitPattern: year) ^ (1 << 63))
                    : bigEndianBytes(UInt16(truncatingIfNeeded: year &+ 32768))
            }
            if mask & 0x02 != 0 { bytes += try byte(1...12) }
            if mask & 0x04 != 0 { bytes += try byte(1...31) }
            if mask & 0x08 != 0 { bytes += try byte(0...23) }
            if mask & 0x10 != 0 { bytes += try byte(0...59) }
            if mask & 0x20 != 0 { bytes += try byte(0...60) }
            if header & 0x40 != 0 {
                bytes +=
                    wide
                    ? bigEndianBytes(try tc.draw(Gen<UInt64>.oneOf(attoseconds, .integer())))
                    : bigEndianBytes(try tc.draw(Gen<UInt32>.oneOf(nanoseconds, .integer())))
            }
            if extensionByte & 0x01 != 0 {
                bytes += bigEndianBytes(
                    try tc.draw(Gen<Int16>.oneOf(offsets.map { Int16($0) }, .integer()))
                )
            }
            // Exact half the time, so the rules checked after the length come up.
            switch try tc.draw(Gen<Int>.oneOf(.just(0), .int(in: 1...2))) {
                case 1: bytes.removeLast(try tc.draw(Gen<Int>.int(in: 1...bytes.count)))
                case 2: bytes += try tc.draw(Gen<[UInt8]>.bytes(count: 1...Int.max))
                default: break
            }
            return bytes
        }

        /// Bytes to decode, a quarter of them from the header menu so each
        /// rule it breaks comes up often.
        static let decodeInputs: Gen<ReaderInput> = .oneOf(
            .oneOf(
                anyValidComponents.map {
                    ReaderInput(
                        kind: "a canonical encoding",
                        bytes: vptsEncoding(of: $0, wide: needsWide($0))
                    )
                },
                anyValidComponents.map {
                    ReaderInput(kind: "a WIDE encoding", bytes: vptsEncoding(of: $0, wide: true))
                }
            ),
            laidOutBytes(after: .element(of: ruleHeaders)).map {
                ReaderInput(kind: "a header from the menu, laid out", bytes: $0)
            },
            .oneOf(
                Hegel.zip(anyComponents, .bool()).map { components, wide in
                    ReaderInput(
                        kind: "any components, laid out",
                        bytes: vptsEncoding(of: components, wide: wide)
                    )
                },
                Hegel.zip(anyValidComponents, mutations).map {
                    ReaderInput(
                        kind: "a corrupted encoding",
                        bytes: mutated(vptsEncoding(of: $0, wide: needsWide($0)), by: $1)
                    )
                }
            ),
            .oneOf(
                laidOutBytes(after: anyHeaders).map {
                    ReaderInput(kind: "any header, laid out", bytes: $0)
                },
                Gen<[UInt8]>.bytes().map { ReaderInput(kind: "any bytes", bytes: $0) }
            )
        )

        /// Two values with the same header and no offset: another of the
        /// same shape, the first with one field moved by one, or the first
        /// again.
        static let sameHeaderPairs: Gen<(VPTSComponents, VPTSComponents)> = Gen { tc in
            let depth = try tc.draw(Gen<Int>.int(in: 1...6))
            let wide = try tc.draw(Gen<Bool>.bool())
            // A wide header carries attoseconds; a narrow one, nanoseconds.
            let withFraction = try tc.draw(Gen<Bool>.bool())
            let fraction: FractionKind =
                depth == 6 && withFraction ? (wide ? .attoseconds : .nanoseconds) : .none
            // Without attoseconds, only a year past the narrow range makes it wide.
            let shapeYears = !wide ? narrowYears : fraction == .attoseconds ? years : wideYears
            let shape = validComponents(
                depth: depth,
                years: shapeYears,
                fraction: fraction,
                offset: false
            )
            let first = try tc.draw(shape)
            // Fields from the year down, then the fraction.
            let movable = depth + (first.fraction == nil ? 0 : 1)
            let neighbour: Gen<VPTSComponents> = Hegel.zip(
                .int(in: 0...(movable - 1)),
                .element(of: [-1, 1])
            ).map {
                index,
                step in
                func moved(by step: Int) -> VPTSComponents {
                    var moved = first
                    if index < depth {
                        moved.set(field: index, to: first.fields[index].map { $0 &+ Int64(step) })
                    } else if case .nanoseconds(let value) = first.fraction {
                        moved.fraction = .nanoseconds(step > 0 ? value &+ 1 : value &- 1)
                    } else if case .attoseconds(let value) = first.fraction {
                        moved.fraction = .attoseconds(step > 0 ? value &+ 1 : value &- 1)
                    }
                    return moved
                }
                // Past an edge, step the other way; failing that, keep the first.
                let candidates = [moved(by: step), moved(by: -step)].filter {
                    brokenRule($0) == nil && needsWide($0) == needsWide(first)
                }
                return candidates.first ?? first
            }
            let second = try tc.draw(Gen<VPTSComponents>.oneOf(shape, neighbour, .just(first)))
            return (first, second)
        }
    }

    /// The decode result as a constant label for the statistics report.
    func vptsOutcome(_ result: Result<MMVPTS?, MMVPTSDecodeFailure>) -> String {
        switch result {
            case .success(nil): "the null timestamp"
            case .success: "decoded"
            case .failure(let failure): "failed with \(failure)"
        }
    }

    @Suite("VPTS properties", .hegel)
    struct VPTSProperties {
        /// Any value encodes to the spec's §2 layout, narrow unless it
        /// needs WIDE, and decodes back to itself. A nanosecond fraction
        /// beside a wide year comes back as the same instant in attoseconds:
        /// the WIDE form has no nanosecond fraction.
        ///
        /// Mutation check: narrowing the narrow year range by one (year
        /// -32768 goes WIDE) or dropping the WIDE year's bias fails here.
        @Test
        func everyValueRoundTrips() throws {
            try property { tc in
                let components = try #draw(VPTSGenerators.anyValidComponents, from: tc)
                let value = try #require(components.value, "\(components)")
                try tc.event("fields", value: Double(components.fields.compactMap { $0 }.count))
                try tc.event(needsWide(components) ? "wide" : "narrow")
                if components.decodedForm != components {
                    try tc.event("a nanosecond fraction beside a wide year")
                }
                let encoded = value.encoded()
                #expect(encoded == vptsEncoding(of: components, wide: needsWide(components)))
                #expect(MMVPTS.decode(encoded) == .success(components.decodedForm.value))
            }
        }

        /// `MMVPTS.init?` makes a value exactly when the components keep
        /// every rule: date and time fields present from the year down with
        /// no gap, a fraction only with a second, an offset only with an
        /// hour, and each field in its range, the day within its month.
        ///
        /// Mutation check: dropping the every-fourth-century leap rule
        /// (29 February 2000) or letting any month run to 31 days (30
        /// February) fails here, through the end-of-February generator.
        @Test
        func initKeepsTheRules() throws {
            try property { tc in
                let components = try #draw(VPTSGenerators.anyComponents, from: tc)
                let rule = brokenRule(components)
                try tc.event(rule ?? "keeps every rule")
                #expect((components.value != nil) == (rule == nil), "\(components)")
            }
        }

        /// Any bytes decode as the spec reads them: the null timestamp, the
        /// value the fields spell, or a failure naming a rule the bytes
        /// break. A decoded value re-encodes canonically, so WIDE input that
        /// fits the narrow forms comes back narrow.
        ///
        /// Mutation check: a decoder skipping the contiguity check or the
        /// offset-needs-an-hour check reports `invalidComponent` for bytes
        /// that break those rules, and fails here.
        @Test
        func decodingFollowsTheRules() throws {
            try property { tc in
                let input = try #draw(VPTSGenerators.decodeInputs, from: tc)
                try tc.event(input.kind)
                let decoded = MMVPTS.decode(input.bytes)
                try tc.event(vptsOutcome(decoded))
                switch readVPTS(input.bytes) {
                    case .null:
                        #expect(decoded == .success(nil))
                    case .value(let components):
                        #expect(decoded == .success(components.value), "\(input.bytes)")
                        if case .success(let value?) = decoded {
                            let canonical = vptsEncoding(
                                of: components,
                                wide: needsWide(components)
                            )
                            #expect(value.encoded() == canonical)
                            if canonical.count < input.bytes.count {
                                try tc.event("WIDE input re-encoded narrow")
                            }
                        }
                    case .invalid(let broken):
                        if case .failure(let failure) = decoded {
                            #expect(broken.contains(failure), "\(input.bytes) broke \(broken)")
                        } else {
                            Issue.record(
                                "decoded \(input.bytes), which breaks \(broken), to \(decoded)"
                            )
                        }
                }
            }
        }

        /// For two values with the same header and no offset, their bytes
        /// sort as their instants do (§5).
        ///
        /// Mutation check: dropping the WIDE year's bias sorts negative
        /// wide years after positive ones, and fails here.
        @Test
        func byteOrderIsChronological() throws {
            try property { tc in
                let (first, second) = try #draw(VPTSGenerators.sameHeaderPairs, from: tc)
                let firstBytes = try #require(first.value).encoded()
                let secondBytes = try #require(second.value).encoded()
                let order = chronologicalOrder(first, second)
                try tc.event(["earlier", "the same", "later"][order + 1])
                try tc.event(needsWide(first) ? "wide" : "narrow")
                #expect(byteOrder(firstBytes, secondBytes) == order, "\(first) against \(second)")
            }
        }
    }

#endif

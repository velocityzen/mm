// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import Testing

    let attosecondsInASecond: UInt128 = 1_000_000_000_000_000_000

    /// Whether a size in attoseconds and a sign make a `Duration`: 2¹²⁷ − 1
    /// attoseconds forward at most, 2¹²⁷ back.
    func durationFits(magnitude: UInt128, negative: Bool) -> Bool {
        magnitude <= (UInt128(1) << 127) - (negative ? 0 : 1)
    }

    /// The signed attoseconds of a size and sign that fit.
    func signedAttoseconds(magnitude: UInt128, negative: Bool) -> Int128 {
        Int128(truncatingIfNeeded: negative ? 0 &- magnitude : magnitude)
    }

    func duration(attoseconds: Int128) -> MMDuration {
        MMDuration(Duration(attoseconds: attoseconds))
    }

    /// A unit the duration encoding writes the fraction of a second in, as
    /// the spec's table gives it.
    struct DurationFractionUnit: Sendable, Hashable {
        let name: String
        let code: UInt8
        let width: Int
        /// Attoseconds in one of the unit.
        let attoseconds: UInt128

        /// One second in this unit: a fraction's count stays below it.
        var bound: UInt128 { attosecondsInASecond / attoseconds }
    }

    let durationFractionUnits: [DurationFractionUnit] = [
        DurationFractionUnit(
            name: "milliseconds",
            code: 1,
            width: 2,
            attoseconds: 1_000_000_000_000_000
        ),
        DurationFractionUnit(
            name: "microseconds",
            code: 2,
            width: 3,
            attoseconds: 1_000_000_000_000
        ),
        DurationFractionUnit(name: "nanoseconds", code: 3, width: 4, attoseconds: 1_000_000_000),
        DurationFractionUnit(name: "attoseconds", code: 4, width: 8, attoseconds: 1),
    ]

    /// The parts of a duration's encoding, valid or not: the sign, the
    /// seconds' bytes as written (leading zeros included), and the
    /// fraction's unit and count. The count keeps only the bytes its unit's
    /// width holds.
    struct DurationLayout: Sendable, Hashable {
        var negative = false
        var seconds: [UInt8] = []
        var unit: DurationFractionUnit?
        var count: UInt128 = 0

        var bytes: [UInt8] {
            let header =
                (negative ? 0x80 : 0) | (unit?.code ?? 0) << 4
                | UInt8(truncatingIfNeeded: seconds.count) & 0x0F
            let fraction = unit.map { Array(bigEndianBytes(count).suffix($0.width)) } ?? []
            return [header] + seconds + fraction
        }

        /// The seconds' value.
        var secondsValue: UInt128 { seconds.reduce(0) { $0 << 8 | UInt128($1) } }
    }

    /// The seconds' bytes with no leading zero: none for zero.
    func minimalBytes(_ value: UInt128) -> [UInt8] {
        Array(bigEndianBytes(value).drop { $0 == 0 })
    }

    /// The canonical layout of a duration (spec: encoding): the size's whole
    /// seconds in as few bytes as hold them, and the fraction, when there is
    /// one, in the first unit of the table that holds it whole.
    func canonicalLayout(of attoseconds: Int128) -> DurationLayout {
        let magnitude = attoseconds.magnitude
        let fraction = magnitude % attosecondsInASecond
        var layout = DurationLayout(
            negative: attoseconds < 0,
            seconds: minimalBytes(magnitude / attosecondsInASecond)
        )
        if fraction > 0,
            let unit = durationFractionUnits.first(where: { fraction % $0.attoseconds == 0 })
        {
            layout.unit = unit
            layout.count = fraction / unit.attoseconds
        }
        return layout
    }

    /// What the spec says bytes decode to.
    enum DurationReading: Sendable {
        case value(Int128)
        /// Every rule the bytes break; a decoder reports one of them.
        case invalid(Set<MMDurationDecodeFailure>)
    }

    /// Reads bytes by the spec's rules: the header's reserved values, the
    /// size the header gives, then the parts.
    func readDuration(_ bytes: [UInt8]) -> DurationReading {
        guard let header = bytes.first else { return .invalid([.empty]) }
        let length = Int(header & 0x0F)
        let code = Int(header >> 4 & 0x07)
        guard length <= 9, code <= 4 else { return .invalid([.reservedBits]) }
        let unit = code == 0 ? nil : durationFractionUnits[code - 1]
        let size = 1 + length + (unit?.width ?? 0)
        if bytes.count < size { return .invalid([.truncated]) }
        if bytes.count > size { return .invalid([.trailingBytes]) }

        let negative = header & 0x80 != 0
        let secondsBytes = Array(bytes[1..<(1 + length)])
        let seconds = secondsBytes.reduce(UInt128(0)) { $0 << 8 | UInt128($1) }
        let count = bytes[(1 + length)...].reduce(UInt128(0)) { $0 << 8 | UInt128($1) }
        var broken: Set<MMDurationDecodeFailure> = []
        if secondsBytes.first == 0 { broken.insert(.nonCanonical) }
        var fraction: UInt128 = 0
        if let unit {
            if count >= unit.bound {
                broken.insert(.fractionOutOfRange)
            } else {
                fraction = count * unit.attoseconds
                let coarsest = durationFractionUnits.first { fraction % $0.attoseconds == 0 }
                if fraction == 0 || coarsest != unit { broken.insert(.nonCanonical) }
            }
        }
        if negative && seconds == 0 && fraction == 0 { broken.insert(.nonCanonical) }
        guard broken.isEmpty else { return .invalid(broken) }

        let (scaled, scaleOverflow) = seconds.multipliedReportingOverflow(by: attosecondsInASecond)
        let (magnitude, sumOverflow) = scaled.addingReportingOverflow(fraction)
        guard !scaleOverflow, !sumOverflow, durationFits(magnitude: magnitude, negative: negative)
        else {
            return .invalid([.outOfRange])
        }
        return .value(signedAttoseconds(magnitude: magnitude, negative: negative))
    }

    /// The canonical text of a duration: `PT0S` for zero; otherwise a `-`
    /// when negative, `PT`, and the hours, minutes and seconds that are not
    /// zero, the seconds with their fraction's 18 digits less the trailing
    /// zeros.
    func canonicalDurationText(of attoseconds: Int128) -> String {
        guard attoseconds != 0 else { return "PT0S" }
        let magnitude = attoseconds.magnitude
        let (wholeSeconds, fraction) = magnitude.quotientAndRemainder(
            dividingBy: attosecondsInASecond
        )
        let (hours, rest) = wholeSeconds.quotientAndRemainder(dividingBy: 3_600)
        let (minutes, seconds) = rest.quotientAndRemainder(dividingBy: 60)
        var text = attoseconds < 0 ? "-PT" : "PT"
        if hours > 0 { text += "\(hours)H" }
        if minutes > 0 { text += "\(minutes)M" }
        if seconds > 0 || fraction > 0 {
            // 10¹⁸ plus the fraction is a 1 and the fraction's 18 digits.
            var digits = String(String(attosecondsInASecond + fraction).dropFirst())
            while digits.last == "0" { digits.removeLast() }
            text += "\(seconds)" + (digits.isEmpty ? "" : ".\(digits)") + "S"
        }
        return text
    }

    /// What the grammar of `MMDuration.parse` makes of text, read through a
    /// regular expression: `["-"] "P" [n "D"] ["T" [n "H"] [n "M"] [n ["." f]
    /// "S"]]` with a component, and one after a `T`.
    func modelDuration(_ text: String) -> Result<Int128, MMDateTimeParseFailure> {
        let grammar =
            /(-)?P(?:([0-9]+)D)?(T(?:([0-9]+)H)?(?:([0-9]+)M)?(?:([0-9]+)(?:\.([0-9]{1,18}))?S)?)?/
        // Scalar by scalar, as the parser reads bytes: a combining mark is
        // a character of its own, never part of a digit's.
        guard let match = text.wholeMatch(of: grammar.matchingSemantics(.unicodeScalar)) else {
            return .failure(.malformedText)
        }
        let (_, sign, days, time, hours, minutes, seconds, fraction) = match.output
        let numbers: [(Substring?, UInt128)] = [
            (days, 86_400), (hours, 3_600), (minutes, 60), (seconds, 1),
        ]
        guard numbers.contains(where: { $0.0 != nil }) else { return .failure(.malformedText) }
        if time != nil, hours == nil, minutes == nil, seconds == nil {
            return .failure(.malformedText)
        }
        var total: UInt128 = 0
        var overflowed = false
        for case (let digits?, let factor) in numbers {
            guard let number = UInt128(String(digits)) else {
                overflowed = true
                continue
            }
            let (product, productOverflow) = number.multipliedReportingOverflow(by: factor)
            let (sum, sumOverflow) = total.addingReportingOverflow(product)
            overflowed = overflowed || productOverflow || sumOverflow
            total = sum
        }
        let padded = (fraction.map(String.init) ?? "") + String(repeating: "0", count: 18)
        let fractionValue = UInt128(padded.prefix(18))!
        let (scaled, scaleOverflow) = total.multipliedReportingOverflow(by: attosecondsInASecond)
        let (magnitude, sumOverflow) = scaled.addingReportingOverflow(fractionValue)
        let negative = sign != nil
        guard !overflowed, !scaleOverflow, !sumOverflow,
            durationFits(magnitude: magnitude, negative: negative)
        else {
            return .failure(.invalidComponent)
        }
        return .success(signedAttoseconds(magnitude: magnitude, negative: negative))
    }

    /// Duration text, and how it was made, for the statistics report.
    struct DurationText: Sendable, CustomStringConvertible {
        var text: String
        var textBreak: DurationTextBreak?
        var atTheEnd = false
        var description: String { text.debugDescription }
    }

    /// One way to make text that may break the grammar. A break can leave
    /// grammatical text (a component moved where there is only one), so the
    /// model, not the break, says what the text is.
    enum DurationTextBreak: String, CaseIterable, Sendable {
        case noP = "no P"
        case lowercase = "a lowercase designator"
        case calendarUnit = "a year, month or week"
        case outOfOrder = "components out of order"
        case repeated = "a component twice"
        case fractionOffSeconds = "a fraction off the seconds"
        case emptyTime = "a T with no time after it"
        case timeWithoutT = "time without a T"
        case nothing = "no component"
        case longFraction = "19 fraction digits"
        case emptyFraction = "a dot with no digits"
        case comma = "a comma for the dot"
        case plusSign = "a plus sign"
        case stranger = "a stray character"
        case unicodeDigit = "a digit that is not ASCII"
        case missingNumber = "a designator with no number"
    }

    enum DurationGenerators {
        /// The most whole seconds a duration holds.
        static let maximumSeconds: UInt128 = (UInt128(1) << 127) / attosecondsInASecond

        /// Whole seconds: often under a year, often at an edge of a length in
        /// bytes or of a clock unit, or any up to the range's end.
        static let seconds: Gen<UInt128> = .oneOf(
            .integer(in: 0...(86_400 * 366)),
            .element(
                of: [
                    0, 1, 59, 60, 3_599, 3_600, 86_399, 86_400, maximumSeconds - 1, maximumSeconds,
                ]
                    + (1...8).flatMap { [(UInt128(1) << (8 * $0)) - 1, UInt128(1) << (8 * $0)] }
            ),
            .integer(in: 0...maximumSeconds)
        )

        /// A fraction's count in its unit that no coarser unit holds whole.
        static func counts(in unit: DurationFractionUnit) -> Gen<UInt128> {
            Gen<UInt128>.oneOf(
                .integer(in: 1...(unit.bound - 1)),
                .element(of: [1, unit.bound - 1])
            )
            .map { count in
                let coarser = durationFractionUnits.first {
                    (count * unit.attoseconds) % $0.attoseconds == 0
                }
                return coarser == unit ? count : count + 1
            }
        }

        /// A sign, whole seconds and a fraction in one unit or none, so every
        /// unit and every length of seconds comes up. A size past the range
        /// stops at its end.
        static let shapedAttoseconds: Gen<Int128> = Gen { tc in
            let negative = try tc.draw(Gen<Bool>.bool())
            let seconds = try tc.draw(Self.seconds)
            var fraction: UInt128 = 0
            let units: [DurationFractionUnit?] = [nil] + durationFractionUnits
            if let unit = try tc.draw(Gen<DurationFractionUnit?>.element(of: units)) {
                fraction = try tc.draw(counts(in: unit)) * unit.attoseconds
            }
            let magnitude = seconds * attosecondsInASecond + fraction
            guard durationFits(magnitude: magnitude, negative: negative) else {
                return negative ? .min : .max
            }
            return signedAttoseconds(magnitude: magnitude, negative: negative)
        }

        /// Half shaped, a quarter any, a quarter at an edge.
        static let attoseconds: Gen<Int128> = .oneOf(
            shapedAttoseconds,
            shapedAttoseconds,
            .integer(),
            .element(of: [0, 0, 1, -1, .max, .min, .max - 1, .min + 1, 1_000_000_000_000_000_000])
        )

        static let durations: Gen<MMDuration> = attoseconds.map(duration(attoseconds:))

        /// Digits for a component: a small number, any 128-bit one, a run
        /// of 22 to 45 digits, past the range in any unit, or a number near
        /// the most whole seconds the range holds, maybe after leading zeros.
        static let numbers: Gen<String> = Gen { tc in
            let digits = try tc.draw(
                Gen<String>.oneOf(
                    Gen<Int>.int(in: 0...100_000).map { String($0) },
                    Gen<Int>.int(in: 0...100_000).map { String($0) },
                    Gen<UInt128>.integer().map { String($0) },
                    Gen<[Int]>.array(of: .int(in: 1...9), count: 22...45).map {
                        $0.map(String.init).joined()
                    },
                    Gen<UInt128>.integer(in: (maximumSeconds - 2)...(maximumSeconds + 2)).map {
                        String($0)
                    }
                )
            )
            let zeros = try tc.draw(Gen<Int>.oneOf(.just(0), .int(in: 1...3)))
            return String(repeating: "0", count: zeros) + digits
        }

        /// A fraction's 1 to 18 digits.
        static let fractionDigits: Gen<String> = Gen<[Int]>.array(
            of: .int(in: 0...9),
            count: 1...18
        )
        .map { $0.map(String.init).joined() }

        /// Characters that are no part of the grammar.
        static let strangers = [" ", "/", "_", "x", "Z", "\u{2010}", "\u{FF1A}", "\u{0301}"]

        /// Text built from a sign, the components present, and maybe one
        /// break, as tokens joined.
        static let texts: Gen<DurationText> = Gen { tc in
            var sign = try tc.draw(Gen<Bool>.bool()) ? "-" : ""
            var designatorP = "P"
            // The components, D first, then H, M and S after the T.
            let present = try tc.draw(Gen<[Bool]>.array(of: .bool(), count: 4...4))
            var date: [String] = present[0] ? [try tc.draw(numbers) + "D"] : []
            var time: [String] = []
            for (index, designator) in ["H", "M"].enumerated() where present[index + 1] {
                time.append(try tc.draw(numbers) + designator)
            }
            if present[3] {
                let fraction = try tc.draw(Gen<String?>.optional(fractionDigits))
                time.append(try tc.draw(numbers) + (fraction.map { ".\($0)" } ?? "") + "S")
            }
            var designatorT = time.isEmpty ? "" : "T"
            // No break half the time.
            let textBreak = try tc.draw(
                Gen<DurationTextBreak?>.oneOf(
                    .just(nil),
                    Gen<DurationTextBreak>.element(of: DurationTextBreak.allCases).map { $0 }
                )
            )
            var characterBreak: ((inout String) throws -> Void)?
            switch textBreak {
                case .noP: designatorP = ""
                case .lowercase:
                    designatorP = "p"
                    if try tc.draw(Gen<Bool>.bool()) { designatorT = designatorT.lowercased() }
                    time = time.map { $0.lowercased() }
                    date = date.map { $0.lowercased() }
                case .calendarUnit:
                    date.insert(
                        try tc.draw(numbers) + tc.draw(.element(of: ["Y", "M", "W"])),
                        at: 0
                    )
                case .outOfOrder:
                    if time.count >= 2 {
                        time.swapAt(0, time.count - 1)
                    } else if let day = date.first {
                        date = []
                        time.append(day)
                        designatorT = "T"
                    } else {
                        date = time
                        time = []
                    }
                case .repeated:
                    if let last = time.last { time.append(last) } else { date += date }
                case .fractionOffSeconds:
                    // On the days, the hours or the minutes, adding minutes
                    // when none of them is there.
                    let digits = try tc.draw(fractionDigits)
                    var places = time.indices.filter { !time[$0].hasSuffix("S") }.map { $0 + 1 }
                    if !date.isEmpty { places.append(0) }
                    if places.isEmpty {
                        time.insert(try tc.draw(numbers) + "M", at: 0)
                        designatorT = "T"
                        places = [1]
                    }
                    let place = try tc.draw(Gen<Int>.element(of: places))
                    if place == 0 {
                        date[0] = String(date[0].dropLast()) + ".\(digits)D"
                    } else {
                        let component = time[place - 1]
                        time[place - 1] =
                            String(component.dropLast()) + ".\(digits)" + String(component.last!)
                    }
                case .emptyTime:
                    time = []
                    designatorT = "T"
                case .timeWithoutT:
                    designatorT = ""
                case .nothing:
                    date = []
                    time = []
                    designatorT = try tc.draw(Gen<Bool>.bool()) ? "T" : ""
                case .longFraction:
                    let digits = try tc.draw(
                        Gen<[Int]>.array(of: .int(in: 0...9), count: 19...40).map {
                            $0.map(String.init).joined()
                        }
                    )
                    time =
                        time.filter { !$0.hasSuffix("S") } + [try tc.draw(numbers) + ".\(digits)S"]
                    designatorT = "T"
                case .emptyFraction:
                    time = time.filter { !$0.hasSuffix("S") } + [try tc.draw(numbers) + ".S"]
                    designatorT = "T"
                case .comma:
                    time =
                        time.filter { !$0.hasSuffix("S") }
                        + [try tc.draw(numbers) + ",\(try tc.draw(fractionDigits))S"]
                    designatorT = "T"
                case .plusSign: sign = "+"
                case .stranger:
                    let stranger = try tc.draw(Gen<String>.element(of: strangers))
                    characterBreak = { text in
                        let offset = try tc.draw(Gen<Int>.int(in: 0...text.count))
                        text.insert(
                            contentsOf: stranger,
                            at: text.index(text.startIndex, offsetBy: offset)
                        )
                    }
                case .unicodeDigit:
                    characterBreak = { text in
                        let digits = text.indices.filter { text[$0].isASCII && text[$0].isNumber }
                        guard !digits.isEmpty else { return }
                        let at = digits[try tc.draw(Gen<Int>.int(in: 0...(digits.count - 1)))]
                        text.replaceSubrange(
                            at...at,
                            with: try tc.draw(.element(of: ["٣", "５", "७"]))
                        )
                    }
                case .missingNumber:
                    let designator = try tc.draw(Gen<String>.element(of: ["D", "H", "M", "S"]))
                    if designator == "D" { date = ["D"] } else { time.append(designator) }
                    if designator != "D" { designatorT = "T" }
                case nil:
                    break
            }
            var text = sign + designatorP + date.joined() + designatorT + time.joined()
            try characterBreak?(&text)
            return DurationText(text: text, textBreak: textBreak)
        }

        /// Text at the range's end: the most whole seconds the range holds,
        /// or one fewer or more, in seconds alone or as hours, minutes and
        /// seconds, with the fraction that reaches the end, or one
        /// attosecond less or more.
        static let textsAtTheEnd: Gen<DurationText> = Gen { tc in
            let negative = try tc.draw(Gen<Bool>.bool())
            let seconds = try tc.draw(
                Gen<UInt128>.integer(in: (maximumSeconds - 1)...(maximumSeconds + 1))
            )
            let limit = (UInt128(1) << 127) - (negative ? 0 : 1)
            let fraction = limit % attosecondsInASecond
            let shifted = try tc.draw(.element(of: [fraction - 1, fraction, fraction + 1]))
            let digits = String(String(attosecondsInASecond + shifted).dropFirst())
            let time =
                try tc.draw(Gen<Bool>.bool())
                ? "\(seconds / 3_600)H\(seconds % 3_600 / 60)M\(seconds % 60).\(digits)S"
                : "\(seconds).\(digits)S"
            return DurationText(
                text: (negative ? "-" : "") + "PT" + time,
                textBreak: nil,
                atTheEnd: true
            )
        }

        static let allTexts: Gen<DurationText> = .oneOf(texts, texts, texts, textsAtTheEnd)

        /// A header byte breaking a rule, or keeping them all: a seconds
        /// length past 9, each reserved fraction unit, then each unit and
        /// sign.
        static let ruleHeaders: [UInt8] = [
            0x0A, 0x0F, 0x50, 0x60, 0x70, 0xFF, 0x00, 0x09, 0x80, 0x89, 0x10, 0x23, 0x35, 0x49,
            0xC9,
        ]

        /// Bytes laid out as a header says: seconds often with no leading
        /// zero, a count often within its unit's bound, then cut short, run
        /// on, or left exact.
        static func laidOut(after header: UInt8, _ tc: TestCase) throws -> [UInt8] {
            var bytes = [header]
            let length = Int(header & 0x0F)
            let code = Int(header >> 4 & 0x07)
            for index in 0..<length {
                // A leading zero a third of the time.
                let byte: Gen<UInt8> =
                    index == 0
                    ? .oneOf(.integer(in: 1...255), .integer(in: 1...255), .just(0)) : .integer()
                bytes.append(try tc.draw(byte))
            }
            if (1...4).contains(code) {
                let unit = durationFractionUnits[code - 1]
                let count = try tc.draw(
                    Gen<UInt128>.oneOf(counts(in: unit), .element(of: [0, unit.bound]), .integer())
                )
                bytes += bigEndianBytes(count).suffix(unit.width)
            } else if code > 4 {
                bytes += try tc.draw(Gen<[UInt8]>.bytes(count: 0...8))
            }
            // Exact half the time, so the rules checked after the length come up.
            switch try tc.draw(Gen<Int>.oneOf(.just(0), .int(in: 1...2))) {
                case 1: bytes.removeLast(try tc.draw(Gen<Int>.int(in: 1...bytes.count)))
                case 2: bytes += try tc.draw(Gen<[UInt8]>.bytes(count: 1...Int.max))
                default: break
            }
            return bytes
        }

        /// The rule a broken encoding breaks, named as the decoder names it.
        enum RuleBreak: String, CaseIterable, Sendable {
            case reservedBits, truncated, trailingBytes, fractionOutOfRange, nonCanonical,
                outOfRange
        }

        /// A canonical encoding with one rule broken: a reserved seconds
        /// length or fraction unit, bytes cut off or run on, a count at or
        /// past its unit's bound, another encoding of the same value (a
        /// leading zero byte on the seconds, the fraction in a finer unit, a
        /// fraction of zero, a negative zero), or a size past the range.
        static let oneRuleBroken: Gen<(RuleBreak, [UInt8])> = Gen { tc in
            let rule = try tc.draw(Gen<RuleBreak>.element(of: RuleBreak.allCases))
            var layout = canonicalLayout(of: try tc.draw(attoseconds))
            switch rule {
                case .reservedBits:
                    var bytes = layout.bytes
                    if try tc.draw(Gen<Bool>.bool()) {
                        bytes[0] = bytes[0] & 0xF0 | (try tc.draw(Gen<UInt8>.integer(in: 10...15)))
                    } else {
                        bytes[0] =
                            bytes[0] & 0x8F | (try tc.draw(Gen<UInt8>.integer(in: 5...7))) << 4
                    }
                    return (rule, bytes)
                case .truncated:
                    if layout.bytes.count == 1 { layout.seconds = [1] }
                    var bytes = layout.bytes
                    bytes.removeLast(try tc.draw(Gen<Int>.int(in: 1...(bytes.count - 1))))
                    return (rule, bytes)
                case .trailingBytes:
                    return (
                        rule, layout.bytes + (try tc.draw(Gen<[UInt8]>.bytes(count: 1...Int.max)))
                    )
                case .fractionOutOfRange:
                    let unit = try tc.draw(
                        Gen<DurationFractionUnit>.element(of: durationFractionUnits)
                    )
                    layout.unit = unit
                    layout.count = try tc.draw(
                        Gen<UInt128>.oneOf(
                            .just(unit.bound),
                            .integer(in: unit.bound...((UInt128(1) << (8 * unit.width)) - 1))
                        )
                    )
                    return (rule, layout.bytes)
                case .nonCanonical:
                    switch try tc.draw(Gen<Int>.int(in: 0...3)) {
                        case 0 where layout.seconds.count < 9:
                            layout.seconds.insert(0, at: 0)
                        case 1 where (layout.unit?.code ?? 4) < 4:
                            let current = layout.unit!
                            let unit = try tc.draw(
                                Gen<DurationFractionUnit>.element(
                                    of: durationFractionUnits.filter { $0.code > current.code }
                                )
                            )
                            layout.count *= current.attoseconds / unit.attoseconds
                            layout.unit = unit
                        case 2 where layout.unit == nil:
                            layout.unit = try tc.draw(.element(of: durationFractionUnits))
                            layout.count = 0
                        default:
                            layout = DurationLayout(negative: true)
                    }
                    return (rule, layout.bytes)
                case .outOfRange:
                    let negative = try tc.draw(Gen<Bool>.bool())
                    let limit = (UInt128(1) << 127) - (negative ? 0 : 1)
                    let seconds = try tc.draw(
                        Gen<UInt128>.oneOf(
                            .just(maximumSeconds),
                            .integer(in: (maximumSeconds + 1)...((UInt128(1) << 72) - 1))
                        )
                    )
                    // At the last second, a fraction past the limit's.
                    let least = seconds == maximumSeconds ? limit % attosecondsInASecond + 1 : 0
                    let fraction = try tc.draw(
                        Gen<UInt128>.oneOf(
                            .just(least),
                            .integer(in: least...(attosecondsInASecond - 1))
                        )
                    )
                    var layout = DurationLayout(negative: negative, seconds: minimalBytes(seconds))
                    if fraction > 0,
                        let unit = durationFractionUnits.first(where: {
                            fraction % $0.attoseconds == 0
                        })
                    {
                        layout.unit = unit
                        layout.count = fraction / unit.attoseconds
                    }
                    return (rule, layout.bytes)
            }
        }

        /// Bytes to decode: two fifths with one rule broken, a fifth
        /// canonical encodings, a fifth laid out after a header from the
        /// menu, the rest corrupted, laid out after any header, or any.
        static let decodeInputs: Gen<ReaderInput> = .oneOf(
            oneRuleBroken.map { ReaderInput(kind: "a broken \($0.0)", bytes: $0.1) },
            oneRuleBroken.map { ReaderInput(kind: "a broken \($0.0)", bytes: $0.1) },
            attoseconds.map {
                ReaderInput(kind: "a canonical encoding", bytes: canonicalLayout(of: $0).bytes)
            },
            Gen { tc in try laidOut(after: tc.draw(.element(of: ruleHeaders)), tc) }
                .map { ReaderInput(kind: "a header from the menu, laid out", bytes: $0) },
            .oneOf(
                Hegel.zip(attoseconds, mutations).map {
                    ReaderInput(
                        kind: "a corrupted encoding",
                        bytes: mutated(canonicalLayout(of: $0).bytes, by: $1)
                    )
                },
                Gen { tc in try laidOut(after: tc.draw(Gen<UInt8>.integer()), tc) }
                    .map { ReaderInput(kind: "any header, laid out", bytes: $0) },
                Gen<[UInt8]>.bytes().map { ReaderInput(kind: "any bytes", bytes: $0) },
                Gen<[UInt8]>.bytes().map { ReaderInput(kind: "any bytes", bytes: $0) }
            )
        )
    }

    /// The unit a canonical encoding writes the fraction in, as a constant
    /// label for the statistics report.
    func unitLabel(_ layout: DurationLayout) -> String {
        layout.unit?.name ?? "no fraction"
    }

    @Suite("Duration properties", .hegel, .offTheCooperativePool)
    struct DurationProperties {
        /// Every duration renders as its canonical text and parses back to
        /// itself.
        ///
        /// Mutation check: rendering hours past 24 as days, or trimming the
        /// fraction's zeros from the front, fails here.
        @Test
        func everyDurationRoundTripsThroughText() throws {
            try property(
                reaching: ["negative"],
                reachingAfter: [
                    "attoseconds": 1_000, "milliseconds": 1_000, "no fraction": 1_000,
                    "the range's end": 1_000, "zero": 1_000,
                ]
            ) { tc in
                let attoseconds = try #draw(DurationGenerators.attoseconds, from: tc)
                let value = duration(attoseconds: attoseconds)
                if attoseconds < 0 { try tc.event("negative") }
                if attoseconds == 0 { try tc.event("zero") }
                if attoseconds == .max || attoseconds == .min { try tc.event("the range's end") }
                try tc.event(unitLabel(canonicalLayout(of: attoseconds)))
                #expect(value.description == canonicalDurationText(of: attoseconds))
                #expect(MMDuration.parse(value.description) == .success(value))
            }
        }

        /// Text parses exactly as the grammar reads it: the duration its
        /// components add up to, `invalidComponent` when that is past the
        /// range of `Duration`, and `malformedText` for text the grammar
        /// does not take.
        ///
        /// Mutation check: a parser that lets a `T` stand with nothing
        /// after it, or wraps past the range's end, fails here at 100
        /// cases; one that takes a fraction on the minutes, at 1,000.
        @Test
        func parsingFollowsTheGrammar() throws {
            try property(
                reaching: ["failed with malformedText"],
                reachingAfter: [
                    "a fraction": 1_000, "a break": 1_000, "days": 1_000,
                    "failed with invalidComponent": 1_000, "no break": 1_000, "parsed": 1_000,
                    "the range's end": 1_000,
                ]
            ) { tc in
                let text = try #draw(DurationGenerators.allTexts, from: tc)
                if text.atTheEnd { try tc.event("the range's end") }
                try tc.event(text.textBreak == nil ? "no break" : "a break")
                if let textBreak = text.textBreak { try tc.event(textBreak.rawValue) }
                if text.text.contains("D") { try tc.event("days") }
                if text.text.contains(".") { try tc.event("a fraction") }
                let parsed = MMDuration.parse(text.text)
                switch parsed {
                    case .success: try tc.event("parsed")
                    case .failure(let failure): try tc.event("failed with \(failure)")
                }
                #expect(parsed == modelDuration(text.text).map(duration(attoseconds:)), "\(text)")
            }
        }

        /// Every duration encodes to its canonical layout, and decodes back
        /// to itself.
        ///
        /// Mutation check: choosing the finest unit that holds a fraction,
        /// or writing the seconds in a fixed 8 bytes, fails here.
        @Test
        func everyDurationRoundTripsThroughBytes() throws {
            try property(
                reaching: ["attoseconds", "negative"],
                reachingAfter: [
                    "microseconds": 1_000, "milliseconds": 1_000, "nanoseconds": 1_000,
                    "nine bytes of seconds": 1_000, "no fraction": 1_000, "the range's end": 1_000,
                ]
            ) { tc in
                let attoseconds = try #draw(DurationGenerators.attoseconds, from: tc)
                let value = duration(attoseconds: attoseconds)
                let layout = canonicalLayout(of: attoseconds)
                try tc.event(unitLabel(layout))
                if attoseconds < 0 { try tc.event("negative") }
                if layout.seconds.count == 9 { try tc.event("nine bytes of seconds") }
                if attoseconds == .max || attoseconds == .min { try tc.event("the range's end") }
                let encoded = value.encoded()
                #expect(encoded == layout.bytes)
                #expect(MMDuration.decode(encoded) == .success(value))
            }
        }

        /// Any bytes decode as the spec reads them: the duration they spell,
        /// or a failure naming a rule they break. A decoded duration encodes
        /// back to the same bytes, so a duration has exactly one encoding.
        ///
        /// Mutation check: taking a fraction a coarser unit holds, a
        /// negative zero, or a leading zero byte on the seconds, or reading
        /// a size past the range as the range's end, fails here.
        @Test
        func decodingFollowsTheRules() throws {
            try property(
                reachingAfter: [
                    "a canonical encoding": 1_000, "a corrupted encoding": 1_000,
                    "a header from the menu, laid out": 1_000, "any bytes": 1_000,
                    "any header, laid out": 1_000, "decoded": 1_000,
                    "failed with fractionOutOfRange": 1_000, "failed with nonCanonical": 1_000,
                    "failed with outOfRange": 1_000, "failed with reservedBits": 1_000,
                    "failed with trailingBytes": 1_000, "failed with truncated": 1_000,
                ]
            ) { tc in
                let input = try #draw(DurationGenerators.decodeInputs, from: tc)
                try tc.event(input.kind)
                let decoded = MMDuration.decode(input.bytes)
                switch decoded {
                    case .success: try tc.event("decoded")
                    case .failure(let failure): try tc.event("failed with \(failure)")
                }
                switch readDuration(input.bytes) {
                    case .value(let attoseconds):
                        #expect(
                            decoded == .success(duration(attoseconds: attoseconds)),
                            "\(input.bytes)"
                        )
                        if case .success(let value) = decoded {
                            #expect(value.encoded() == input.bytes)
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
    }

#endif

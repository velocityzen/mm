/// A span of elapsed time, exact to the attosecond: the wire's `duration`
/// kind. It holds a Swift `Duration`, so it covers that type's whole range
/// (±2¹²⁷ attoseconds) and converts both ways without loss:
///
/// ```swift
/// let timeout = MMDuration(.seconds(90))
/// try await Task.sleep(for: timeout.duration)
/// let elapsed = MMDuration(later - earlier)   // two MMTimestamps
/// ```
///
/// Its own type, not `Duration` itself, for the same reason the calendar
/// kinds have theirs: its `Codable` form is the ISO 8601 text JSON coders and
/// the generated CLI print and read (`PT1H30M`), where `Duration`'s is a
/// pair of integers. On the wire it travels as MessagePack `bin` holding the
/// compact binary form of ``encoded()`` (the duration article in MMWire's
/// DocC catalog), the time kinds' coder-level shortcut.
///
/// A duration is an exact amount of time, not a calendar quantity: there are
/// no years or months, whose lengths vary. The text form counts hours,
/// minutes and seconds; a day in parsed text is 86,400 seconds.
public struct MMDuration: Sendable, Hashable, Comparable {
    /// The span.
    public var duration: Duration

    public init(_ duration: Duration) {
        self.duration = duration
    }

    /// No time at all.
    public static let zero = MMDuration(.zero)

    public static func < (lhs: MMDuration, rhs: MMDuration) -> Bool {
        lhs.duration < rhs.duration
    }

    /// The span in attoseconds, its sign included.
    var attoseconds: Int128 { self.duration.attoseconds }

    init(attoseconds: Int128) {
        self.duration = Duration(attoseconds: attoseconds)
    }

    /// The span's size in attoseconds and whether it is negative, or nil
    /// when a size and a sign out of the range of `Duration` (more than
    /// 2¹²⁷ − 1 attoseconds forward, or 2¹²⁷ back).
    init?(magnitude: UInt128, negative: Bool) {
        if negative {
            guard magnitude <= Int128.min.magnitude else { return nil }
            self.init(attoseconds: magnitude == Int128.min.magnitude ? .min : -Int128(magnitude))
        } else {
            guard magnitude <= UInt128(Int128.max) else { return nil }
            self.init(attoseconds: Int128(magnitude))
        }
    }
}

private let attosecondsPerSecond: UInt128 = 1_000_000_000_000_000_000

// MARK: - ISO 8601 text

extension MMDuration {
    /// Parses ISO 8601 duration text: `PT1H30M`, `PT0.25S`, `-PT5M`,
    /// `P2DT12H`. The grammar is
    /// `["-"] "P" [n "D"] ["T" [n "H"] [n "M"] [n ["." f] "S"]]`, with at
    /// least one component, at least one after a `T`, each `n` one or more
    /// digits, and `f` 1 to 18 digits. A day is 86,400 seconds; years,
    /// months and weeks, which are calendar quantities, have no place in it.
    /// Text that breaks the grammar is `.malformedText`; grammatical text
    /// naming a span beyond the range of `Duration` is `.invalidComponent`.
    public static func parse(
        _ text: some StringProtocol
    ) -> Result<MMDuration, MMDateTimeParseFailure> {
        let bytes = Array(text.utf8)
        var index = 0
        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        let negative = peek() == UInt8(ascii: "-")
        if negative { index += 1 }
        guard peek() == UInt8(ascii: "P") else { return .failure(.malformedText) }
        index += 1

        var magnitude: UInt128 = 0
        var overflowed = false
        func add(_ value: UInt128, times factor: UInt128 = 1) {
            let (product, productOverflow) = value.multipliedReportingOverflow(by: factor)
            let (sum, sumOverflow) = magnitude.addingReportingOverflow(product)
            if productOverflow || sumOverflow { overflowed = true } else { magnitude = sum }
        }

        var inTime = false
        var components = 0
        var timeComponents = 0
        // The designators in their order: D, then H, M, S after the T.
        var nextUnit = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "T") {
                guard !inTime else { return .failure(.malformedText) }
                inTime = true
                index += 1
                continue
            }
            let start = index
            var whole: UInt128 = 0
            var wholeOverflowed = false
            while let byte = peek(), (0x30...0x39).contains(byte) {
                let (shifted, shiftOverflow) = whole.multipliedReportingOverflow(by: 10)
                let (next, digitOverflow) = shifted.addingReportingOverflow(UInt128(byte - 0x30))
                if shiftOverflow || digitOverflow { wholeOverflowed = true } else { whole = next }
                index += 1
            }
            guard index > start else { return .failure(.malformedText) }
            var fraction: UInt128?
            if peek() == UInt8(ascii: ".") {
                index += 1
                var digits = 0
                var value: UInt128 = 0
                while let byte = peek(), (0x30...0x39).contains(byte) {
                    guard digits < 18 else { return .failure(.malformedText) }
                    value = value * 10 + UInt128(byte - 0x30)
                    digits += 1
                    index += 1
                }
                guard digits > 0 else { return .failure(.malformedText) }
                for _ in digits..<18 { value *= 10 }
                fraction = value
            }
            guard let designator = peek() else { return .failure(.malformedText) }
            index += 1
            let unit: Int
            let seconds: UInt128
            switch (designator, inTime) {
                case (UInt8(ascii: "D"), false): (unit, seconds) = (0, 86_400)
                case (UInt8(ascii: "H"), true): (unit, seconds) = (1, 3_600)
                case (UInt8(ascii: "M"), true): (unit, seconds) = (2, 60)
                case (UInt8(ascii: "S"), true): (unit, seconds) = (3, 1)
                default: return .failure(.malformedText)
            }
            guard unit >= nextUnit, fraction == nil || unit == 3 else {
                return .failure(.malformedText)
            }
            nextUnit = unit + 1
            components += 1
            if inTime { timeComponents += 1 }
            if wholeOverflowed { overflowed = true }
            add(whole, times: seconds * attosecondsPerSecond)
            add(fraction ?? 0)
        }
        guard components > 0, !inTime || timeComponents > 0 else {
            return .failure(.malformedText)
        }
        guard !overflowed, let value = MMDuration(magnitude: magnitude, negative: negative) else {
            return .failure(.invalidComponent)
        }
        return .success(value)
    }
}

extension MMDuration: CustomStringConvertible, LosslessStringConvertible {
    /// The canonical text: `PT0S` for zero; otherwise a `-` when negative,
    /// `PT`, then the hours, minutes and seconds that are not zero, the
    /// seconds with a fraction of up to 18 digits, trailing zeros dropped:
    /// `PT1H30M`, `PT25H`, `-PT0.5S`, `PT1M0.000000001S`.
    public var description: String {
        let attoseconds = self.attoseconds
        guard attoseconds != 0 else { return "PT0S" }
        let magnitude = attoseconds.magnitude
        let wholeSeconds = magnitude / attosecondsPerSecond
        let fraction = magnitude % attosecondsPerSecond
        let hours = wholeSeconds / 3_600
        let minutes = wholeSeconds % 3_600 / 60
        let seconds = wholeSeconds % 60
        var text = attoseconds < 0 ? "-PT" : "PT"
        if hours > 0 { text += "\(hours)H" }
        if minutes > 0 { text += "\(minutes)M" }
        if seconds > 0 || fraction > 0 {
            text += "\(seconds)"
            if fraction > 0 {
                var digits = String(fraction)
                digits = String(repeating: "0", count: 18 - digits.count) + digits
                while digits.hasSuffix("0") { digits.removeLast() }
                text += "." + digits
            }
            text += "S"
        }
        return text
    }

    public init?(_ description: String) {
        guard case .success(let value) = Self.parse(description) else { return nil }
        self = value
    }
}

extension MMDuration: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        switch Self.parse(text) {
            case .success(let value):
                self = value
            case .failure(let failure):
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "'\(text)' is not an ISO 8601 duration (PT1H30M) (\(failure))"
                )
        }
    }
}

extension MMDuration: SchemaDescribable {
    public static var schema: TypeSchema { .duration }
}

// The probe walks containing decoders with placeholder instances; the
// decoder rejects the probe's empty string, so zero stands in.
extension MMDuration: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any { MMDuration.zero }
}

// MARK: - Binary encoding

/// Why bytes are not a duration's binary encoding: one case per rule of the
/// duration article in MMWire's DocC catalog.
public enum MMDurationDecodeFailure: Error, Sendable, Hashable {
    /// No bytes at all.
    case empty
    /// A seconds length above 9 or a fraction unit above 4 in the header.
    case reservedBits
    /// Fewer bytes than the header demands.
    case truncated
    /// More bytes than the header demands (the encoding self-delimits).
    case trailingBytes
    /// A fraction at or above its unit's bound: 1,000 milliseconds, 10⁶
    /// microseconds, 10⁹ nanoseconds, 10¹⁸ attoseconds.
    case fractionOutOfRange
    /// A value with another, shorter encoding: seconds with a leading zero
    /// byte, a fraction of zero, a fraction a coarser unit holds, or a
    /// negative zero.
    case nonCanonical
    /// A span beyond the range of `Duration`.
    case outOfRange
}

extension MMDuration {
    /// A unit the fraction of a second is written in: its header code, its
    /// width in bytes, and the attoseconds in one of it.
    struct FractionUnit: Sendable {
        let code: UInt8
        let width: Int
        let attoseconds: UInt128

        /// One second, in this unit.
        var perSecond: UInt128 { attosecondsPerSecond / self.attoseconds }

        static let units: [FractionUnit] = [
            FractionUnit(code: 1, width: 2, attoseconds: 1_000_000_000_000_000),
            FractionUnit(code: 2, width: 3, attoseconds: 1_000_000_000_000),
            FractionUnit(code: 3, width: 4, attoseconds: 1_000_000_000),
            FractionUnit(code: 4, width: 8, attoseconds: 1),
        ]
    }

    private static let negativeBit: UInt8 = 0x80

    /// The canonical binary encoding, 1 to 18 bytes: a header byte (bit 7
    /// set for a negative span, bits 4 to 6 the fraction's unit, bits 0 to 3
    /// the length of the seconds), the whole seconds of the span's size
    /// big-endian with no leading zero byte, then the fraction, when it is
    /// not zero, in the coarsest unit that holds it exactly: milliseconds in
    /// 2 bytes, microseconds in 3, nanoseconds in 4, attoseconds in 8.
    public func encoded() -> [UInt8] {
        let attoseconds = self.attoseconds
        let magnitude = attoseconds.magnitude
        let seconds = magnitude / attosecondsPerSecond
        let fraction = magnitude % attosecondsPerSecond

        var secondsBytes: [UInt8] = []
        var remaining = seconds
        while remaining > 0 {
            secondsBytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        var header = UInt8(secondsBytes.count)
        if attoseconds < 0 { header |= Self.negativeBit }
        var fractionBytes: [UInt8] = []
        if fraction > 0,
            let unit = FractionUnit.units.first(where: { fraction % $0.attoseconds == 0 })
        {
            header |= unit.code << 4
            let value = fraction / unit.attoseconds
            for shift in stride(from: (unit.width - 1) * 8, through: 0, by: -8) {
                fractionBytes.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        return [header] + secondsBytes + fractionBytes
    }

    /// Decodes one complete encoding, refusing every encoding but the
    /// canonical one, so a value has exactly one: decoding then encoding
    /// gives the same bytes back.
    public static func decode(
        _ bytes: some Collection<UInt8>
    ) -> Result<MMDuration, MMDurationDecodeFailure> {
        let bytes = Array(bytes)
        guard let header = bytes.first else { return .failure(.empty) }
        let secondsLength = Int(header & 0x0F)
        let unitCode = header >> 4 & 0x07
        guard secondsLength <= 9, unitCode <= 4 else { return .failure(.reservedBits) }
        let unit = unitCode == 0 ? nil : FractionUnit.units[Int(unitCode) - 1]
        let size = 1 + secondsLength + (unit?.width ?? 0)
        guard bytes.count >= size else { return .failure(.truncated) }
        guard bytes.count == size else { return .failure(.trailingBytes) }

        let secondsBytes = bytes[1..<(1 + secondsLength)]
        guard secondsBytes.first != 0 else { return .failure(.nonCanonical) }
        let seconds = secondsBytes.reduce(UInt128(0)) { $0 << 8 | UInt128($1) }
        var fraction: UInt128 = 0
        if let unit {
            let value = bytes[(1 + secondsLength)...].reduce(UInt128(0)) { $0 << 8 | UInt128($1) }
            guard value < unit.perSecond else { return .failure(.fractionOutOfRange) }
            // Zero, or a whole number of the next coarser unit.
            let coarser = unit.code == 4 ? UInt128(1_000_000_000) : 1_000
            guard value > 0, unit.code == 1 || value % coarser != 0 else {
                return .failure(.nonCanonical)
            }
            fraction = value * unit.attoseconds
        }
        let negative = header & Self.negativeBit != 0
        if negative && seconds == 0 && fraction == 0 { return .failure(.nonCanonical) }

        let (scaled, scaleOverflow) = seconds.multipliedReportingOverflow(by: attosecondsPerSecond)
        let (magnitude, sumOverflow) = scaled.addingReportingOverflow(fraction)
        guard !scaleOverflow, !sumOverflow,
            let value = MMDuration(magnitude: magnitude, negative: negative)
        else {
            return .failure(.outOfRange)
        }
        return .success(value)
    }
}

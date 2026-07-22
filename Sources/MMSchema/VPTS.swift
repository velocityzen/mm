/// VPTS — the Variable-Precision Timestamp (v0.2; normative spec: the VPTS
/// article in MMWire's DocC catalog): a
/// compact binary encoding of Gregorian date-time values whose **precision
/// is part of the value**. A value may stop at any granularity — year,
/// year-month, date, …, sub-second — declared by a bitmask header, so
/// `2026-07` is the month, never its first instant, and
/// `12:00:00.000000000` is not `12:00:00`.
///
/// ``MMVPTS`` is the decoded form: optional components whose presence chain
/// is validated at construction (year → month → … → second contiguously; a
/// fraction requires a second; an offset requires an hour). `nil` at the
/// codec boundary is the spec's **null timestamp** (header `0x00`).
///
/// Encoding is canonical by construction: WIDE only when the year exceeds
/// the narrow range or the fraction is declared in attoseconds, fields
/// big-endian in most-significant-first order — which is what makes
/// bytewise order equal chronological order for values of equal header
/// (spec §5). The decoder is liberal exactly where the spec is: it accepts
/// non-canonical WIDE for values that fit narrow (normalizing on
/// re-encode), and rejects everything §3 rejects.
public struct MMVPTS: Sendable, Hashable {
    /// Sub-second precision, width included: nanoseconds is the 9-digit
    /// (narrow) declaration, attoseconds the 18-digit (wide) one. The width
    /// is semantic — `.attoseconds(0)` declares 18 digits of precision —
    /// and drives the WIDE bit for the whole encoding (spec: a narrow year
    /// cannot be combined with a wide fraction, or vice versa).
    public enum Fraction: Sendable, Hashable {
        /// 0...999_999_999.
        case nanoseconds(UInt32)
        /// 0...999_999_999_999_999_999.
        case attoseconds(UInt64)
    }

    public var year: Int64?
    public var month: Int?
    public var day: Int?
    public var hour: Int?
    public var minute: Int?
    public var second: Int?
    public var fraction: Fraction?
    /// Minutes east of UTC, −1439...+1439; 0 is UTC ("Z").
    public var offsetMinutes: Int?

    /// Validating: nil unless the components satisfy the spec — contiguous
    /// presence from year down (no "year+day without month"), fraction only
    /// with a second, offset only with an hour, every field in range, and
    /// the day valid for its year/month. All-nil is not a value (the null
    /// timestamp is `Optional<MMVPTS>.none` at the codec boundary).
    public init?(
        year: Int64? = nil,
        month: Int? = nil,
        day: Int? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        second: Int? = nil,
        fraction: Fraction? = nil,
        offsetMinutes: Int? = nil
    ) {
        let presence = [
            year != nil, month != nil, day != nil, hour != nil, minute != nil, second != nil,
        ]
        // Contiguity: once a field is absent, everything finer is too.
        guard let deepest = presence.lastIndex(of: true) else { return nil }
        guard presence[0...deepest].allSatisfy({ $0 }) else { return nil }
        if fraction != nil && second == nil { return nil }
        if offsetMinutes != nil && hour == nil { return nil }

        if let month, !(1...12).contains(month) { return nil }
        if let day {
            guard
                let year, let month,
                (1...MMDate.daysIn(month: month, year: Int(clamping: year))).contains(day)
            else {
                return nil
            }
        }
        if let hour, !(0...23).contains(hour) { return nil }
        if let minute, !(0...59).contains(minute) { return nil }
        if let second, !(0...60).contains(second) { return nil }
        switch fraction {
            case .nanoseconds(let value):
                guard value <= 999_999_999 else { return nil }
            case .attoseconds(let value):
                guard value <= 999_999_999_999_999_999 else { return nil }
            case nil:
                break
        }
        if let offsetMinutes, !(-1439...1439).contains(offsetMinutes) { return nil }

        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.fraction = fraction
        self.offsetMinutes = offsetMinutes
    }
}

/// Why a byte sequence is not a valid VPTS encoding — the spec's §3 rules,
/// one case per rule.
public enum MMVPTSDecodeFailure: Error, Sendable, Hashable {
    /// Fewer bytes than the header(s) demand.
    case truncated
    /// More bytes than the header(s) demand (VPTS is self-delimiting).
    case trailingBytes
    /// The presence mask has a gap (`year+day` without `month`).
    case nonContiguousMask
    /// FRACTION set without SECOND.
    case fractionWithoutSecond
    /// EXT set with an empty (0x00) extension byte.
    case emptyExtension
    /// Reserved extension bits set.
    case reservedExtensionBits
    /// OFFSET set without HOUR.
    case offsetWithoutHour
    /// WIDE set with no year field.
    case wideWithoutYear
    /// A present field is out of range (month 13, February 30, offset
    /// beyond ±23:59, fraction above its bound, …).
    case invalidComponent
    /// The empty input — not even a null timestamp.
    case empty
}

extension MMVPTS {
    private static let yearBit: UInt8 = 0x01
    private static let monthBit: UInt8 = 0x02
    private static let dayBit: UInt8 = 0x04
    private static let hourBit: UInt8 = 0x08
    private static let minuteBit: UInt8 = 0x10
    private static let secondBit: UInt8 = 0x20
    private static let fractionBit: UInt8 = 0x40
    private static let extBit: UInt8 = 0x80
    private static let offsetExtBit: UInt8 = 0x01
    private static let wideExtBit: UInt8 = 0x02

    /// The one-byte encoding of the null timestamp (header `0x00`).
    public static let nullEncoding: [UInt8] = [0x00]

    /// Whether this value needs the WIDE forms: a year outside the narrow
    /// biased-uint16 range, or an attosecond fraction.
    private var isWide: Bool {
        if let year, !(-32768...32767).contains(year) { return true }
        if case .attoseconds = self.fraction { return true }
        return false
    }

    /// The canonical encoding. Total size 3...25 bytes; see spec §6.
    public func encoded() -> [UInt8] {
        var mask: UInt8 = 0
        if self.year != nil { mask |= Self.yearBit }
        if self.month != nil { mask |= Self.monthBit }
        if self.day != nil { mask |= Self.dayBit }
        if self.hour != nil { mask |= Self.hourBit }
        if self.minute != nil { mask |= Self.minuteBit }
        if self.second != nil { mask |= Self.secondBit }

        var extensionByte: UInt8 = 0
        if self.offsetMinutes != nil { extensionByte |= Self.offsetExtBit }
        let wide = self.isWide
        if wide { extensionByte |= Self.wideExtBit }

        var header = mask
        if self.fraction != nil { header |= Self.fractionBit }
        if extensionByte != 0 { header |= Self.extBit }

        var bytes: [UInt8] = [header]
        if extensionByte != 0 { bytes.append(extensionByte) }
        if let year {
            if wide {
                // Bias by 2⁶³ — the sign-bit flip of the two's-complement form.
                let biased = UInt64(bitPattern: year) ^ 0x8000_0000_0000_0000
                Self.appendBigEndian(biased, count: 8, into: &bytes)
            } else {
                let biased = UInt16(Int(year) + 32768)
                Self.appendBigEndian(UInt64(biased), count: 2, into: &bytes)
            }
        }
        if let month { bytes.append(UInt8(month)) }
        if let day { bytes.append(UInt8(day)) }
        if let hour { bytes.append(UInt8(hour)) }
        if let minute { bytes.append(UInt8(minute)) }
        if let second { bytes.append(UInt8(second)) }
        switch self.fraction {
            case .nanoseconds(let value):
                if wide {
                    // The year forced WIDE: the fraction rides wide too,
                    // scaled to attoseconds (1 ns = 10⁹ as — exact).
                    Self.appendBigEndian(
                        UInt64(value) * 1_000_000_000, count: 8, into: &bytes)
                } else {
                    Self.appendBigEndian(UInt64(value), count: 4, into: &bytes)
                }
            case .attoseconds(let value):
                Self.appendBigEndian(value, count: 8, into: &bytes)
            case nil:
                break
        }
        if let offsetMinutes {
            let raw = UInt16(bitPattern: Int16(offsetMinutes))
            Self.appendBigEndian(UInt64(raw), count: 2, into: &bytes)
        }
        return bytes
    }

    /// Decodes one complete VPTS value; `.success(nil)` is the null
    /// timestamp. Rejects everything §3 rejects, including trailing bytes —
    /// the header fully determines the length, so VPTS self-delimits inside
    /// any framing.
    public static func decode(
        _ bytes: some Collection<UInt8>
    ) -> Result<MMVPTS?, MMVPTSDecodeFailure> {
        var reader = Array(bytes)[...]
        guard let header = reader.popFirst() else { return .failure(.empty) }
        if header == 0 {
            return reader.isEmpty ? .success(nil) : .failure(.trailingBytes)
        }

        let mask = header & 0x3F
        guard mask & (mask &+ 1) == 0 else { return .failure(.nonContiguousMask) }
        if header & Self.fractionBit != 0 && mask & Self.secondBit == 0 {
            return .failure(.fractionWithoutSecond)
        }

        var extensionByte: UInt8 = 0
        if header & Self.extBit != 0 {
            guard let value = reader.popFirst() else { return .failure(.truncated) }
            guard value != 0 else { return .failure(.emptyExtension) }
            guard value & 0xFC == 0 else { return .failure(.reservedExtensionBits) }
            extensionByte = value
        }
        if extensionByte & Self.offsetExtBit != 0 && mask & Self.hourBit == 0 {
            return .failure(.offsetWithoutHour)
        }
        let wide = extensionByte & Self.wideExtBit != 0
        if wide && mask == 0 { return .failure(.wideWithoutYear) }

        var year: Int64?
        if mask & Self.yearBit != 0 {
            if wide {
                guard let biased = Self.readBigEndian(&reader, count: 8) else {
                    return .failure(.truncated)
                }
                year = Int64(bitPattern: biased ^ 0x8000_0000_0000_0000)
            } else {
                guard let biased = Self.readBigEndian(&reader, count: 2) else {
                    return .failure(.truncated)
                }
                year = Int64(biased) - 32768
            }
        }
        func byteField(_ bit: UInt8) -> Result<Int?, MMVPTSDecodeFailure> {
            guard mask & bit != 0 else { return .success(nil) }
            guard let value = reader.popFirst() else { return .failure(.truncated) }
            return .success(Int(value))
        }
        return byteField(Self.monthBit).flatMap { month in
            byteField(Self.dayBit).flatMap { day in
                byteField(Self.hourBit).flatMap { hour in
                    byteField(Self.minuteBit).flatMap { minute in
                        byteField(Self.secondBit).flatMap { second in
                            var fraction: Fraction?
                            if header & Self.fractionBit != 0 {
                                if wide {
                                    guard let value = Self.readBigEndian(&reader, count: 8)
                                    else { return .failure(.truncated) }
                                    fraction = .attoseconds(value)
                                } else {
                                    guard let value = Self.readBigEndian(&reader, count: 4)
                                    else { return .failure(.truncated) }
                                    fraction = .nanoseconds(UInt32(value))
                                }
                            }
                            var offsetMinutes: Int?
                            if extensionByte & Self.offsetExtBit != 0 {
                                guard let raw = Self.readBigEndian(&reader, count: 2)
                                else { return .failure(.truncated) }
                                offsetMinutes = Int(Int16(bitPattern: UInt16(raw)))
                            }
                            guard reader.isEmpty else { return .failure(.trailingBytes) }
                            guard
                                let value = MMVPTS(
                                    year: year, month: month, day: day, hour: hour,
                                    minute: minute, second: second, fraction: fraction,
                                    offsetMinutes: offsetMinutes)
                            else {
                                return .failure(.invalidComponent)
                            }
                            return .success(value)
                        }
                    }
                }
            }
        }
    }

    private static func appendBigEndian(_ value: UInt64, count: Int, into bytes: inout [UInt8]) {
        for shift in stride(from: (count - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    private static func readBigEndian(
        _ reader: inout ArraySlice<UInt8>, count: Int
    ) -> UInt64? {
        guard reader.count >= count else { return nil }
        var value: UInt64 = 0
        for _ in 0..<count {
            value = value << 8 | UInt64(reader.popFirst()!)
        }
        return value
    }
}

// MARK: - Mapping to the fixed-precision kinds

extension MMVPTS {
    /// A full calendar date (`2026-07-22`) as a VPTS value — mask `0x07`.
    public init(_ date: MMDate) {
        self.init(year: Int64(date.year), month: date.month, day: date.day)!
    }

    /// A wall-clock datetime as a VPTS value — mask `0x3F`, the fraction
    /// present only for a non-zero nanosecond (matching the canonical ISO
    /// emission: precision is declared, never padded).
    public init(_ dateTime: MMDateTime) {
        self.init(
            year: Int64(dateTime.date.year),
            month: dateTime.date.month,
            day: dateTime.date.day,
            hour: dateTime.hour,
            minute: dateTime.minute,
            second: dateTime.second,
            fraction: dateTime.nanosecond == 0
                ? nil : .nanoseconds(UInt32(dateTime.nanosecond))
        )!
    }

    /// An absolute instant as a VPTS value — a datetime plus OFFSET.
    public init(_ timestamp: MMTimestamp) {
        var value = MMVPTS(timestamp.dateTime)
        value.offsetMinutes = timestamp.offsetMinutes
        self = value
    }

    /// The value as a calendar date — nil unless the precision is exactly
    /// a date (no time fields, no offset).
    public var dateValue: MMDate? {
        guard
            let year, let month, let day,
            self.hour == nil, self.offsetMinutes == nil, (0...9999).contains(year)
        else {
            return nil
        }
        return MMDate(year: Int(year), month: month, day: day)
    }

    /// The value as a wall-clock datetime — nil unless the precision runs
    /// exactly through seconds (fraction optional, nanosecond-representable)
    /// with no offset.
    public var dateTimeValue: MMDateTime? {
        guard self.offsetMinutes == nil else { return nil }
        return self.wallClock
    }

    /// The value as an absolute instant — nil unless it is a full datetime
    /// **with** an offset.
    public var timestampValue: MMTimestamp? {
        guard let offsetMinutes, let wallClock = self.wallClock else { return nil }
        return MMTimestamp(dateTime: wallClock, offsetMinutes: offsetMinutes)
    }

    private var wallClock: MMDateTime? {
        guard
            let year, let month, let day, let hour, let minute, let second,
            (0...9999).contains(year),
            let date = MMDate(year: Int(year), month: month, day: day)
        else {
            return nil
        }
        let nanosecond: Int
        switch self.fraction {
            case .nanoseconds(let value):
                nanosecond = Int(value)
            case .attoseconds(let value):
                // Only nanosecond-representable fractions map onto the
                // fixed kinds; finer precision has no MMDateTime form.
                guard value % 1_000_000_000 == 0 else { return nil }
                nanosecond = Int(value / 1_000_000_000)
            case nil:
                nanosecond = 0
        }
        return MMDateTime(
            date: date, hour: hour, minute: minute, second: second, nanosecond: nanosecond)
    }
}

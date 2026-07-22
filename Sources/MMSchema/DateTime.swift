/// The wire's calendar and clock values — three distinct semantic kinds,
/// deliberately separate types because they answer different questions:
///
/// - ``MMDate`` — a calendar date (`2026-07-21`). Not an instant: a birthday
///   has no time zone.
/// - ``MMDateTime`` — a wall-clock reading (`2026-07-21T14:30:00`), **no**
///   zone or offset. Not an instant either: "the meeting is at 09:00" means
///   09:00 wherever the calendar lives.
/// - ``MMTimestamp`` — a datetime **with a UTC offset**
///   (`2026-07-21T14:30:00+02:00`, `Z` for UTC): an absolute instant.
///
/// On the wire all three are MessagePack strings in canonical ISO 8601 /
/// RFC 3339 form (grammar in the wire specification, section 6.4); the
/// schema tags them `.date` / `.datetime` / `.timestamp`, so peers and
/// tooling know the semantics — a CLI can localize them, a diff knows a
/// date is not a string.
///
/// Everything here is dependency-free by MMSchema's house rule (no
/// Foundation): parsing, formatting, and the civil-calendar math are
/// implemented in place, which also keeps behavior identical on every
/// platform — no ICU variance. Parsing is strict: canonical grammar only,
/// with the two RFC-sanctioned liberties (lowercase `t`/`z`, and
/// `±00:00` accepted as an alias of `Z`).
public enum MMDateTimeParseFailure: Error, Sendable, Hashable {
    /// The text does not match the kind's grammar at this position.
    case malformedText
    /// Fields parsed but name an impossible calendar value (month 13,
    /// February 30, hour 24, offset beyond ±18:00, …).
    case invalidComponent
}

// MARK: - MMDate

/// A calendar date: `YYYY-MM-DD`, proleptic Gregorian, year 0...9999.
/// See the overview above for how it differs from the other two kinds.
public struct MMDate: Sendable, Hashable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int

    /// Validating: nil for anything the calendar rejects (month 13,
    /// February 30, year outside 0...9999 — the four-digit wire form).
    public init?(year: Int, month: Int, day: Int) {
        guard
            (0...9999).contains(year),
            (1...12).contains(month),
            (1...Self.daysIn(month: month, year: year)).contains(day)
        else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: MMDate, rhs: MMDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Days in `month` of `year` (proleptic Gregorian leap rule).
    public static func daysIn(month: Int, year: Int) -> Int {
        switch month {
            case 1, 3, 5, 7, 8, 10, 12: return 31
            case 4, 6, 9, 11: return 30
            case 2: return Self.isLeapYear(year) ? 29 : 28
            default: return 0
        }
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    /// Days since 1970-01-01 (negative before it) — the civil-from-days
    /// algorithm, used for instant ordering of ``MMTimestamp``.
    public var daysSinceEpoch: Int {
        let year = self.month <= 2 ? self.year - 1 : self.year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (self.month + (self.month > 2 ? -3 : 9)) + 2) / 5 + self.day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

// MARK: - MMDateTime

/// A wall-clock datetime with no zone or offset:
/// `YYYY-MM-DDTHH:MM:SS[.fraction]`. Seconds are always present in the
/// canonical form; the fraction (up to nanoseconds) appears only when
/// non-zero, trailing zeros trimmed. Second 60 is accepted on parse (leap
/// seconds are valid RFC 3339) and preserved.
public struct MMDateTime: Sendable, Hashable, Comparable {
    public var date: MMDate
    public var hour: Int
    public var minute: Int
    public var second: Int
    public var nanosecond: Int

    /// Validating: nil for hour 24, minute 61, nanoseconds outside
    /// 0..<1_000_000_000, and so on. Second 60 is allowed (leap second).
    public init?(
        date: MMDate, hour: Int, minute: Int, second: Int, nanosecond: Int = 0
    ) {
        guard
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...60).contains(second),
            (0..<1_000_000_000).contains(nanosecond)
        else {
            return nil
        }
        self.date = date
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond
    }

    public static func < (lhs: MMDateTime, rhs: MMDateTime) -> Bool {
        (lhs.date, lhs.hour, lhs.minute, lhs.second, lhs.nanosecond)
            < (rhs.date, rhs.hour, rhs.minute, rhs.second, rhs.nanosecond)
    }

    /// Seconds since 1970-01-01T00:00:00 reading this wall clock as if it
    /// were UTC — the instant math for ``MMTimestamp`` applies the offset.
    var secondsSinceEpochAsUTC: Int {
        self.date.daysSinceEpoch * 86_400 + self.hour * 3_600 + self.minute * 60 + self.second
    }
}

// MARK: - MMTimestamp

/// An absolute instant: a datetime plus a UTC offset,
/// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`. Canonical emission uses `Z`
/// for offset zero; `±00:00` parses as `Z`.
///
/// Equality and hashing are **component-wise** (`14:00+02:00` ≠ `12:00Z` —
/// they render differently and round-trip differently); ordering is by
/// **instant first, offset second** — two renderings of the same instant
/// still order deterministically (the westward offset first), keeping
/// `Comparable` a total order consistent with component equality. Compare
/// ``secondsSinceEpoch`` directly when only the instant matters.
public struct MMTimestamp: Sendable, Hashable, Comparable {
    public var dateTime: MMDateTime
    /// Minutes east of UTC, in ±18:00 (RFC 3339 offsets are whole minutes).
    public var offsetMinutes: Int

    /// Validating: nil when the offset is outside ±18:00.
    public init?(dateTime: MMDateTime, offsetMinutes: Int) {
        guard (-1080...1080).contains(offsetMinutes) else { return nil }
        self.dateTime = dateTime
        self.offsetMinutes = offsetMinutes
    }

    /// The instant as (seconds, nanoseconds) since the Unix epoch.
    public var secondsSinceEpoch: (seconds: Int, nanoseconds: Int) {
        (
            self.dateTime.secondsSinceEpochAsUTC - self.offsetMinutes * 60,
            self.dateTime.nanosecond
        )
    }

    public static func < (lhs: MMTimestamp, rhs: MMTimestamp) -> Bool {
        let left = lhs.secondsSinceEpoch
        let right = rhs.secondsSinceEpoch
        if left != right { return left < right }
        return lhs.offsetMinutes < rhs.offsetMinutes
    }
}

// MARK: - Parsing

/// A strict fixed-grammar scanner over UTF-8 bytes. Positions never rewind;
/// every helper either consumes exactly what the grammar demands or reports
/// `.malformedText`.
fileprivate struct ISO8601Scanner {
    let bytes: [UInt8]
    var index = 0

    init(_ text: some StringProtocol) {
        self.bytes = Array(text.utf8)
    }

    var isAtEnd: Bool { self.index == self.bytes.count }

    mutating func fixedDigits(_ count: Int) -> Int? {
        guard self.index + count <= self.bytes.count else { return nil }
        var value = 0
        for _ in 0..<count {
            let byte = self.bytes[self.index]
            guard (0x30...0x39).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 0x30)
            self.index += 1
        }
        return value
    }

    mutating func consume(_ ascii: UInt8) -> Bool {
        guard self.index < self.bytes.count, self.bytes[self.index] == ascii else {
            return false
        }
        self.index += 1
        return true
    }

    mutating func consumeCaseInsensitive(_ upper: UInt8) -> Bool {
        guard self.index < self.bytes.count else { return false }
        let byte = self.bytes[self.index]
        guard byte == upper || byte == upper + 0x20 else { return false }
        self.index += 1
        return true
    }

    func peek() -> UInt8? {
        self.index < self.bytes.count ? self.bytes[self.index] : nil
    }

    /// `.fraction` — 1...9 digits after a dot, scaled to nanoseconds.
    /// Returns 0 when no dot follows (the fraction is optional).
    mutating func fractionNanoseconds() -> Int? {
        guard self.peek() == UInt8(ascii: ".") else { return 0 }
        self.index += 1
        var digits = 0
        var value = 0
        while let byte = self.peek(), (0x30...0x39).contains(byte) {
            if digits == 9 { return nil }
            value = value * 10 + Int(byte - 0x30)
            digits += 1
            self.index += 1
        }
        guard digits > 0 else { return nil }
        for _ in digits..<9 { value *= 10 }
        return value
    }
}

extension MMDate {
    /// Parses the canonical form, `YYYY-MM-DD`. The typed twin of
    /// `EntityName.parse`: grammar violations are `.malformedText`,
    /// impossible calendar values `.invalidComponent`.
    public static func parse(_ text: some StringProtocol) -> Result<MMDate, MMDateTimeParseFailure> {
        var scanner = ISO8601Scanner(text)
        return Self.scan(&scanner).flatMap { date in
            scanner.isAtEnd ? .success(date) : .failure(.malformedText)
        }
    }

    fileprivate static func scan(_ scanner: inout ISO8601Scanner) -> Result<MMDate, MMDateTimeParseFailure> {
        guard
            let year = scanner.fixedDigits(4),
            scanner.consume(UInt8(ascii: "-")),
            let month = scanner.fixedDigits(2),
            scanner.consume(UInt8(ascii: "-")),
            let day = scanner.fixedDigits(2)
        else {
            return .failure(.malformedText)
        }
        guard let date = MMDate(year: year, month: month, day: day) else {
            return .failure(.invalidComponent)
        }
        return .success(date)
    }
}

extension MMDateTime {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction]` (lowercase `t` accepted;
    /// canonical emission uppercases).
    public static func parse(
        _ text: some StringProtocol
    ) -> Result<MMDateTime, MMDateTimeParseFailure> {
        var scanner = ISO8601Scanner(text)
        return Self.scan(&scanner).flatMap { value in
            scanner.isAtEnd ? .success(value) : .failure(.malformedText)
        }
    }

    fileprivate static func scan(
        _ scanner: inout ISO8601Scanner
    ) -> Result<MMDateTime, MMDateTimeParseFailure> {
        MMDate.scan(&scanner).flatMap { date in
            guard
                scanner.consumeCaseInsensitive(UInt8(ascii: "T")),
                let hour = scanner.fixedDigits(2),
                scanner.consume(UInt8(ascii: ":")),
                let minute = scanner.fixedDigits(2),
                scanner.consume(UInt8(ascii: ":")),
                let second = scanner.fixedDigits(2),
                let nanosecond = scanner.fractionNanoseconds()
            else {
                return .failure(.malformedText)
            }
            guard
                let value = MMDateTime(
                    date: date, hour: hour, minute: minute, second: second,
                    nanosecond: nanosecond)
            else {
                return .failure(.invalidComponent)
            }
            return .success(value)
        }
    }
}

extension MMTimestamp {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` (lowercase `t`/`z`
    /// accepted; `±00:00` is an alias of `Z`).
    public static func parse(
        _ text: some StringProtocol
    ) -> Result<MMTimestamp, MMDateTimeParseFailure> {
        var scanner = ISO8601Scanner(text)
        return MMDateTime.scan(&scanner).flatMap { dateTime in
            let offsetMinutes: Int
            if scanner.consumeCaseInsensitive(UInt8(ascii: "Z")) {
                offsetMinutes = 0
            } else {
                let negative: Bool
                if scanner.consume(UInt8(ascii: "+")) {
                    negative = false
                } else if scanner.consume(UInt8(ascii: "-")) {
                    negative = true
                } else {
                    return .failure(.malformedText)
                }
                guard
                    let hours = scanner.fixedDigits(2),
                    scanner.consume(UInt8(ascii: ":")),
                    let minutes = scanner.fixedDigits(2)
                else {
                    return .failure(.malformedText)
                }
                guard minutes < 60 else { return .failure(.invalidComponent) }
                let magnitude = hours * 60 + minutes
                offsetMinutes = negative ? -magnitude : magnitude
            }
            guard scanner.isAtEnd else { return .failure(.malformedText) }
            guard let value = MMTimestamp(dateTime: dateTime, offsetMinutes: offsetMinutes)
            else {
                return .failure(.invalidComponent)
            }
            return .success(value)
        }
    }
}

// MARK: - Canonical rendering

private func padded(_ value: Int, _ width: Int) -> String {
    let text = String(value)
    return text.count >= width
        ? text
        : String(repeating: "0", count: width - text.count) + text
}

/// The shortest fraction rendering: nanoseconds with trailing zeros
/// trimmed, or empty for zero.
private func fractionText(nanoseconds: Int) -> String {
    guard nanoseconds != 0 else { return "" }
    var digits = padded(nanoseconds, 9)
    while digits.hasSuffix("0") {
        digits.removeLast()
    }
    return "." + digits
}

extension MMDate: CustomStringConvertible, LosslessStringConvertible {
    public var description: String {
        "\(padded(self.year, 4))-\(padded(self.month, 2))-\(padded(self.day, 2))"
    }

    public init?(_ description: String) {
        guard case .success(let value) = Self.parse(description) else { return nil }
        self = value
    }
}

extension MMDateTime: CustomStringConvertible, LosslessStringConvertible {
    public var description: String {
        self.date.description
            + "T\(padded(self.hour, 2)):\(padded(self.minute, 2)):\(padded(self.second, 2))"
            + fractionText(nanoseconds: self.nanosecond)
    }

    public init?(_ description: String) {
        guard case .success(let value) = Self.parse(description) else { return nil }
        self = value
    }
}

extension MMTimestamp: CustomStringConvertible, LosslessStringConvertible {
    public var description: String {
        let offset: String
        if self.offsetMinutes == 0 {
            offset = "Z"
        } else {
            let magnitude = abs(self.offsetMinutes)
            offset =
                (self.offsetMinutes < 0 ? "-" : "+")
                + "\(padded(magnitude / 60, 2)):\(padded(magnitude % 60, 2))"
        }
        return self.dateTime.description + offset
    }

    public init?(_ description: String) {
        guard case .success(let value) = Self.parse(description) else { return nil }
        self = value
    }
}

// MARK: - Codable (ISO strings on the wire)

private func decodeISO<Value>(
    _ decoder: any Decoder,
    kind: String,
    parse: (String) -> Result<Value, MMDateTimeParseFailure>
) throws -> Value {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    switch parse(text) {
        case .success(let value):
            return value
        case .failure(let failure):
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "'\(text)' is not a canonical \(kind) (\(failure))"
            )
    }
}

extension MMDate: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }

    public init(from decoder: any Decoder) throws {
        self = try decodeISO(decoder, kind: "date (YYYY-MM-DD)", parse: Self.parse)
    }
}

extension MMDateTime: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }

    public init(from decoder: any Decoder) throws {
        self = try decodeISO(
            decoder, kind: "datetime (YYYY-MM-DDTHH:MM:SS[.fff])", parse: Self.parse)
    }
}

extension MMTimestamp: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }

    public init(from decoder: any Decoder) throws {
        self = try decodeISO(
            decoder, kind: "timestamp (YYYY-MM-DDTHH:MM:SS[.fff]Z|±HH:MM)", parse: Self.parse)
    }
}

// MARK: - Schema classification

extension MMDate: SchemaDescribable {
    public static var schema: TypeSchema { .date }
}

extension MMDateTime: SchemaDescribable {
    public static var schema: TypeSchema { .datetime }
}

extension MMTimestamp: SchemaDescribable {
    public static var schema: TypeSchema { .timestamp }
}

// The probe walks containing decoders with placeholder instances; these
// types' decoders reject the probe's empty string, so they provide the
// epoch as their trivial instance.
extension MMDate: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any {
        MMDate(year: 1970, month: 1, day: 1)!
    }
}

extension MMDateTime: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any {
        MMDateTime(
            date: MMDate(year: 1970, month: 1, day: 1)!, hour: 0, minute: 0, second: 0)!
    }
}

extension MMTimestamp: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any {
        MMTimestamp(
            dateTime: MMDateTime(
                date: MMDate(year: 1970, month: 1, day: 1)!, hour: 0, minute: 0, second: 0)!,
            offsetMinutes: 0
        )!
    }
}

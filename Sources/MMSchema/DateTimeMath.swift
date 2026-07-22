/// Calendar and clock arithmetic for the wire time kinds:
///
/// ```swift
/// date + .day(2)                       // civil-day arithmetic
/// date + .month(1)                     // Jan 31 + 1 month = Feb 28/29 (clamped)
/// dateTime + .hour(30) - .minute(5)    // carries across days
/// dateTime + .seconds(90)              // Duration — exact elapsed time
/// timestamp - other                    // Duration between instants
/// ```
///
/// Two kinds of arithmetic, deliberately distinct:
///
/// - ``MMDateComponent`` math is **calendar** math: adding a month lands on
///   the same day of the next month (clamped to its length), adding a day
///   crosses month and year boundaries civilly. On ``MMTimestamp`` it
///   operates on the wall clock and keeps the offset — "same time next
///   Tuesday" semantics.
/// - `Duration` math is **elapsed-time** math, exact to the nanosecond.
///   With no time zones in these types (offsets are fixed), wall-clock and
///   instant shifting agree; sub-nanosecond duration precision truncates.
///
/// Operators trap on results outside the wire range (year 0...9999) — the
/// same contract as integer overflow; use the `adding(_:)` methods for a
/// nil-returning form. Arithmetic normalizes a leap second (`:60` folds
/// into the next minute) — leap seconds survive parsing and re-rendering,
/// not math.
public enum MMDateComponent: Sendable, Hashable {
    case year(Int)
    case month(Int)
    case day(Int)
    case hour(Int)
    case minute(Int)
    case second(Int)
    case nanosecond(Int)

    var negated: MMDateComponent {
        switch self {
            case .year(let count): return .year(-count)
            case .month(let count): return .month(-count)
            case .day(let count): return .day(-count)
            case .hour(let count): return .hour(-count)
            case .minute(let count): return .minute(-count)
            case .second(let count): return .second(-count)
            case .nanosecond(let count): return .nanosecond(-count)
        }
    }
}

private func floorDivide(_ value: Int, _ divisor: Int) -> Int {
    let quotient = value / divisor
    return (value % divisor < 0) ? quotient - 1 : quotient
}

// MARK: - MMDate

extension MMDate {
    /// The inverse of ``daysSinceEpoch`` (the civil-from-days algorithm);
    /// nil outside the wire range (year 0...9999).
    public static func date(daysSinceEpoch: Int) -> MMDate? {
        let z = daysSinceEpoch + 719_468
        let era = floorDivide(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return MMDate(year: year, month: month, day: day)
    }

    /// Calendar addition; nil when the result leaves the wire range.
    /// Month/year addition clamps the day to the target month's length
    /// (Jan 31 + 1 month = Feb 28/29). Time components are a programmer
    /// error on a calendar date.
    public func adding(_ component: MMDateComponent) -> MMDate? {
        switch component {
            case .year(let count):
                return self.adding(.month(count * 12))
            case .month(let count):
                let total = self.year * 12 + (self.month - 1) + count
                let year = floorDivide(total, 12)
                let month = total - year * 12 + 1
                guard (0...9999).contains(year) else { return nil }
                let day = min(self.day, MMDate.daysIn(month: month, year: year))
                return MMDate(year: year, month: month, day: day)
            case .day(let count):
                return MMDate.date(daysSinceEpoch: self.daysSinceEpoch + count)
            case .hour, .minute, .second, .nanosecond:
                preconditionFailure(
                    "MMDate has no time: adding \(component) to a calendar date is a programmer error"
                )
        }
    }

    public static func + (date: MMDate, component: MMDateComponent) -> MMDate {
        guard let result = date.adding(component) else {
            preconditionFailure("MMDate + \(component) leaves the wire range (year 0...9999)")
        }
        return result
    }

    public static func - (date: MMDate, component: MMDateComponent) -> MMDate {
        date + component.negated
    }

    /// The number of civil days from `rhs` to `lhs` (positive when `lhs`
    /// is later).
    public static func - (lhs: MMDate, rhs: MMDate) -> Int {
        lhs.daysSinceEpoch - rhs.daysSinceEpoch
    }
}

/// Striding in civil days: `startDate..<endDate` is a countable range of
/// dates, and `stride(from:to:by:)` walks weeks or any other day step.
/// `advanced(by:)` traps outside the wire range (year 0...9999), the same
/// contract as `+ .day(n)`. Only ``MMDate`` strides — the natural stride of
/// the clock-bearing kinds is `Duration`, which `Strideable` cannot carry.
extension MMDate: Strideable {
    public func distance(to other: MMDate) -> Int {
        other - self
    }

    public func advanced(by days: Int) -> MMDate {
        self + .day(days)
    }
}

// MARK: - MMDateTime

extension MMDateTime {
    /// Shifts by exact elapsed time, carrying across minutes, hours, and
    /// days; nil when the result leaves the wire range. Normalizes a leap
    /// second.
    func shifted(seconds: Int, nanoseconds: Int) -> MMDateTime? {
        let totalNanoseconds = self.nanosecond + nanoseconds
        let nanosecondCarry = floorDivide(totalNanoseconds, 1_000_000_000)
        let nanosecond = totalNanoseconds - nanosecondCarry * 1_000_000_000
        let totalSeconds = self.secondsSinceEpochAsUTC + seconds + nanosecondCarry
        let days = floorDivide(totalSeconds, 86_400)
        let secondOfDay = totalSeconds - days * 86_400
        guard let date = MMDate.date(daysSinceEpoch: days) else { return nil }
        return MMDateTime(
            date: date,
            hour: secondOfDay / 3600,
            minute: secondOfDay % 3600 / 60,
            second: secondOfDay % 60,
            nanosecond: nanosecond
        )
    }

    /// Calendar addition: date components move the calendar date (day
    /// clamping and all, time preserved); time components are exact shifts
    /// that carry across days. Nil when the result leaves the wire range.
    public func adding(_ component: MMDateComponent) -> MMDateTime? {
        switch component {
            case .year, .month, .day:
                guard let date = self.date.adding(component) else { return nil }
                return MMDateTime(
                    date: date, hour: self.hour, minute: self.minute,
                    second: min(self.second, 59), nanosecond: self.nanosecond)
            case .hour(let count):
                return self.shifted(seconds: count * 3600, nanoseconds: 0)
            case .minute(let count):
                return self.shifted(seconds: count * 60, nanoseconds: 0)
            case .second(let count):
                return self.shifted(seconds: count, nanoseconds: 0)
            case .nanosecond(let count):
                return self.shifted(seconds: 0, nanoseconds: count)
        }
    }

    public static func + (dateTime: MMDateTime, component: MMDateComponent) -> MMDateTime {
        guard let result = dateTime.adding(component) else {
            preconditionFailure(
                "MMDateTime + \(component) leaves the wire range (year 0...9999)")
        }
        return result
    }

    public static func - (dateTime: MMDateTime, component: MMDateComponent) -> MMDateTime {
        dateTime + component.negated
    }

    public static func + (dateTime: MMDateTime, duration: Duration) -> MMDateTime {
        let (seconds, attoseconds) = duration.components
        guard
            let result = dateTime.shifted(
                seconds: Int(seconds), nanoseconds: Int(attoseconds / 1_000_000_000))
        else {
            preconditionFailure("MMDateTime + Duration leaves the wire range (year 0...9999)")
        }
        return result
    }

    public static func - (dateTime: MMDateTime, duration: Duration) -> MMDateTime {
        dateTime + (Duration.zero - duration)
    }

    /// The exact elapsed time from `rhs` to `lhs`, read on the same wall
    /// clock (positive when `lhs` is later).
    public static func - (lhs: MMDateTime, rhs: MMDateTime) -> Duration {
        .seconds(lhs.secondsSinceEpochAsUTC - rhs.secondsSinceEpochAsUTC)
            + .nanoseconds(lhs.nanosecond - rhs.nanosecond)
    }
}

// MARK: - MMTimestamp

extension MMTimestamp {
    /// Calendar addition on the **wall clock**, offset preserved — "same
    /// time next Tuesday" semantics. Nil when the result leaves the wire
    /// range.
    public func adding(_ component: MMDateComponent) -> MMTimestamp? {
        guard let dateTime = self.dateTime.adding(component) else { return nil }
        return MMTimestamp(dateTime: dateTime, offsetMinutes: self.offsetMinutes)
    }

    public static func + (timestamp: MMTimestamp, component: MMDateComponent) -> MMTimestamp {
        guard let result = timestamp.adding(component) else {
            preconditionFailure(
                "MMTimestamp + \(component) leaves the wire range (year 0...9999)")
        }
        return result
    }

    public static func - (timestamp: MMTimestamp, component: MMDateComponent) -> MMTimestamp {
        timestamp + component.negated
    }

    /// Exact elapsed time. With a fixed offset, shifting the wall clock IS
    /// shifting the instant, so the offset is preserved.
    public static func + (timestamp: MMTimestamp, duration: Duration) -> MMTimestamp {
        MMTimestamp(
            dateTime: timestamp.dateTime + duration,
            offsetMinutes: timestamp.offsetMinutes
        )!
    }

    public static func - (timestamp: MMTimestamp, duration: Duration) -> MMTimestamp {
        timestamp + (Duration.zero - duration)
    }

    /// The exact elapsed time between two **instants** (positive when `lhs`
    /// is later) — offsets are applied, so `14:00+02:00 - 12:00Z` is zero.
    public static func - (lhs: MMTimestamp, rhs: MMTimestamp) -> Duration {
        let left = lhs.secondsSinceEpoch
        let right = rhs.secondsSinceEpoch
        return .seconds(left.seconds - right.seconds)
            + .nanoseconds(left.nanoseconds - right.nanoseconds)
    }
}

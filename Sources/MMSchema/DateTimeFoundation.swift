// The one deliberate exception to MMSchema's no-imports rule, and it is
// conditionally compiled: `DateComponents` interop exists only where
// Foundation does. Nothing else in the module touches Foundation — the wire
// types, parsing, formatting, and arithmetic stay dependency-free and
// ICU-free.
#if canImport(Foundation)
import Foundation

extension MMDate {
    /// The value as `DateComponents` (year, month, day).
    public var dateComponents: DateComponents {
        DateComponents(year: self.year, month: self.month, day: self.day)
    }

    /// Builds from `DateComponents`: nil unless year, month, and day are
    /// all present and form a valid wire-range date. Other fields are
    /// ignored — a calendar date carries no time.
    public init?(_ components: DateComponents) {
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }
}

extension MMDateTime {
    /// The value as `DateComponents` (through nanosecond, no time zone —
    /// a wall clock has none).
    public var dateComponents: DateComponents {
        DateComponents(
            year: self.date.year,
            month: self.date.month,
            day: self.date.day,
            hour: self.hour,
            minute: self.minute,
            second: self.second,
            nanosecond: self.nanosecond
        )
    }

    /// Builds from `DateComponents`: year/month/day required; missing time
    /// fields default to zero (the common shape of partially-filled
    /// components). Nil for out-of-range values. Any `timeZone` is ignored
    /// — a wall clock has none; use ``MMTimestamp`` for zoned components.
    public init?(_ components: DateComponents) {
        guard let date = MMDate(components) else { return nil }
        self.init(
            date: date,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0,
            nanosecond: components.nanosecond ?? 0
        )
    }
}

extension MMTimestamp {
    /// The value as `DateComponents`, `timeZone` carrying the fixed offset.
    public var dateComponents: DateComponents {
        var components = self.dateTime.dateComponents
        components.timeZone = TimeZone(secondsFromGMT: self.offsetMinutes * 60)
        return components
    }

    /// Builds from `DateComponents`: the wall-clock fields as
    /// ``MMDateTime/init(_:)``, plus a required `timeZone` whose GMT offset
    /// must be whole minutes within ±23:59 (the wire's offset grammar).
    /// Components without a zone are a wall clock, not an instant — use
    /// ``MMDateTime`` for those.
    public init?(_ components: DateComponents) {
        guard
            let dateTime = MMDateTime(components),
            let timeZone = components.timeZone
        else {
            return nil
        }
        let offsetSeconds = timeZone.secondsFromGMT()
        guard offsetSeconds % 60 == 0 else { return nil }
        self.init(dateTime: dateTime, offsetMinutes: offsetSeconds / 60)
    }
}

// MARK: - The current moment

/// `Date()` is the wall-clock source here — the one legitimate use: these
/// constructors exist so application code has a sanctioned way to say "now"
/// without the core types growing a clock. Server/client code measuring
/// elapsed time still uses monotonic clocks, never this.
extension MMTimestamp {
    /// The current instant. Defaults to offset zero (`Z`) — the canonical
    /// rendering for machine timestamps; pass a zone for local-time
    /// presentation (`MMTimestamp.now(in: .current)`). Nanosecond field
    /// carries the sub-second reading at the clock's own precision.
    public static func now(in timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> MMTimestamp {
        let date = Date()
        // Time zone offsets are whole minutes in every modern zone; the
        // division cannot lose anything the wire grammar could carry.
        let offsetMinutes = timeZone.secondsFromGMT(for: date) / 60
        let interval = date.timeIntervalSince1970
        var seconds = Int(interval.rounded(.down))
        var nanoseconds = Int(((interval - interval.rounded(.down)) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            seconds += 1
            nanoseconds = 0
        }
        // Force unwraps: the epoch is a valid datetime, "now" plus any legal
        // offset stays inside year 0...9999 for the next several millennia,
        // and the offset is within ±18:00 by TimeZone's own contract.
        let epoch = MMDateTime(
            date: MMDate(year: 1970, month: 1, day: 1)!,
            hour: 0, minute: 0, second: 0
        )!
        let local = epoch.shifted(
            seconds: seconds + offsetMinutes * 60, nanoseconds: nanoseconds)!
        return MMTimestamp(dateTime: local, offsetMinutes: offsetMinutes)!
    }
}

extension MMDateTime {
    /// The current wall-clock reading in a zone (the local calendar and
    /// clock by default). A wall clock carries no offset — use
    /// ``MMTimestamp/now(in:)`` when the instant matters.
    public static func now(in timeZone: TimeZone = .current) -> MMDateTime {
        MMTimestamp.now(in: timeZone).dateTime
    }
}

extension MMDate {
    /// Today's calendar date in a zone (the local calendar by default).
    public static func today(in timeZone: TimeZone = .current) -> MMDate {
        MMTimestamp.now(in: timeZone).dateTime.date
    }
}

extension MMVPTS {
    /// The value as `DateComponents`: present fields map one to one —
    /// variable precision is exactly what `DateComponents` models. A
    /// nanosecond-representable fraction lands in `nanosecond`
    /// (sub-nanosecond precision does not survive the trip); an offset
    /// becomes a fixed-offset `timeZone`.
    public var dateComponents: DateComponents {
        var components = DateComponents()
        components.year = self.year.map(Int.init)
        components.month = self.month
        components.day = self.day
        components.hour = self.hour
        components.minute = self.minute
        components.second = self.second
        switch self.fraction {
            case .nanoseconds(let value):
                components.nanosecond = Int(value)
            case .attoseconds(let value) where value % 1_000_000_000 == 0:
                components.nanosecond = Int(value / 1_000_000_000)
            case .attoseconds, nil:
                break
        }
        if let offsetMinutes = self.offsetMinutes {
            components.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60)
        }
        return components
    }

    /// Builds from `DateComponents`, preserving which fields are present —
    /// nil when the present set violates the VPTS rules (a gap in the
    /// chain, a nanosecond without a second, a zone without an hour, a
    /// zone whose offset is not whole minutes, or any out-of-range field).
    public init?(_ components: DateComponents) {
        var offsetMinutes: Int?
        if let timeZone = components.timeZone {
            let offsetSeconds = timeZone.secondsFromGMT()
            guard offsetSeconds % 60 == 0 else { return nil }
            offsetMinutes = offsetSeconds / 60
        }
        var fraction: Fraction?
        if let nanosecond = components.nanosecond {
            guard (0...999_999_999).contains(nanosecond) else { return nil }
            fraction = .nanoseconds(UInt32(nanosecond))
        }
        self.init(
            year: components.year.map(Int64.init),
            month: components.month,
            day: components.day,
            hour: components.hour,
            minute: components.minute,
            second: components.second,
            fraction: fraction,
            offsetMinutes: offsetMinutes
        )
    }
}
#endif

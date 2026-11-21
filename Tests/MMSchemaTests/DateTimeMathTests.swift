import Foundation
import Testing

@testable import MMSchema

/// Calendar/clock arithmetic and the Foundation interop for the wire time
/// kinds.
@Suite("Date and time arithmetic and interop")
struct DateTimeMathTests {
    private func date(_ text: String) -> MMDate {
        try! MMDate.parse(text).get()
    }

    private func dateTime(_ text: String) -> MMDateTime {
        try! MMDateTime.parse(text).get()
    }

    private func timestamp(_ text: String) -> MMTimestamp {
        try! MMTimestamp.parse(text).get()
    }

    // MARK: - Calendar-component math

    @Test("day arithmetic is civil: it carries across months, years, and leap days")
    func dayArithmetic() {
        #expect(self.date("2026-07-30") + .day(2) == self.date("2026-08-01"))
        #expect(self.date("2026-01-01") - .day(1) == self.date("2025-12-31"))
        #expect(self.date("2024-02-28") + .day(1) == self.date("2024-02-29"))
        #expect(self.date("2025-02-28") + .day(1) == self.date("2025-03-01"))
        #expect(self.date("2026-07-22") + .day(365) == self.date("2027-07-22"))
    }

    @Test("month and year arithmetic clamps to the target month's length")
    func monthClamping() {
        #expect(self.date("2026-01-31") + .month(1) == self.date("2026-02-28"))
        #expect(self.date("2024-01-31") + .month(1) == self.date("2024-02-29"))
        #expect(self.date("2026-08-31") - .month(2) == self.date("2026-06-30"))
        #expect(self.date("2026-11-15") + .month(3) == self.date("2027-02-15"))
        #expect(self.date("2024-02-29") + .year(1) == self.date("2025-02-28"))
    }

    @Test("component math chains and inverts")
    func chaining() {
        let start = self.date("2026-07-22")
        #expect(start + .month(1) + .day(10) - .day(10) - .month(1) == start)
        #expect(self.date("2026-07-31") - self.date("2026-06-30") == 31)
        #expect(self.date("2026-01-01") - self.date("2026-01-02") == -1)
    }

    @Test("time components carry across minutes, hours, and days")
    func timeCarry() {
        #expect(
            self.dateTime("2026-07-22T23:30:00") + .hour(1)
                == self.dateTime("2026-07-23T00:30:00"))
        #expect(
            self.dateTime("2026-12-31T23:59:59") + .second(1)
                == self.dateTime("2027-01-01T00:00:00"))
        #expect(
            self.dateTime("2026-07-22T00:00:00") - .nanosecond(1)
                == self.dateTime("2026-07-21T23:59:59.999999999"))
        // Calendar components on a datetime keep the wall clock.
        #expect(
            self.dateTime("2026-01-31T09:15:00.5") + .month(1)
                == self.dateTime("2026-02-28T09:15:00.5"))
    }

    @Test("timestamp component math is wall-clock math; the offset rides along")
    func timestampCalendarMath() {
        #expect(
            self.timestamp("2026-07-22T23:30:00-04:00") + .hour(1)
                == self.timestamp("2026-07-23T00:30:00-04:00"))
        #expect(
            self.timestamp("2026-01-31T12:00:00+05:30") + .month(1)
                == self.timestamp("2026-02-28T12:00:00+05:30"))
    }

    // MARK: - Strideable

    @Test("dates stride in civil days: ranges iterate, stride() walks weeks")
    func strideable() {
        let july = Array(self.date("2026-07-01")..<self.date("2026-08-01"))
        #expect(july.count == 31)
        #expect(july.first == self.date("2026-07-01"))
        #expect(july.last == self.date("2026-07-31"))
        // A leap February, closed-range form.
        #expect(Array(self.date("2024-02-01")...self.date("2024-02-29")).count == 29)
        let mondays = Array(
            stride(from: self.date("2026-07-06"), to: self.date("2026-08-01"), by: 7))
        #expect(
            mondays == [
                self.date("2026-07-06"), self.date("2026-07-13"),
                self.date("2026-07-20"), self.date("2026-07-27"),
            ])
        #expect(self.date("2026-07-22").distance(to: self.date("2027-07-22")) == 365)
        #expect(self.date("2026-07-22").advanced(by: -22) == self.date("2026-06-30"))
    }

    // MARK: - Duration math

    @Test("Duration math is exact elapsed time, nanoseconds included")
    func durationMath() {
        #expect(
            self.dateTime("2026-07-22T14:30:00") + .seconds(90)
                == self.dateTime("2026-07-22T14:31:30"))
        #expect(
            self.dateTime("2026-07-22T14:30:00.75") + .milliseconds(500)
                == self.dateTime("2026-07-22T14:30:01.25"))
        #expect(
            self.timestamp("2026-07-22T23:59:59Z") + .seconds(2)
                == self.timestamp("2026-07-23T00:00:01Z"))
        #expect(
            self.timestamp("2026-07-22T12:00:00+02:00") - .nanoseconds(1)
                == self.timestamp("2026-07-22T11:59:59.999999999+02:00"))
    }

    @Test("differences: wall-clock for datetimes, instant for timestamps")
    func differences() {
        #expect(
            self.dateTime("2026-07-22T14:31:30") - self.dateTime("2026-07-22T14:30:00")
                == .seconds(90))
        // Same instant, different offsets: zero.
        #expect(
            self.timestamp("2026-07-22T14:00:00+02:00") - self.timestamp("2026-07-22T12:00:00Z")
                == .zero)
        #expect(
            self.timestamp("2026-07-22T12:00:00.5Z") - self.timestamp("2026-07-22T12:00:00Z")
                == .milliseconds(500))
        #expect(
            self.timestamp("2026-07-22T12:00:00Z") - self.timestamp("2026-07-22T12:00:01Z")
                == .seconds(-1))
    }

    @Test("arithmetic normalizes a leap second")
    func leapSecondNormalization() {
        #expect(
            self.dateTime("2026-12-31T23:59:60") + .second(1)
                == self.dateTime("2027-01-01T00:00:01"))
    }

    // MARK: - Now (Foundation-gated)

    @Test("now() is the current instant: UTC by default, zone offsets applied")
    func now() {
        let before = Date().timeIntervalSince1970
        let utcNow = MMTimestamp.now()
        let after = Date().timeIntervalSince1970
        #expect(utcNow.offsetMinutes == 0)
        let (seconds, nanoseconds) = utcNow.secondsSinceEpoch
        let instant = Double(seconds) + Double(nanoseconds) / 1_000_000_000
        #expect(instant >= before - 1 && instant <= after + 1)
        // A zoned now is the same instant read on a shifted wall clock.
        let ahead = MMTimestamp.now(in: TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!)
        #expect(ahead.offsetMinutes == 330)
        #expect(abs((ahead - utcNow).components.seconds) <= 2)
        // The wall-clock and date forms agree with the timestamp's reading.
        let wallClock = MMDateTime.now(in: TimeZone(secondsFromGMT: 0)!)
        #expect(abs(wallClock.secondsSinceEpochAsUTC - seconds) <= 2)
        let today = MMDate.today(in: TimeZone(secondsFromGMT: 0)!)
        #expect(abs(today - utcNow.dateTime.date) <= 1)
    }

    // MARK: - DateComponents interop

    @Test("the fixed kinds round-trip through DateComponents")
    func dateComponentsRoundTrip() {
        let date = self.date("2026-07-22")
        #expect(MMDate(date.dateComponents) == date)
        let dateTime = self.dateTime("2026-07-22T14:30:00.25")
        #expect(MMDateTime(dateTime.dateComponents) == dateTime)
        let timestamp = self.timestamp("2026-07-22T14:30:00.25-09:30")
        #expect(timestamp.dateComponents.timeZone?.secondsFromGMT() == -570 * 60)
        #expect(MMTimestamp(timestamp.dateComponents) == timestamp)
    }

    @Test("partial and invalid DateComponents are handled honestly")
    func dateComponentsEdges() {
        // Missing time fields default to zero for a wall clock...
        #expect(
            MMDateTime(DateComponents(year: 2026, month: 7, day: 22))
                == self.dateTime("2026-07-22T00:00:00"))
        // ...but a missing date is nothing.
        #expect(MMDate(DateComponents(month: 7, day: 22)) == nil)
        #expect(MMDate(DateComponents(year: 2026, month: 2, day: 30)) == nil)
        // A timestamp requires the zone; a wall clock ignores it.
        #expect(MMTimestamp(DateComponents(year: 2026, month: 7, day: 22)) == nil)
    }

    /// Components in `zone`, through the second.
    private func components(
        _ zone: String, _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int = 0, _ second: Int = 0
    ) -> DateComponents {
        DateComponents(
            timeZone: TimeZone(identifier: zone)!,
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
    }

    /// The instant Foundation's Gregorian calendar gives for zoned
    /// components, in seconds since 1970.
    private func calendarSeconds(_ components: DateComponents) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone!
        return calendar.date(from: components).map { Int($0.timeIntervalSince1970) }
    }

    @Test("a zone's offset is the one in force at the components' wall time, not today")
    func dateComponentsZoneOffsetAtTheirDate() {
        // Both halves of the year, both hemispheres, a half-hour zone: the
        // same answer whatever today's date is.
        let cases = [
            (components("America/New_York", 2026, 7, 1, 12), "2026-07-01T12:00:00-04:00"),
            (components("America/New_York", 2026, 1, 15, 12), "2026-01-15T12:00:00-05:00"),
            (components("Australia/Sydney", 2026, 1, 15, 12), "2026-01-15T12:00:00+11:00"),
            (components("Australia/Sydney", 2026, 7, 1, 12), "2026-07-01T12:00:00+10:00"),
            (components("Asia/Kolkata", 2026, 7, 1, 12), "2026-07-01T12:00:00+05:30"),
        ]
        for (components, expected) in cases {
            let timestamp = MMTimestamp(components)
            #expect(timestamp?.description == expected)
            #expect(timestamp?.secondsSinceEpoch.seconds == calendarSeconds(components))
        }
        // New York kept local mean time, −4:56:02, until 1883: no whole
        // minute offset, so no timestamp.
        #expect(MMTimestamp(components("America/New_York", 1800, 1, 1, 12)) == nil)
    }

    @Test("a skipped or repeated wall time takes the offset before the change, as Calendar does")
    func dateComponentsGapsAndFolds() {
        let cases = [
            // New York goes forward at 02:00 on 2026-03-08: 02:00..<03:00
            // is skipped, read with EST.
            (components("America/New_York", 2026, 3, 8, 1, 59, 59), "2026-03-08T01:59:59-05:00"),
            (components("America/New_York", 2026, 3, 8, 2, 30), "2026-03-08T02:30:00-05:00"),
            (components("America/New_York", 2026, 3, 8, 3), "2026-03-08T03:00:00-04:00"),
            // It goes back at 02:00 on 2026-11-01: 01:00..<02:00 shows
            // twice, the earlier in EDT.
            (components("America/New_York", 2026, 11, 1, 0, 59, 59), "2026-11-01T00:59:59-04:00"),
            (components("America/New_York", 2026, 11, 1, 1, 30), "2026-11-01T01:30:00-04:00"),
            (components("America/New_York", 2026, 11, 1, 2), "2026-11-01T02:00:00-05:00"),
            // Lord Howe Island moves its clocks by half an hour.
            (components("Australia/Lord_Howe", 2026, 10, 4, 2, 15), "2026-10-04T02:15:00+10:30"),
            (components("Australia/Lord_Howe", 2026, 4, 5, 1, 45), "2026-04-05T01:45:00+11:00"),
        ]
        for (components, expected) in cases {
            let timestamp = MMTimestamp(components)
            #expect(timestamp?.description == expected)
            #expect(timestamp?.secondsSinceEpoch.seconds == calendarSeconds(components))
        }
    }

    @Test("MMVPTS takes a zone's offset at the wall time its fields name")
    func vptsDateComponentsZoneOffset() {
        // An absent minute and second read as zero.
        let summerHour = MMVPTS(
            DateComponents(
                timeZone: TimeZone(identifier: "America/New_York")!,
                year: 2026, month: 7, day: 1, hour: 12
            )
        )
        #expect(summerHour == MMVPTS(year: 2026, month: 7, day: 1, hour: 12, offsetMinutes: -240))
        // The skipped hour, read with EST.
        let skippedHour = MMVPTS(
            DateComponents(
                timeZone: TimeZone(identifier: "America/New_York")!,
                year: 2026, month: 3, day: 8, hour: 2
            )
        )
        #expect(skippedHour == MMVPTS(year: 2026, month: 3, day: 8, hour: 2, offsetMinutes: -300))
        // Any year holds a fixed zone's offset. `DateComponents` reads
        // Int.max as an absent field, so the top year is one below it.
        for year in [Int.min, -1, 10_000, Int.max - 1] {
            let value = MMVPTS(
                DateComponents(
                    timeZone: TimeZone(secondsFromGMT: 3600)!,
                    year: year, month: 7, day: 1, hour: 12
                )
            )
            #expect(value?.offsetMinutes == 60, "year \(year)")
        }
        // A zone needs an hour.
        #expect(
            MMVPTS(DateComponents(timeZone: TimeZone(secondsFromGMT: 0)!, year: 2026)) == nil)
    }

    @Test("MMVPTS maps DateComponents' optionality one to one")
    func vptsDateComponents() {
        let yearMonth = MMVPTS(year: 2026, month: 7)!
        #expect(yearMonth.dateComponents.year == 2026)
        #expect(yearMonth.dateComponents.month == 7)
        #expect(yearMonth.dateComponents.day == nil)
        #expect(MMVPTS(yearMonth.dateComponents) == yearMonth)
        let full = MMVPTS(self.timestamp("2026-07-22T14:30:00.123456789+02:00"))
        #expect(MMVPTS(full.dateComponents) == full)
        // A gap in the chain is rejected, same as everywhere.
        #expect(MMVPTS(DateComponents(year: 2026, day: 22)) == nil)
    }
}

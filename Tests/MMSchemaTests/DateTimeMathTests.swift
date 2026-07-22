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

import Foundation
import Testing

@testable import MMSchema

/// A macro fixture carrying all three calendar/clock kinds — proves the
/// static subset, the generated property types, and macro fidelity.
private enum Chrono: MethodNamespace {
    #schema("chrono") {
        Call("plan") {
            Access { .write }
            Request {
                Field("day", .date)
                Field("slot", .datetime)
                Field("created", .timestamp)
                Field("remind", .optional(.timestamp))
            }
            Response {
                Field("ok", .bool)
            }
        }
    }
}

@Suite("Calendar and clock wire values")
struct DateTimeTests {
    // MARK: - Parse / render round trips

    @Test(
        "canonical forms round-trip exactly",
        arguments: [
            "2026-07-21",
            "0001-01-01",
            "9999-12-31",
            "2000-02-29",
        ]
    )
    func dateRoundTrip(text: String) throws {
        let parsed = try MMDate.parse(text).get()
        #expect(parsed.description == text)
    }

    @Test(
        "canonical datetimes round-trip exactly",
        arguments: [
            "2026-07-21T14:30:00",
            "2026-07-21T00:00:00.5",
            "2026-07-21T23:59:60",
            "2026-07-21T01:02:03.000000001",
        ]
    )
    func datetimeRoundTrip(text: String) throws {
        let parsed = try MMDateTime.parse(text).get()
        #expect(parsed.description == text)
    }

    @Test(
        "canonical timestamps round-trip exactly",
        arguments: [
            "2026-07-21T14:30:00Z",
            "2026-07-21T14:30:00+02:00",
            "2026-07-21T14:30:00.25-09:30",
            "2026-07-21T14:30:00+18:00",
        ]
    )
    func timestampRoundTrip(text: String) throws {
        let parsed = try MMTimestamp.parse(text).get()
        #expect(parsed.description == text)
    }

    @Test("the sanctioned liberties normalize: lowercase t/z, ±00:00 as Z")
    func liberties() throws {
        #expect(try MMDateTime.parse("2026-07-21t14:30:00").get().description
            == "2026-07-21T14:30:00")
        #expect(try MMTimestamp.parse("2026-07-21t14:30:00z").get().description
            == "2026-07-21T14:30:00Z")
        #expect(try MMTimestamp.parse("2026-07-21T14:30:00+00:00").get().description
            == "2026-07-21T14:30:00Z")
        #expect(try MMTimestamp.parse("2026-07-21T14:30:00-00:00").get().description
            == "2026-07-21T14:30:00Z")
    }

    @Test("fractions parse scaled to nanoseconds and render trimmed")
    func fractionScaling() throws {
        let half = try MMDateTime.parse("2026-01-01T00:00:00.500").get()
        #expect(half.nanosecond == 500_000_000)
        #expect(half.description == "2026-01-01T00:00:00.5")
    }

    @Test(
        "grammar violations are malformedText",
        arguments: [
            "2026-7-01", "2026-07-1", "26-07-01", "2026/07/01", "2026-07-01 ",
            "2026-07-01T14:30", "2026-07-01T14:30:00.", "2026-07-01T14:30:00.1234567890",
        ]
    )
    func malformed(text: String) {
        let asDate = MMDate.parse(text)
        let asDatetime = MMDateTime.parse(text)
        #expect(asDate == .failure(.malformedText) || asDate == .failure(.invalidComponent))
        if case .success = asDatetime {
            Issue.record("'\(text)' must not parse as a datetime")
        }
    }

    @Test(
        "impossible calendar values are invalidComponent",
        arguments: ["2026-02-30", "2026-13-01", "2025-02-29", "2026-00-10", "2026-04-31"]
    )
    func impossibleDates(text: String) {
        #expect(MMDate.parse(text) == .failure(.invalidComponent))
    }

    @Test("impossible clock and offset components are rejected")
    func impossibleClocks() {
        #expect(MMDateTime.parse("2026-01-01T24:00:00") == .failure(.invalidComponent))
        #expect(MMDateTime.parse("2026-01-01T12:60:00") == .failure(.invalidComponent))
        #expect(MMTimestamp.parse("2026-01-01T12:00:00+18:01") == .failure(.invalidComponent))
        #expect(MMTimestamp.parse("2026-01-01T12:00:00+02:60") == .failure(.invalidComponent))
        // Leap second is legal.
        #expect(MMDateTime.parse("2026-01-01T23:59:60") != .failure(.invalidComponent))
    }

    // MARK: - Semantics

    @Test("timestamps order by instant, not by wall clock")
    func instantOrdering() throws {
        let plusTwo = try MMTimestamp.parse("2026-07-21T14:00:00+02:00").get()
        let utcNoon = try MMTimestamp.parse("2026-07-21T12:00:00Z").get()
        let later = try MMTimestamp.parse("2026-07-21T12:00:01Z").get()
        // Same instant, different rendering: NOT equal (component-wise),
        // and ordered deterministically by the offset tie-break.
        #expect(plusTwo != utcNoon)
        #expect(plusTwo.secondsSinceEpoch == utcNoon.secondsSinceEpoch)
        #expect(utcNoon < plusTwo)
        // The instant dominates: a later instant orders later regardless of
        // how "early" its wall clock looks.
        #expect(plusTwo < later)
    }

    @Test("the civil-day math anchors to the epoch")
    func epochDays() {
        #expect(MMDate(year: 1970, month: 1, day: 1)?.daysSinceEpoch == 0)
        #expect(MMDate(year: 1969, month: 12, day: 31)?.daysSinceEpoch == -1)
        #expect(MMDate(year: 2000, month: 3, day: 1)?.daysSinceEpoch == 11_017)
    }

    // MARK: - Codable and schema classification

    @Test("Codable rides as canonical ISO strings; bad wire strings fail decode")
    func codableStrings() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let stamp = try MMTimestamp.parse("2026-07-21T14:30:00.25+02:00").get()
        let encoded = try encoder.encode([stamp])
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"["2026-07-21T14:30:00.25+02:00"]"#)
        #expect(try decoder.decode([MMTimestamp].self, from: encoded) == [stamp])
        #expect(throws: (any Error).self) {
            _ = try decoder.decode([MMDate].self, from: Data(#"["2026-02-30"]"#.utf8))
        }
    }

    @Test("the kinds classify as their own schema tags, distinct from string")
    func schemaClassification() {
        #expect(MMDate.schema == .date)
        #expect(MMDateTime.schema == .datetime)
        #expect(MMTimestamp.schema == .timestamp)
        // Distinct kinds are distinct in the fingerprint fold.
        let asDate = SchemaFingerprint.compute(
            [], types: [TypeDefinition(name: "x.T", schema: .date)])
        let asString = SchemaFingerprint.compute(
            [], types: [TypeDefinition(name: "x.T", schema: .string)])
        let asTimestamp = SchemaFingerprint.compute(
            [], types: [TypeDefinition(name: "x.T", schema: .timestamp)])
        #expect(asDate != asString)
        #expect(asDate != asTimestamp)
    }

    // MARK: - Macro static subset

    @Test("the macro generates MM* property types and a faithful contract")
    func macroFidelity() throws {
        let breaks = try Chrono.contract.verify(against: Chrono.self).get()
        #expect(breaks == [])
        let signature = try Chrono.plan.signature().get()
        guard case .structure(let fields) = signature.request else {
            Issue.record("request is not a structure")
            return
        }
        #expect(fields.map(\.type) == [.date, .datetime, .timestamp, .optional(.timestamp)])
        // The generated properties are the real value types.
        let request = Chrono.PlanRequest(
            day: MMDate(year: 2026, month: 7, day: 21)!,
            slot: MMDateTime(
                date: MMDate(year: 2026, month: 7, day: 21)!, hour: 14, minute: 30, second: 0)!,
            created: MMTimestamp(
                dateTime: MMDateTime(
                    date: MMDate(year: 2026, month: 7, day: 21)!,
                    hour: 12, minute: 0, second: 0)!,
                offsetMinutes: 120)!,
            remind: nil
        )
        #expect(request.day.description == "2026-07-21")
    }
}

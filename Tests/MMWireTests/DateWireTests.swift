import MMSchema
import MMWire
import NIOCore
import Testing

/// The wire time kinds ride MessagePack as `bin`-wrapped VPTS — the coder
/// short-circuits `MMDate`/`MMDateTime`/`MMTimestamp` exactly as it does
/// `ByteBuffer`, so their ISO-string `Codable` form never reaches the wire.
@Suite("Wire time kinds: VPTS binary encoding")
struct DateWireTests {
    private func date(_ text: String) -> MMDate {
        try! MMDate.parse(text).get()
    }

    private func dateTime(_ text: String) -> MMDateTime {
        try! MMDateTime.parse(text).get()
    }

    private func timestamp(_ text: String) -> MMTimestamp {
        try! MMTimestamp.parse(text).get()
    }

    // MARK: - Exact bytes

    @Test("a date encodes as bin-wrapped VPTS with exactly date precision")
    func dateBytes() {
        // header 0x07 (YEAR|MONTH|DAY), year 2026+32768 = 0x87EA, 07, 22.
        #expect(
            MMPackEncoder().encode(self.date("2026-07-22")).map(mpHex)
                == .success("c4050787ea0716"))
        #expect(
            MMPackDecoder().decode(MMDate.self, from: mpBytes("c4050787ea0716"))
                == .success(self.date("2026-07-22")))
    }

    @Test("a datetime encodes through seconds, fraction only when non-zero")
    func dateTimeBytes() {
        // header 0x3F (through SECOND), 14:30:00 — no FRACTION for zero.
        #expect(
            MMPackEncoder().encode(self.dateTime("2026-07-22T14:30:00")).map(mpHex)
                == .success("c4083f87ea07160e1e00"))
        // header 0x7F adds FRACTION: 0.5 s = 500 000 000 ns = 0x1DCD6500.
        #expect(
            MMPackEncoder().encode(self.dateTime("2026-07-22T14:30:00.5")).map(mpHex)
                == .success("c40c7f87ea07160e1e001dcd6500"))
        #expect(
            MMPackDecoder().decode(
                MMDateTime.self, from: mpBytes("c40c7f87ea07160e1e001dcd6500"))
                == .success(self.dateTime("2026-07-22T14:30:00.5")))
    }

    @Test("a timestamp carries the offset in the extension; zero offset is 0x0000")
    func timestampBytes() {
        // header 0xBF (EXT set), extension 0x01 (OFFSET), offset int16 BE.
        #expect(
            MMPackEncoder().encode(self.timestamp("2026-07-22T14:30:00Z")).map(mpHex)
                == .success("c40bbf0187ea07160e1e000000"))
        #expect(
            MMPackEncoder().encode(self.timestamp("2026-07-22T14:30:00+02:00")).map(mpHex)
                == .success("c40bbf0187ea07160e1e000078"))
        // -04:00 = -240 minutes = 0xFF10 two's complement.
        #expect(
            MMPackEncoder().encode(self.timestamp("2026-07-22T14:30:00-04:00")).map(mpHex)
                == .success("c40bbf0187ea07160e1e00ff10"))
        #expect(
            MMPackDecoder().decode(
                MMTimestamp.self, from: mpBytes("c40bbf0187ea07160e1e00ff10"))
                == .success(self.timestamp("2026-07-22T14:30:00-04:00")))
    }

    // MARK: - Container paths

    private struct Payload: Codable, Equatable {
        var day: MMDate
        var at: MMDateTime?
        var seen: [MMTimestamp]

        enum CodingKeys: Int, CodingKey {
            case day = 1
            case at = 2
            case seen = 3
        }
    }

    @Test("keyed, optional, and unkeyed fields all round-trip as VPTS")
    func containerRoundTrip() throws {
        let payload = Payload(
            day: self.date("2026-07-22"),
            at: self.dateTime("2026-07-22T14:30:00.123456789"),
            seen: [
                self.timestamp("2026-07-22T14:30:00Z"),
                self.timestamp("2026-12-31T23:59:60+18:00"),
            ]
        )
        let encoded = try MMPackEncoder().encode(payload).get()
        #expect(MMPackDecoder().decode(Payload.self, from: encoded) == .success(payload))
        // A nil optional stays MessagePack nil, never a VPTS null.
        let sparse = Payload(day: self.date("0000-01-01"), at: nil, seen: [])
        let sparseEncoded = try MMPackEncoder().encode(sparse).get()
        #expect(MMPackDecoder().decode(Payload.self, from: sparseEncoded) == .success(sparse))
    }

    // MARK: - Rejections

    @Test("an ISO string where VPTS bin is expected is a decode failure")
    func stringRejected() throws {
        let asString = try MMPackEncoder().encode("2026-07-22").get()
        #expect(throws: MMWireError.self) {
            try MMPackDecoder().decode(MMDate.self, from: asString).get()
        }
    }

    @Test("the VPTS null encoding is never a value")
    func nullRejected() {
        #expect(throws: MMWireError.self) {
            try MMPackDecoder().decode(MMTimestamp.self, from: mpBytes("c40100")).get()
        }
    }

    @Test("invalid VPTS bytes are a decode failure")
    func garbageRejected() {
        // Header promises YEAR|MONTH|DAY but the payload is truncated.
        #expect(throws: MMWireError.self) {
            try MMPackDecoder().decode(MMDate.self, from: mpBytes("c4020787")).get()
        }
    }

    @Test("precision and offset must match the schema kind")
    func kindMismatchRejected() {
        let dateBytes = mpBytes("c4050787ea0716")
        #expect(throws: MMWireError.self) {
            try MMPackDecoder().decode(MMDateTime.self, from: dateBytes).get()
        }
        // A datetime never carries an offset; a timestamp always does.
        let zonedBytes = mpBytes("c40bbf0187ea07160e1e000000")
        #expect(throws: MMWireError.self) {
            try MMPackDecoder().decode(MMDateTime.self, from: zonedBytes).get()
        }
        let wallClockBytes = mpBytes("c4083f87ea07160e1e00")
        #expect(throws: MMWireError.self) {
            try MMPackDecoder().decode(MMTimestamp.self, from: wallClockBytes).get()
        }
    }
}

import Testing

@testable import MMSchema

/// The VPTS codec against the VPTS spec v0.2 (MMWire's DocC catalog) —
/// every §7 test vector in
/// both directions, every invalid example rejected for the spec's reason,
/// and the §5 ordering property.
@Suite("VPTS: variable-precision timestamps")
struct VPTSTests {
    private func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var digits = text.replacingOccurrences(of: " ", with: "")[...]
        while let high = digits.popFirst(), let low = digits.popFirst() {
            bytes.append(UInt8(String([high, low]), radix: 16)!)
        }
        return bytes
    }

    // MARK: - §7 positive vectors, both directions

    @Test("null is one byte and decodes to nil")
    func nullVector() throws {
        #expect(MMVPTS.nullEncoding == [0x00])
        #expect(try MMVPTS.decode([0x00]).get() == nil)
    }

    @Test("year 2026 — `01 87 EA`")
    func yearVector() throws {
        let value = MMVPTS(year: 2026)!
        let bytes = hex("01 87 EA")
        #expect(value.encoded() == bytes)
        #expect(try MMVPTS.decode(bytes).get() == value)
    }

    @Test("2026-07-22 — `07 87 EA 07 16`")
    func dateVector() throws {
        let value = MMVPTS(MMDate(year: 2026, month: 7, day: 22)!)
        let bytes = hex("07 87 EA 07 16")
        #expect(value.encoded() == bytes)
        #expect(try MMVPTS.decode(bytes).get() == value)
        #expect(try MMVPTS.decode(bytes).get()?.dateValue == MMDate(year: 2026, month: 7, day: 22))
    }

    @Test("2026-07-22T14:30:00Z — `BF 01 87 EA 07 16 0E 1E 00 00 00`")
    func utcTimestampVector() throws {
        let timestamp = try MMTimestamp.parse("2026-07-22T14:30:00Z").get()
        let value = MMVPTS(timestamp)
        let bytes = hex("BF 01 87 EA 07 16 0E 1E 00 00 00")
        #expect(value.encoded() == bytes)
        #expect(try MMVPTS.decode(bytes).get() == value)
        #expect(try MMVPTS.decode(bytes).get()?.timestampValue == timestamp)
    }

    @Test("2026-07-22T14:30:00.123456789-04:00 — `FF 01 ... FF 10`")
    func fractionalOffsetVector() throws {
        let timestamp = try MMTimestamp.parse("2026-07-22T14:30:00.123456789-04:00").get()
        let value = MMVPTS(timestamp)
        let bytes = hex("FF 01 87 EA 07 16 0E 1E 00 07 5B CD 15 FF 10")
        #expect(value.encoded() == bytes)
        #expect(try MMVPTS.decode(bytes).get() == value)
        #expect(try MMVPTS.decode(bytes).get()?.timestampValue == timestamp)
    }

    @Test("year −13 800 000 000 (wide) — `81 02 7F FF FF FC C9 74 B6 00`")
    func wideYearVector() throws {
        let value = MMVPTS(year: -13_800_000_000)!
        let bytes = hex("81 02 7F FF FF FC C9 74 B6 00")
        #expect(value.encoded() == bytes)
        #expect(try MMVPTS.decode(bytes).get() == value)
    }

    @Test("one attosecond, UTC — the full 25-byte wide form")
    func attosecondVector() throws {
        let value = MMVPTS(
            year: 2026, month: 7, day: 22, hour: 14, minute: 30, second: 0,
            fraction: .attoseconds(1), offsetMinutes: 0)!
        let bytes = hex(
            "FF 03 80 00 00 00 00 00 07 EA 07 16 0E 1E 00 00 00 00 00 00 00 00 01 00 00")
        #expect(value.encoded() == bytes)
        #expect(try MMVPTS.decode(bytes).get() == value)
        // Sub-nanosecond precision has no fixed-kind form.
        #expect(try MMVPTS.decode(bytes).get()?.timestampValue == nil)
    }

    // MARK: - §7 invalid examples

    @Test(
        "the spec's invalid examples are rejected for the spec's reasons",
        arguments: [
            ("05 87 EA 16", MMVPTSDecodeFailure.nonContiguousMask),
            ("41 87 EA", .fractionWithoutSecond),
            ("81 00 87 EA", .emptyExtension),
            ("87 01 87 EA 07 16 00 00", .offsetWithoutHour),
            ("80 02", .wideWithoutYear),
            // Spec 0.2-draft printed this as `01 04 87 EA`, but header 0x01
            // has EXT clear — no extension byte exists to carry a reserved
            // bit (those bytes are a year plus trailing garbage). The spec
            // row was corrected to EXT-set form.
            ("81 04 87 EA", .reservedExtensionBits),
            ("07 87 EA 02 1E", .invalidComponent),
        ]
    )
    func invalidVectors(vector: (String, MMVPTSDecodeFailure)) {
        #expect(MMVPTS.decode(self.hex(vector.0)) == .failure(vector.1))
    }

    @Test("self-delimiting: truncation and trailing bytes are rejected")
    func lengthDiscipline() {
        #expect(MMVPTS.decode([]) == .failure(.empty))
        #expect(MMVPTS.decode(self.hex("01 87")) == .failure(.truncated))
        #expect(MMVPTS.decode(self.hex("01 87 EA 00")) == .failure(.trailingBytes))
        #expect(MMVPTS.decode(self.hex("00 00")) == .failure(.trailingBytes))
    }

    // MARK: - Semantics

    @Test("precision is part of the value: absent is not zero, declared zero is not absent")
    func precisionSemantics() {
        #expect(MMVPTS(year: 2026, month: 7) != MMVPTS(year: 2026, month: 7, day: 1))
        let bare = MMVPTS(
            year: 2026, month: 7, day: 22, hour: 12, minute: 0, second: 0)!
        let declaredZero = MMVPTS(
            year: 2026, month: 7, day: 22, hour: 12, minute: 0, second: 0,
            fraction: .nanoseconds(0))!
        #expect(bare != declaredZero)
        #expect(bare.encoded() != declaredZero.encoded())
        // Width is precision too: 9 declared digits ≠ 18 declared digits.
        let wide = MMVPTS(
            year: 2026, month: 7, day: 22, hour: 12, minute: 0, second: 0,
            fraction: .attoseconds(0))!
        #expect(declaredZero != wide)
    }

    @Test("construction rejects the spec's invalid shapes")
    func constructionValidation() {
        #expect(MMVPTS(year: 2026, day: 22) == nil)  // gap in the chain
        #expect(MMVPTS() == nil)  // all-nil is not a value
        #expect(MMVPTS(year: 2026, month: 2, day: 30) == nil)
        #expect(MMVPTS(year: 2026, month: 7, day: 22, hour: 24) == nil)
        #expect(
            MMVPTS(
                year: 2026, month: 7, day: 22, hour: 12, minute: 0, second: 0,
                offsetMinutes: 1440) == nil)
        // Offset attaches to times: valid with an hour even without seconds.
        #expect(
            MMVPTS(year: 2026, month: 7, day: 22, hour: 12, offsetMinutes: 120) != nil)
    }

    @Test("wide is used only when needed; non-canonical wide input normalizes")
    func wideCanonicality() throws {
        // Narrow-fitting year: 3 bytes, no EXT.
        #expect(MMVPTS(year: 2026)!.encoded().count == 3)
        // A foreign encoder's non-canonical wide year decodes fine and
        // re-encodes canonically narrow.
        let nonCanonical = self.hex("81 02 80 00 00 00 00 00 07 EA")
        let decoded = try MMVPTS.decode(nonCanonical).get()
        #expect(decoded == MMVPTS(year: 2026))
        #expect(decoded?.encoded() == self.hex("01 87 EA"))
        // A nanosecond fraction alongside a wide year rides wide, scaled
        // exactly (1 ns = 10⁹ as) — and comes back as attoseconds.
        let mixed = MMVPTS(
            year: 40000, month: 1, day: 1, hour: 0, minute: 0, second: 0,
            fraction: .nanoseconds(1))!
        let roundTripped = try MMVPTS.decode(mixed.encoded()).get()
        #expect(roundTripped?.fraction == .attoseconds(1_000_000_000))
    }

    @Test("bytewise order equals chronological order for equal headers (§5)")
    func lexicographicOrdering() {
        let values = [
            MMVPTS(year: -44, month: 3, day: 15)!,
            MMVPTS(year: 1969, month: 7, day: 20)!,
            MMVPTS(year: 1969, month: 7, day: 21)!,
            MMVPTS(year: 2026, month: 7, day: 22)!,
            MMVPTS(year: 9999, month: 12, day: 31)!,
        ]
        let encodings = values.map { $0.encoded() }
        // Already chronological; the encodings must sort identically.
        let sorted = encodings.sorted { lhs, rhs in
            for (left, right) in zip(lhs, rhs) where left != right {
                return left < right
            }
            return lhs.count < rhs.count
        }
        #expect(sorted == encodings)
    }

    @Test("the fixed kinds round-trip through VPTS")
    func fixedKindMapping() throws {
        let date = MMDate(year: 2026, month: 2, day: 28)!
        #expect(MMVPTS(date).dateValue == date)
        let dateTime = try MMDateTime.parse("2026-07-22T14:30:00.25").get()
        #expect(MMVPTS(dateTime).dateTimeValue == dateTime)
        // A datetime never surfaces as a timestamp and vice versa.
        #expect(MMVPTS(dateTime).timestampValue == nil)
        let timestamp = try MMTimestamp.parse("2026-07-22T14:30:00.25-09:30").get()
        #expect(MMVPTS(timestamp).timestampValue == timestamp)
        #expect(MMVPTS(timestamp).dateTimeValue == nil)
        #expect(MMVPTS(timestamp).dateValue == nil)
    }
}

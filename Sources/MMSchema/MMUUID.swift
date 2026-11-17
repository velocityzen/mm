/// A universally unique identifier (RFC 9562): the wire's `uuid` kind.
///
/// ```swift
/// let id = MMUUID.random()                       // version 4
/// let parsed = MMUUID("f81d4fae-7dec-11d0-a765-00a0c91e6bf6")
/// ```
///
/// Its own type, not Foundation's `UUID`, because MMSchema depends on
/// nothing: parsing, formatting and random generation are written here, and
/// where Foundation exists the two convert both ways. Its `Codable` form is
/// the canonical text JSON coders and the
/// generated CLI print and read; on the wire it travels as MessagePack `bin`
/// holding its 16 bytes, the coder-level shortcut the time kinds use.
///
/// The value is the 128 bits in network byte order, as RFC 9562 lays them
/// out; ``high`` holds the first eight bytes and ``low`` the last eight.
/// Values order by those bytes, which is also the order of their canonical
/// text.
public struct MMUUID: Sendable, Hashable, Comparable {
    /// The first eight bytes, big-endian: `time_low`, `time_mid` and
    /// `time_high_and_version` in RFC 9562's version 1 layout.
    public var high: UInt64
    /// The last eight bytes, big-endian: the variant, the clock sequence and
    /// the node in RFC 9562's version 1 layout.
    public var low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    /// The identifier whose 16 bytes are `bytes`, in order, or nil unless
    /// there are exactly 16.
    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 16 else { return nil }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            if index < 8 {
                high = high << 8 | UInt64(byte)
            } else {
                low = low << 8 | UInt64(byte)
            }
        }
        self.init(high: high, low: low)
    }

    /// The 16 bytes, in network byte order.
    public var bytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for half in [self.high, self.low] {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: half >> shift))
            }
        }
        return bytes
    }

    /// All 128 bits zero: RFC 9562's Nil UUID.
    public static let zero = MMUUID(high: 0, low: 0)

    public static func < (lhs: MMUUID, rhs: MMUUID) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }
}

// MARK: - Random generation

extension MMUUID {
    /// A random version 4 identifier: 122 random bits from `generator`, with
    /// the version field set to 4 and the variant to RFC 9562's `10`.
    public static func random(using generator: inout some RandomNumberGenerator) -> MMUUID {
        let high = generator.next() as UInt64
        let low = generator.next() as UInt64
        return MMUUID(
            high: high & ~0xF000 | 0x4000,
            low: low & 0x3FFF_FFFF_FFFF_FFFF | 0x8000_0000_0000_0000
        )
    }

    /// A random version 4 identifier from the system's random source.
    public static func random() -> MMUUID {
        var generator = SystemRandomNumberGenerator()
        return Self.random(using: &generator)
    }
}

// MARK: - Text

extension MMUUID: CustomStringConvertible, LosslessStringConvertible {
    /// The canonical text: 32 lowercase hexadecimal digits in groups of 8,
    /// 4, 4, 4 and 12, joined by hyphens
    /// (`f81d4fae-7dec-11d0-a765-00a0c91e6bf6`).
    public var description: String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(36)
        for (index, byte) in self.bytes.enumerated() {
            if index == 4 || index == 6 || index == 8 || index == 10 {
                text.append(UInt8(ascii: "-"))
            }
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// Parses the hyphenated text form, digits in either case: exactly 36
    /// characters, hyphens at offsets 8, 13, 18 and 23 and hexadecimal
    /// digits everywhere else. Nil for anything else, including the forms
    /// without hyphens, with braces or with a `urn:uuid:` prefix.
    public init?(_ description: String) {
        let text = Array(description.utf8)
        guard text.count == 36 else { return nil }
        var high: UInt64 = 0
        var low: UInt64 = 0
        var digitCount = 0
        for (offset, character) in text.enumerated() {
            if offset == 8 || offset == 13 || offset == 18 || offset == 23 {
                guard character == UInt8(ascii: "-") else { return nil }
                continue
            }
            guard let value = Self.hexadecimalValue(character) else { return nil }
            if digitCount < 16 {
                high = high << 4 | UInt64(value)
            } else {
                low = low << 4 | UInt64(value)
            }
            digitCount += 1
        }
        self.init(high: high, low: low)
    }

    private static func hexadecimalValue(_ character: UInt8) -> UInt8? {
        switch character {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
            default: nil
        }
    }
}

extension MMUUID: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = MMUUID(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "'\(text)' is not a UUID (f81d4fae-7dec-11d0-a765-00a0c91e6bf6)"
            )
        }
        self = value
    }
}

extension MMUUID: SchemaDescribable {
    public static var schema: TypeSchema { .uuid }
}

// The probe walks containing decoders with placeholder instances; the
// decoder rejects the probe's empty string, so the Nil UUID stands in.
extension MMUUID: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any { MMUUID.zero }
}

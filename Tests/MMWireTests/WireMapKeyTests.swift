import MMWire
import NIOCore
import Testing

/// A `String`-backed enum with `Codable`'s own conformance: text naming no
/// case is refused.
private enum WireMapKeyColor: String, Codable, Hashable {
    case red, green
}

/// A `String`-backed enum whose raw value looks like an integer.
private enum WireMapKeyDigit: String, Codable, Hashable {
    case five = "5"
}

/// An `Int`-backed enum.
private enum WireMapKeyLevel: Int, Codable, Hashable {
    case low = 1
    case high = 2
}

/// Shaped like a generated enum: text naming no case decodes to `unknown`.
private enum WireMapKeyMood: String, Codable, Hashable {
    case calm
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WireMapKeyMood(rawValue: raw) ?? .unknown
    }
}

/// A dictionary reached through a keyed container.
private struct WireMapKeyHolder: Codable, Equatable {
    var ports: [UInt16: Bool]
}

@Suite("Wire map keys")
struct WireMapKeyTests {
    @Test("a dictionary keyed by an unsigned integer is a wire map with integer keys")
    func unsignedKeys() {
        let value: [UInt64: String] = [7: "a"]
        let encoded = MMPackEncoder().encode(value).mpSuccess!
        // fixmap 1, key 7, fixstr "a" — where Codable writes the array [7, "a"].
        #expect(mpHex(encoded) == "8107a161")
        #expect(MMPackDecoder().decode([UInt64: String].self, from: encoded) == .success(value))
    }

    @Test("every integer key type writes the map Int keys do")
    func integerKeyTypes() {
        let hex = "8105c3"
        #expect(mpHex(MMPackEncoder().encode([UInt8(5): true]).mpSuccess!) == hex)
        #expect(mpHex(MMPackEncoder().encode([Int8(5): true]).mpSuccess!) == hex)
        #expect(mpHex(MMPackEncoder().encode([UInt32(5): true]).mpSuccess!) == hex)
        #expect(mpHex(MMPackEncoder().encode([Int64(5): true]).mpSuccess!) == hex)
        #expect(mpHex(MMPackEncoder().encode([Int(5): true]).mpSuccess!) == hex)
        #expect(
            MMPackDecoder().decode([Int16: Bool].self, from: mpBytes(hex)) == .success([5: true])
        )
    }

    @Test("an unsigned key reaches Int64.max, and one past it fails the encode")
    func unsignedKeyRange() {
        let largest: [UInt64: String] = [UInt64(Int64.max): "a"]
        let encoded = MMPackEncoder().encode(largest).mpSuccess!
        #expect(mpHex(encoded) == "81cf7fffffffffffffffa161")
        #expect(MMPackDecoder().decode([UInt64: String].self, from: encoded) == .success(largest))

        let past: [UInt64: String] = [UInt64(Int64.max) + 1: "a"]
        #expect(
            MMPackEncoder().encode(past).mpFailure == .numberOutOfRange(target: "Int64")
        )
        // Nothing is written on failure.
        var buffer = mpBytes("c0")
        #expect(MMPackEncoder().encode(past, into: &buffer).mpFailure != nil)
        #expect(mpHex(buffer) == "c0")
    }

    @Test("a dictionary keyed by an enum is a wire map keyed by its raw values")
    func enumKeys() {
        let colors: [WireMapKeyColor: Int] = [.red: 1]
        let colorBytes = MMPackEncoder().encode(colors).mpSuccess!
        #expect(mpHex(colorBytes) == "81a372656401")
        #expect(
            MMPackDecoder().decode([WireMapKeyColor: Int].self, from: colorBytes)
                == .success(colors)
        )

        let levels: [WireMapKeyLevel: String] = [.high: "x"]
        let levelBytes = MMPackEncoder().encode(levels).mpSuccess!
        #expect(mpHex(levelBytes) == "8102a178")
        #expect(
            MMPackDecoder().decode([WireMapKeyLevel: String].self, from: levelBytes)
                == .success(levels)
        )
    }

    @Test("a key travels as its own encoding: text that looks like an integer stays text")
    func textKeyStaysText() {
        let digits: [WireMapKeyDigit: Int] = [.five: 1]
        let encoded = MMPackEncoder().encode(digits).mpSuccess!
        #expect(mpHex(encoded) == "81a13501")
        #expect(
            MMPackDecoder().decode([WireMapKeyDigit: Int].self, from: encoded) == .success(digits)
        )
        // The integer 5 is not the text "5".
        #expect(
            MMPackDecoder().decode([WireMapKeyDigit: Int].self, from: mpBytes("810501")).mpFailure
                == .typeMismatch(expected: "str", format: 0x05)
        )
    }

    @Test("an enum that reads unknown text as unknown keeps the first such key's value")
    func unknownEnumKeys() {
        // {"calm": 1, "sleepy": 2, "grumpy": 3}
        let bytes = mpBytes("83a463616c6d01a6736c6565707902a66772756d707903")
        #expect(
            MMPackDecoder().decode([WireMapKeyMood: Int].self, from: bytes)
                == .success([.calm: 1, .unknown: 2])
        )
    }

    @Test("a key is refused as a value of its type would be")
    func refusedKeys() {
        // Text where an unsigned key belongs.
        #expect(
            MMPackDecoder().decode([UInt64: String].self, from: mpBytes("81a178a161")).mpFailure
                == .typeMismatch(expected: "integer", format: 0xa1)
        )
        // A negative unsigned key.
        #expect(
            MMPackDecoder().decode([UInt64: String].self, from: mpBytes("81ffa161")).mpFailure
                == .numberOutOfRange(target: "UInt64")
        )
        // 256 where a UInt8 key belongs.
        #expect(
            MMPackDecoder().decode([UInt8: String].self, from: mpBytes("81cd0100a161")).mpFailure
                == .numberOutOfRange(target: "UInt8")
        )
        // Text naming no case of an enum with Codable's own conformance.
        let purple = MMPackDecoder().decode(
            [WireMapKeyColor: Int].self,
            from: mpBytes("81a6707572706c6501")
        )
        guard case .failure(.decodingFailed) = purple else {
            Issue.record("expected decodingFailed, got \(purple)")
            return
        }
    }

    @Test("a dictionary with wire map keys refuses Codable's array of keys and values")
    func pairsRefused() {
        #expect(
            MMPackDecoder().decode([UInt64: String].self, from: mpBytes("9207a161")).mpFailure
                == .typeMismatch(expected: "map", format: 0x92)
        )
        #expect(
            MMPackDecoder().decode([WireMapKeyColor: Int].self, from: mpBytes("92a372656401"))
                .mpFailure == .typeMismatch(expected: "map", format: 0x92)
        )
    }

    @Test("wire map keys hold through keyed, unkeyed and single-value containers")
    func throughContainers() {
        let holder = WireMapKeyHolder(ports: [443: true])
        let holderBytes = MMPackEncoder().encode(holder).mpSuccess!
        // {"ports": {443: true}}
        #expect(mpHex(holderBytes) == "81a5706f72747381cd01bbc3")
        #expect(
            MMPackDecoder().decode(WireMapKeyHolder.self, from: holderBytes) == .success(holder)
        )

        let list: [[UInt64: String]] = [[7: "a"]]
        let listBytes = MMPackEncoder().encode(list).mpSuccess!
        #expect(mpHex(listBytes) == "918107a161")
        #expect(MMPackDecoder().decode([[UInt64: String]].self, from: listBytes) == .success(list))

        let optional: [UInt64: String]? = [7: "a"]
        let optionalBytes = MMPackEncoder().encode(optional).mpSuccess!
        #expect(mpHex(optionalBytes) == "8107a161")
        #expect(
            MMPackDecoder().decode([UInt64: String]?.self, from: optionalBytes)
                == .success(optional)
        )
    }

    @Test("keys Codable writes as an array of keys and values stay that way")
    func otherKeysKeepPairs() {
        let flags: [Bool: Int] = [true: 1]
        let encoded = MMPackEncoder().encode(flags).mpSuccess!
        #expect(mpHex(encoded) == "92c301")
        #expect(MMPackDecoder().decode([Bool: Int].self, from: encoded) == .success(flags))
    }
}

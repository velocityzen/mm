import NIOCore
import Testing

/// Builds a `ByteBuffer` from a hex string ("cc80" → [0xcc, 0x80]).
func mpBytes(_ hex: String) -> ByteBuffer {
    precondition(hex.count.isMultiple(of: 2), "hex string must have even length")
    var buffer = ByteBuffer()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else {
            preconditionFailure("invalid hex: \(hex[index..<next])")
        }
        buffer.writeInteger(byte)
        index = next
    }
    return buffer
}

/// Lowercase hex of a buffer's readable bytes.
func mpHex(_ buffer: ByteBuffer) -> String {
    let digits = Array("0123456789abcdef")
    var out = ""
    out.reserveCapacity(buffer.readableBytes * 2)
    for byte in buffer.readableBytesView {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0f)])
    }
    return out
}

/// Spec-derived canonical MessagePack encoding (hex) of a non-negative integer < 2^16.
/// Written against the spec tables, independently of the production writer, for
/// constructing large expected byte sequences.
func specUIntHex(_ value: Int) -> String {
    precondition(value >= 0 && value <= 0xffff)
    let digits = Array("0123456789abcdef")
    func byte(_ b: UInt8) -> String {
        String([digits[Int(b >> 4)], digits[Int(b & 0x0f)]])
    }
    if value <= 0x7f { return byte(UInt8(value)) }
    if value <= 0xff { return "cc" + byte(UInt8(value)) }
    return "cd" + byte(UInt8(value >> 8)) + byte(UInt8(value & 0xff))
}

extension Result {
    var mpFailure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }

    var mpSuccess: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

/// Hand-rolled seeded PRNG (SplitMix64). Never an unseeded RNG in tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

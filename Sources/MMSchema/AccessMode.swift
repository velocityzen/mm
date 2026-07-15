/// POSIX-style rwx permission bits for one permission class, as an `OptionSet`
/// over the low three bits of a byte.
///
/// Bit layout matches POSIX exactly: execute = 1, write = 2, read = 4. A method
/// descriptor carries the `AccessMode` its verb requires on its target entity
/// (`journal.append` requires `.write`, `rpc.schema` requires `.read`, traversal
/// requires `.execute` on every ancestor prefix).
///
/// On the wire an `AccessMode` travels as its raw `UInt8`. Unknown high bits are
/// preserved on decode rather than rejected, per the wire-evolution rule that
/// decoding never fails on unrecognized values.
public struct AccessMode: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Execute / traverse. POSIX `x`, bit value 1.
    public static let execute = AccessMode(rawValue: 1)
    /// Write / mutate. POSIX `w`, bit value 2.
    public static let write = AccessMode(rawValue: 2)
    /// Read / observe. POSIX `r`, bit value 4.
    public static let read = AccessMode(rawValue: 4)

    /// All three bits: `rwx` = 7.
    public static let all: AccessMode = [.read, .write, .execute]
}

extension AccessMode: Codable {
    /// Encodes as the raw `UInt8` in a single-value container.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Decodes from a raw `UInt8`; never rejects unknown bits.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt8.self))
    }
}

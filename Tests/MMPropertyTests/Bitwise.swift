// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    /// A value compared bit for bit: its floating-point fields by bit pattern,
    /// so NaN equals itself and -0.0 differs from 0.0, and everything else by
    /// value, with those fields zeroed. Lets a property draw any float and
    /// still check that it comes back exactly.
    struct Bitwise<Value: Equatable>: Equatable {
        var value: Value
        var floatBits: [UInt64]
    }

    extension Bitwise: Sendable where Value: Sendable {}

#endif

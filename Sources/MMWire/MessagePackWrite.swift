import NIOCore

/// MessagePack value writers over `ByteBuffer`.
///
/// Every writer emits the smallest correct representation for its value, per the
/// MessagePack spec. Multi-byte values are big-endian (NIO's `writeInteger` default).
extension ByteBuffer {
    public mutating func writeMessagePackNil() {
        self.writeInteger(MPFormat.nilByte)
    }

    public mutating func writeMessagePackBool(_ value: Bool) {
        self.writeInteger(value ? MPFormat.trueByte : MPFormat.falseByte)
    }

    /// Writes a signed integer in its smallest correct representation.
    /// Non-negative values use the positive fixint / uint family.
    public mutating func writeMessagePackInt(_ value: Int64) {
        if value >= 0 {
            self.writeMessagePackUInt(UInt64(value))
        } else if value >= -32 {
            self.writeInteger(UInt8(truncatingIfNeeded: value))
        } else if value >= Int64(Int8.min) {
            self.writeInteger(MPFormat.int8)
            self.writeInteger(Int8(truncatingIfNeeded: value))
        } else if value >= Int64(Int16.min) {
            self.writeInteger(MPFormat.int16)
            self.writeInteger(Int16(truncatingIfNeeded: value))
        } else if value >= Int64(Int32.min) {
            self.writeInteger(MPFormat.int32)
            self.writeInteger(Int32(truncatingIfNeeded: value))
        } else {
            self.writeInteger(MPFormat.int64)
            self.writeInteger(value)
        }
    }

    /// Writes an unsigned integer in its smallest correct representation.
    public mutating func writeMessagePackUInt(_ value: UInt64) {
        if value <= UInt64(MPFormat.positiveFixintMax) {
            self.writeInteger(UInt8(truncatingIfNeeded: value))
        } else if value <= UInt64(UInt8.max) {
            self.writeInteger(MPFormat.uint8)
            self.writeInteger(UInt8(truncatingIfNeeded: value))
        } else if value <= UInt64(UInt16.max) {
            self.writeInteger(MPFormat.uint16)
            self.writeInteger(UInt16(truncatingIfNeeded: value))
        } else if value <= UInt64(UInt32.max) {
            self.writeInteger(MPFormat.uint32)
            self.writeInteger(UInt32(truncatingIfNeeded: value))
        } else {
            self.writeInteger(MPFormat.uint64)
            self.writeInteger(value)
        }
    }

    /// Writes a `float32` value (bit-exact).
    public mutating func writeMessagePackFloat(_ value: Float) {
        self.writeInteger(MPFormat.float32)
        self.writeInteger(value.bitPattern)
    }

    /// Writes a `float64` value (bit-exact).
    public mutating func writeMessagePackDouble(_ value: Double) {
        self.writeInteger(MPFormat.float64)
        self.writeInteger(value.bitPattern)
    }

    /// Writes a `fixstr`/`str8`/`str16`/`str32` header for a UTF-8 payload of `byteCount` bytes.
    public mutating func writeMessagePackStringHeader(byteCount: Int) {
        precondition(
            byteCount >= 0 && byteCount <= UInt32.max,
            "str payload exceeds MessagePack length limits"
        )
        if byteCount < 32 {
            self.writeInteger(MPFormat.fixstrBase | UInt8(truncatingIfNeeded: byteCount))
        } else if byteCount <= Int(UInt8.max) {
            self.writeInteger(MPFormat.str8)
            self.writeInteger(UInt8(truncatingIfNeeded: byteCount))
        } else if byteCount <= Int(UInt16.max) {
            self.writeInteger(MPFormat.str16)
            self.writeInteger(UInt16(truncatingIfNeeded: byteCount))
        } else {
            self.writeInteger(MPFormat.str32)
            self.writeInteger(UInt32(truncatingIfNeeded: byteCount))
        }
    }

    public mutating func writeMessagePackString(_ value: String) {
        self.writeMessagePackStringHeader(byteCount: value.utf8.count)
        self.writeString(value)
    }

    /// Writes a `bin8`/`bin16`/`bin32` header for a payload of `byteCount` bytes.
    public mutating func writeMessagePackBinaryHeader(byteCount: Int) {
        precondition(
            byteCount >= 0 && byteCount <= UInt32.max,
            "bin payload exceeds MessagePack length limits"
        )
        if byteCount <= Int(UInt8.max) {
            self.writeInteger(MPFormat.bin8)
            self.writeInteger(UInt8(truncatingIfNeeded: byteCount))
        } else if byteCount <= Int(UInt16.max) {
            self.writeInteger(MPFormat.bin16)
            self.writeInteger(UInt16(truncatingIfNeeded: byteCount))
        } else {
            self.writeInteger(MPFormat.bin32)
            self.writeInteger(UInt32(truncatingIfNeeded: byteCount))
        }
    }

    public mutating func writeMessagePackBinary(_ payload: ByteBuffer) {
        self.writeMessagePackBinaryHeader(byteCount: payload.readableBytes)
        self.writeImmutableBuffer(payload)
    }

    public mutating func writeMessagePackBinary(bytes: some Collection<UInt8>) {
        self.writeMessagePackBinaryHeader(byteCount: bytes.count)
        self.writeBytes(bytes)
    }

    /// Writes a `fixarray`/`array16`/`array32` header. The caller writes `count` values after it.
    public mutating func writeMessagePackArrayHeader(count: Int) {
        precondition(count >= 0 && count <= UInt32.max, "array exceeds MessagePack length limits")
        if count < 16 {
            self.writeInteger(MPFormat.fixarrayBase | UInt8(truncatingIfNeeded: count))
        } else if count <= Int(UInt16.max) {
            self.writeInteger(MPFormat.array16)
            self.writeInteger(UInt16(truncatingIfNeeded: count))
        } else {
            self.writeInteger(MPFormat.array32)
            self.writeInteger(UInt32(truncatingIfNeeded: count))
        }
    }

    /// Writes a `fixmap`/`map16`/`map32` header. The caller writes `count` key-value pairs after it.
    public mutating func writeMessagePackMapHeader(count: Int) {
        precondition(count >= 0 && count <= UInt32.max, "map exceeds MessagePack length limits")
        if count < 16 {
            self.writeInteger(MPFormat.fixmapBase | UInt8(truncatingIfNeeded: count))
        } else if count <= Int(UInt16.max) {
            self.writeInteger(MPFormat.map16)
            self.writeInteger(UInt16(truncatingIfNeeded: count))
        } else {
            self.writeInteger(MPFormat.map32)
            self.writeInteger(UInt32(truncatingIfNeeded: count))
        }
    }

    /// Writes an ext value. Payload lengths 1, 2, 4, 8, and 16 use the fixext formats;
    /// everything else uses the smallest of `ext8`/`ext16`/`ext32`.
    public mutating func writeMessagePackExt(type: Int8, payload: ByteBuffer) {
        let byteCount = payload.readableBytes
        precondition(byteCount <= UInt32.max, "ext payload exceeds MessagePack length limits")
        switch byteCount {
            case 1: self.writeInteger(MPFormat.fixext1)
            case 2: self.writeInteger(MPFormat.fixext2)
            case 4: self.writeInteger(MPFormat.fixext4)
            case 8: self.writeInteger(MPFormat.fixext8)
            case 16: self.writeInteger(MPFormat.fixext16)
            default:
                if byteCount <= Int(UInt8.max) {
                    self.writeInteger(MPFormat.ext8)
                    self.writeInteger(UInt8(truncatingIfNeeded: byteCount))
                } else if byteCount <= Int(UInt16.max) {
                    self.writeInteger(MPFormat.ext16)
                    self.writeInteger(UInt16(truncatingIfNeeded: byteCount))
                } else {
                    self.writeInteger(MPFormat.ext32)
                    self.writeInteger(UInt32(truncatingIfNeeded: byteCount))
                }
        }
        self.writeInteger(UInt8(bitPattern: type))
        self.writeImmutableBuffer(payload)
    }
}

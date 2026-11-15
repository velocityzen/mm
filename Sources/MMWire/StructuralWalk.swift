/// The structural walk behind `skipMessagePackValue`: it steps over one
/// MessagePack value in raw bytes, nested containers included, reading only
/// format bytes and the lengths and counts after them.
///
/// It stops where a byte-by-byte read of the value would, and for the same
/// reason: input ending inside a value, the reserved `0xc1` byte, or a
/// container at the nesting cap. A failed read leaves `offset` before the
/// field it could not read, so the reader index lands where the
/// `ByteBuffer` reads it replaces left it.
struct MPStructuralWalk {
    /// Why a walk stopped short.
    enum Failure {
        case truncated
        case invalidFormat(UInt8)
        case nestingTooDeep
    }

    private let bytes: UnsafeRawBufferPointer
    private let cap: Int
    /// How far the walk has read into `bytes`.
    private(set) var offset = 0

    init(bytes: UnsafeRawBufferPointer, cap: Int) {
        self.bytes = bytes
        self.cap = cap
    }

    /// Steps over one value that sits at container nesting level `depth`.
    /// Nil once the whole value is behind the walk.
    mutating func skipValue(depth: Int) -> Failure? {
        guard self.offset < self.bytes.count else { return .truncated }
        let format = self.bytes[self.offset]
        self.offset += 1
        switch format {
            case 0x00...0x7f, 0xe0...0xff, MPFormat.nilByte, MPFormat.falseByte, MPFormat.trueByte:
                return nil
            case 0xa0...0xbf:
                return self.skipBytes(Int(format & 0x1f))
            case 0x90...0x9f:
                return self.skipElements(Int(format & 0x0f), depth: depth)
            case 0x80...0x8f:
                return self.skipElements(2 * Int(format & 0x0f), depth: depth)
            case MPFormat.uint8, MPFormat.int8:
                return self.skipBytes(1)
            case MPFormat.uint16, MPFormat.int16:
                return self.skipBytes(2)
            case MPFormat.uint32, MPFormat.int32, MPFormat.float32:
                return self.skipBytes(4)
            case MPFormat.uint64, MPFormat.int64, MPFormat.float64:
                return self.skipBytes(8)
            case MPFormat.str8, MPFormat.bin8:
                return self.skipSized(UInt8.self)
            case MPFormat.str16, MPFormat.bin16:
                return self.skipSized(UInt16.self)
            case MPFormat.str32, MPFormat.bin32:
                return self.skipSized(UInt32.self)
            case MPFormat.fixext1:
                return self.skipBytes(2)
            case MPFormat.fixext2:
                return self.skipBytes(3)
            case MPFormat.fixext4:
                return self.skipBytes(5)
            case MPFormat.fixext8:
                return self.skipBytes(9)
            case MPFormat.fixext16:
                return self.skipBytes(17)
            case MPFormat.ext8:
                return self.skipSized(UInt8.self, plus: 1)
            case MPFormat.ext16:
                return self.skipSized(UInt16.self, plus: 1)
            case MPFormat.ext32:
                return self.skipSized(UInt32.self, plus: 1)
            case MPFormat.array16:
                return self.skipContainer(UInt16.self, valuesPerEntry: 1, depth: depth)
            case MPFormat.array32:
                return self.skipContainer(UInt32.self, valuesPerEntry: 1, depth: depth)
            case MPFormat.map16:
                return self.skipContainer(UInt16.self, valuesPerEntry: 2, depth: depth)
            case MPFormat.map32:
                return self.skipContainer(UInt32.self, valuesPerEntry: 2, depth: depth)
            default:
                // Only 0xc1 (never used) reaches here.
                return .invalidFormat(format)
        }
    }

    /// Steps over the `count` values of a container that sits at `depth`.
    private mutating func skipElements(_ count: Int, depth: Int) -> Failure? {
        guard depth < self.cap else { return .nestingTooDeep }
        for _ in 0..<count {
            // Most elements are one byte, or a string short enough for a
            // fixstr: those are stepped over here, without a call.
            if self.offset < self.bytes.count {
                let format = self.bytes[self.offset]
                if format <= 0x7f || format >= 0xe0 {
                    self.offset += 1
                    continue
                }
                let length = Int(format & 0x1f)
                if format & 0xe0 == 0xa0, self.bytes.count - self.offset > length {
                    self.offset += 1 + length
                    continue
                }
            }
            if let failure = self.skipValue(depth: depth + 1) {
                return failure
            }
        }
        return nil
    }

    /// Steps over a string, binary or ext value's bytes, `extra` more than
    /// its length says (an ext value's type byte).
    private mutating func skipSized<Length: FixedWidthInteger & UnsignedInteger>(
        _ type: Length.Type,
        plus extra: Int = 0
    ) -> Failure? {
        guard let length = self.readLength(Length.self) else { return .truncated }
        return self.skipBytes(length + extra)
    }

    /// Steps over an array (one value per entry) or a map (two) whose count
    /// is a `Count`.
    private mutating func skipContainer<Count: FixedWidthInteger & UnsignedInteger>(
        _ type: Count.Type,
        valuesPerEntry: Int,
        depth: Int
    ) -> Failure? {
        guard let count = self.readLength(Count.self) else { return .truncated }
        return self.skipElements(valuesPerEntry * count, depth: depth)
    }

    private mutating func skipBytes(_ count: Int) -> Failure? {
        guard self.bytes.count - self.offset >= count else { return .truncated }
        self.offset += count
        return nil
    }

    /// Reads a big-endian length or count; nil, without moving, when its
    /// bytes are not all there.
    private mutating func readLength<Length: FixedWidthInteger & UnsignedInteger>(
        _ type: Length.Type
    ) -> Int? {
        let width = MemoryLayout<Length>.size
        guard self.bytes.count - self.offset >= width else { return nil }
        let raw = self.bytes.loadUnaligned(fromByteOffset: self.offset, as: Length.self)
        self.offset += width
        return Int(Length(bigEndian: raw))
    }
}

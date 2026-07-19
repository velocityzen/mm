import NIOCore

/// An ext value read as an opaque pass-through: type tag plus raw payload slice.
public struct MMPackExtValue: Equatable, Sendable {
    public var type: Int8
    public var payload: ByteBuffer

    public init(type: Int8, payload: ByteBuffer) {
        self.type = type
        self.payload = payload
    }
}

/// MessagePack value readers over `ByteBuffer`.
///
/// Readers are tolerant of non-canonical input: a value encoded wider than necessary
/// decodes, and integers decode across signedness when representable in the target type.
/// On failure the reader index is restored to where it was before the call.
extension ByteBuffer {
    /// Non-consuming peek at the next MessagePack format byte; `nil` if no bytes are readable.
    public func peekMessagePackFormat() -> UInt8? {
        self.peekInteger(as: UInt8.self)
    }

    /// Consumes a `nil` value.
    public mutating func readMessagePackNil() -> Result<Void, MMWireError> {
        guard let format = self.peekMessagePackFormat() else { return .failure(.truncated) }
        guard format == MPFormat.nilByte else {
            return .failure(.typeMismatch(expected: "nil", format: format))
        }
        self.moveReaderIndex(forwardBy: 1)
        return .success(())
    }

    public mutating func readMessagePackBool() -> Result<Bool, MMWireError> {
        guard let format = self.peekMessagePackFormat() else { return .failure(.truncated) }
        switch format {
            case MPFormat.trueByte:
                self.moveReaderIndex(forwardBy: 1)
                return .success(true)
            case MPFormat.falseByte:
                self.moveReaderIndex(forwardBy: 1)
                return .success(false)
            default:
                return .failure(.typeMismatch(expected: "bool", format: format))
        }
    }

    /// Reads any integer-family value representable in `Int64` (including unsigned formats).
    public mutating func readMessagePackInt() -> Result<Int64, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let result: Result<Int64, MMWireError>
        switch format {
            case 0x00...0x7f:
                result = .success(Int64(format))
            case 0xe0...0xff:
                result = .success(Int64(Int8(bitPattern: format)))
            case MPFormat.uint8:
                result = self.readFixedInteger(UInt8.self).map { Int64($0) }
            case MPFormat.uint16:
                result = self.readFixedInteger(UInt16.self).map { Int64($0) }
            case MPFormat.uint32:
                result = self.readFixedInteger(UInt32.self).map { Int64($0) }
            case MPFormat.uint64:
                result = self.readFixedInteger(UInt64.self).flatMap { value in
                    guard let narrowed = Int64(exactly: value) else {
                        return .failure(.numberOutOfRange(target: "Int64"))
                    }
                    return .success(narrowed)
                }
            case MPFormat.int8:
                result = self.readFixedInteger(Int8.self).map { Int64($0) }
            case MPFormat.int16:
                result = self.readFixedInteger(Int16.self).map { Int64($0) }
            case MPFormat.int32:
                result = self.readFixedInteger(Int32.self).map { Int64($0) }
            case MPFormat.int64:
                result = self.readFixedInteger(Int64.self)
            default:
                result = .failure(.typeMismatch(expected: "integer", format: format))
        }
        if case .failure = result { self.moveReaderIndex(to: start) }
        return result
    }

    /// Reads any non-negative integer-family value (including signed formats).
    public mutating func readMessagePackUInt() -> Result<UInt64, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let result: Result<UInt64, MMWireError>
        switch format {
            case 0x00...0x7f:
                result = .success(UInt64(format))
            case 0xe0...0xff:
                result = .failure(.numberOutOfRange(target: "UInt64"))
            case MPFormat.uint8:
                result = self.readFixedInteger(UInt8.self).map { UInt64($0) }
            case MPFormat.uint16:
                result = self.readFixedInteger(UInt16.self).map { UInt64($0) }
            case MPFormat.uint32:
                result = self.readFixedInteger(UInt32.self).map { UInt64($0) }
            case MPFormat.uint64:
                result = self.readFixedInteger(UInt64.self)
            case MPFormat.int8:
                result = self.readFixedInteger(Int8.self).flatMap(Self.nonNegative)
            case MPFormat.int16:
                result = self.readFixedInteger(Int16.self).flatMap(Self.nonNegative)
            case MPFormat.int32:
                result = self.readFixedInteger(Int32.self).flatMap(Self.nonNegative)
            case MPFormat.int64:
                result = self.readFixedInteger(Int64.self).flatMap(Self.nonNegative)
            default:
                result = .failure(.typeMismatch(expected: "integer", format: format))
        }
        if case .failure = result { self.moveReaderIndex(to: start) }
        return result
    }

    /// Reads a `float32` or `float64` value as `Double` (widening is exact).
    public mutating func readMessagePackDouble() -> Result<Double, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let result: Result<Double, MMWireError>
        switch format {
            case MPFormat.float32:
                result = self.readFixedInteger(UInt32.self).map { Double(Float(bitPattern: $0)) }
            case MPFormat.float64:
                result = self.readFixedInteger(UInt64.self).map { Double(bitPattern: $0) }
            default:
                result = .failure(.typeMismatch(expected: "float", format: format))
        }
        if case .failure = result { self.moveReaderIndex(to: start) }
        return result
    }

    /// Reads a `float32` value, or a `float64` value when it is exactly representable as `Float`.
    public mutating func readMessagePackFloat() -> Result<Float, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let result: Result<Float, MMWireError>
        switch format {
            case MPFormat.float32:
                result = self.readFixedInteger(UInt32.self).map { Float(bitPattern: $0) }
            case MPFormat.float64:
                result = self.readFixedInteger(UInt64.self).flatMap { bits in
                    let wide = Double(bitPattern: bits)
                    if wide.isNaN { return .success(Float(wide)) }
                    guard let narrowed = Float(exactly: wide) else {
                        return .failure(.numberOutOfRange(target: "Float"))
                    }
                    return .success(narrowed)
                }
            default:
                result = .failure(.typeMismatch(expected: "float", format: format))
        }
        if case .failure = result { self.moveReaderIndex(to: start) }
        return result
    }

    /// Reads a str-family value as `String`, validating UTF-8. This is the one unavoidable copy.
    public mutating func readMessagePackString() -> Result<String, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let lengthResult: Result<Int, MMWireError>
        switch format {
            case 0xa0...0xbf:
                lengthResult = .success(Int(format & 0x1f))
            case MPFormat.str8:
                lengthResult = self.readFixedInteger(UInt8.self).map { Int($0) }
            case MPFormat.str16:
                lengthResult = self.readFixedInteger(UInt16.self).map { Int($0) }
            case MPFormat.str32:
                lengthResult = self.readFixedInteger(UInt32.self).map { Int($0) }
            default:
                self.moveReaderIndex(to: start)
                return .failure(.typeMismatch(expected: "str", format: format))
        }
        switch lengthResult {
            case .failure(let error):
                self.moveReaderIndex(to: start)
                return .failure(error)
            case .success(let length):
                guard self.readableBytes >= length else {
                    self.moveReaderIndex(to: start)
                    return .failure(.truncated)
                }
                // Single pass: SE-0405 validates strictly (overlongs,
                // surrogates, > U+10FFFF all rejected) while building the
                // string; nil leaves the bytes unconsumed.
                guard
                    let string = String(
                        validating: self.readableBytesView.prefix(length), as: UTF8.self)
                else {
                    self.moveReaderIndex(to: start)
                    return .failure(.invalidUTF8)
                }
                self.moveReaderIndex(forwardBy: length)
                return .success(string)
        }
    }

    /// Reads a bin-family or str-family payload as a zero-copy `ByteBuffer` slice.
    /// No UTF-8 validation is performed.
    public mutating func readMessagePackBinary() -> Result<ByteBuffer, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let lengthResult: Result<Int, MMWireError>
        switch format {
            case 0xa0...0xbf:
                lengthResult = .success(Int(format & 0x1f))
            case MPFormat.bin8, MPFormat.str8:
                lengthResult = self.readFixedInteger(UInt8.self).map { Int($0) }
            case MPFormat.bin16, MPFormat.str16:
                lengthResult = self.readFixedInteger(UInt16.self).map { Int($0) }
            case MPFormat.bin32, MPFormat.str32:
                lengthResult = self.readFixedInteger(UInt32.self).map { Int($0) }
            default:
                self.moveReaderIndex(to: start)
                return .failure(.typeMismatch(expected: "bin", format: format))
        }
        switch lengthResult {
            case .failure(let error):
                self.moveReaderIndex(to: start)
                return .failure(error)
            case .success(let length):
                guard let slice = self.readSlice(length: length) else {
                    self.moveReaderIndex(to: start)
                    return .failure(.truncated)
                }
                return .success(slice)
        }
    }

    /// Reads an array header; the caller then reads that many values.
    public mutating func readMessagePackArrayHeader() -> Result<Int, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let result: Result<Int, MMWireError>
        switch format {
            case 0x90...0x9f:
                result = .success(Int(format & 0x0f))
            case MPFormat.array16:
                result = self.readFixedInteger(UInt16.self).map { Int($0) }
            case MPFormat.array32:
                result = self.readFixedInteger(UInt32.self).map { Int($0) }
            default:
                result = .failure(.typeMismatch(expected: "array", format: format))
        }
        if case .failure = result { self.moveReaderIndex(to: start) }
        return result
    }

    /// Reads a map header; the caller then reads that many key-value pairs.
    public mutating func readMessagePackMapHeader() -> Result<Int, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let result: Result<Int, MMWireError>
        switch format {
            case 0x80...0x8f:
                result = .success(Int(format & 0x0f))
            case MPFormat.map16:
                result = self.readFixedInteger(UInt16.self).map { Int($0) }
            case MPFormat.map32:
                result = self.readFixedInteger(UInt32.self).map { Int($0) }
            default:
                result = .failure(.typeMismatch(expected: "map", format: format))
        }
        if case .failure = result { self.moveReaderIndex(to: start) }
        return result
    }

    /// Reads any ext-family value as an opaque type tag plus zero-copy payload slice.
    public mutating func readMessagePackExt() -> Result<MMPackExtValue, MMWireError> {
        let start = self.readerIndex
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        let lengthResult: Result<Int, MMWireError>
        switch format {
            case MPFormat.fixext1: lengthResult = .success(1)
            case MPFormat.fixext2: lengthResult = .success(2)
            case MPFormat.fixext4: lengthResult = .success(4)
            case MPFormat.fixext8: lengthResult = .success(8)
            case MPFormat.fixext16: lengthResult = .success(16)
            case MPFormat.ext8:
                lengthResult = self.readFixedInteger(UInt8.self).map { Int($0) }
            case MPFormat.ext16:
                lengthResult = self.readFixedInteger(UInt16.self).map { Int($0) }
            case MPFormat.ext32:
                lengthResult = self.readFixedInteger(UInt32.self).map { Int($0) }
            default:
                self.moveReaderIndex(to: start)
                return .failure(.typeMismatch(expected: "ext", format: format))
        }
        switch lengthResult {
            case .failure(let error):
                self.moveReaderIndex(to: start)
                return .failure(error)
            case .success(let length):
                guard let typeByte = self.readInteger(as: Int8.self),
                    let payload = self.readSlice(length: length)
                else {
                    self.moveReaderIndex(to: start)
                    return .failure(.truncated)
                }
                return .success(MMPackExtValue(type: typeByte, payload: payload))
        }
    }

    /// Structurally skips one MessagePack value of any family, including nested containers
    /// and ext values, without materializing it. Nesting beyond `maxDepth` container levels
    /// fails with `.nestingTooDeep` — never a crash or a hang.
    /// On failure the reader index is restored.
    public mutating func skipMessagePackValue(maxDepth: Int = 128) -> Result<Void, MMWireError> {
        let start = self.readerIndex
        let result = self.skipMessagePackValue(currentDepth: 0, cap: maxDepth)
        if case .failure = result { self.moveReaderIndex(to: start) }
        return result
    }

    /// Skip with explicit depth accounting: the value being skipped sits at container
    /// nesting level `currentDepth` (0 for a top-level value).
    mutating func skipMessagePackValue(currentDepth: Int, cap: Int) -> Result<Void, MMWireError> {
        guard let format = self.readInteger(as: UInt8.self) else { return .failure(.truncated) }
        switch format {
            case 0x00...0x7f, 0xe0...0xff, MPFormat.nilByte, MPFormat.falseByte, MPFormat.trueByte:
                return .success(())
            case MPFormat.uint8, MPFormat.int8:
                return self.skipRawBytes(1)
            case MPFormat.uint16, MPFormat.int16:
                return self.skipRawBytes(2)
            case MPFormat.uint32, MPFormat.int32, MPFormat.float32:
                return self.skipRawBytes(4)
            case MPFormat.uint64, MPFormat.int64, MPFormat.float64:
                return self.skipRawBytes(8)
            case 0xa0...0xbf:
                return self.skipRawBytes(Int(format & 0x1f))
            case MPFormat.str8, MPFormat.bin8:
                return self.readFixedInteger(UInt8.self).flatMap { self.skipRawBytes(Int($0)) }
            case MPFormat.str16, MPFormat.bin16:
                return self.readFixedInteger(UInt16.self).flatMap { self.skipRawBytes(Int($0)) }
            case MPFormat.str32, MPFormat.bin32:
                return self.readFixedInteger(UInt32.self).flatMap { self.skipRawBytes(Int($0)) }
            case MPFormat.fixext1:
                return self.skipRawBytes(2)
            case MPFormat.fixext2:
                return self.skipRawBytes(3)
            case MPFormat.fixext4:
                return self.skipRawBytes(5)
            case MPFormat.fixext8:
                return self.skipRawBytes(9)
            case MPFormat.fixext16:
                return self.skipRawBytes(17)
            case MPFormat.ext8:
                return self.readFixedInteger(UInt8.self).flatMap { self.skipRawBytes(Int($0) + 1) }
            case MPFormat.ext16:
                return self.readFixedInteger(UInt16.self).flatMap { self.skipRawBytes(Int($0) + 1) }
            case MPFormat.ext32:
                return self.readFixedInteger(UInt32.self).flatMap { self.skipRawBytes(Int($0) + 1) }
            case 0x90...0x9f:
                return self.skipElements(
                    count: Int(format & 0x0f), containerDepth: currentDepth, cap: cap)
            case MPFormat.array16:
                return self.readFixedInteger(UInt16.self).flatMap {
                    self.skipElements(count: Int($0), containerDepth: currentDepth, cap: cap)
                }
            case MPFormat.array32:
                return self.readFixedInteger(UInt32.self).flatMap {
                    self.skipElements(count: Int($0), containerDepth: currentDepth, cap: cap)
                }
            case 0x80...0x8f:
                return self.skipElements(
                    count: 2 * Int(format & 0x0f), containerDepth: currentDepth, cap: cap)
            case MPFormat.map16:
                return self.readFixedInteger(UInt16.self).flatMap {
                    self.skipElements(count: 2 * Int($0), containerDepth: currentDepth, cap: cap)
                }
            case MPFormat.map32:
                return self.readFixedInteger(UInt32.self).flatMap {
                    self.skipElements(count: 2 * Int($0), containerDepth: currentDepth, cap: cap)
                }
            default:
                // Only 0xc1 (never used) reaches here.
                return .failure(.invalidFormat(byte: format))
        }
    }

    private mutating func skipElements(
        count: Int,
        containerDepth: Int,
        cap: Int
    ) -> Result<Void, MMWireError> {
        guard containerDepth < cap else { return .failure(.nestingTooDeep(limit: cap)) }
        for _ in 0..<count {
            if case .failure(let error) = self.skipMessagePackValue(
                currentDepth: containerDepth + 1, cap: cap)
            {
                return .failure(error)
            }
        }
        return .success(())
    }

    private mutating func skipRawBytes(_ count: Int) -> Result<Void, MMWireError> {
        guard self.readableBytes >= count else { return .failure(.truncated) }
        self.moveReaderIndex(forwardBy: count)
        return .success(())
    }

    private mutating func readFixedInteger<T: FixedWidthInteger>(
        _ type: T.Type
    ) -> Result<T, MMWireError> {
        guard let value = self.readInteger(as: T.self) else { return .failure(.truncated) }
        return .success(value)
    }

    private static func nonNegative<T: SignedInteger>(_ value: T) -> Result<UInt64, MMWireError> {
        guard let converted = UInt64(exactly: value) else {
            return .failure(.numberOutOfRange(target: "UInt64"))
        }
        return .success(converted)
    }
}

extension ByteBuffer {
    /// Measures one value's extent by structurally skipping a probe copy, then
    /// consumes it as a zero-copy slice — the shared core of
    /// `readMessagePackRawValueSlice(maxDepth:)` and the decoder's slot
    /// extraction. Depth accounting is relative: `currentDepth` container
    /// levels are already open; `cap` is the absolute limit.
    mutating func sliceMessagePackValue(
        currentDepth: Int, cap: Int
    ) -> Result<ByteBuffer, MMWireError> {
        var probe = self
        return probe.skipMessagePackValue(currentDepth: currentDepth, cap: cap).map { _ in
            // Force-unwrap is safe: the skip walked exactly this many
            // readable bytes of self.
            self.readSlice(length: probe.readerIndex - self.readerIndex)!
        }
    }
}

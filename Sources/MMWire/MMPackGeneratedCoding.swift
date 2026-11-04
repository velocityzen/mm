import MMSchema
import NIOCore

// The coders' path for the types the schema macros generate MessagePack code
// for (`MMPackEncodable`, `MMPackDecodable`): the generated code reads and
// writes the bytes itself, so no `Encoder`, `Decoder`, or container is made.
// The reader and writer below delegate to the primitives the `Codable` path
// uses, which is what keeps the two paths' bytes and failures the same.

extension MMPackEncoder {
    /// Encodes `value` into a fresh buffer through its generated code.
    public func encode<T: MMPackEncodable>(_ value: T) -> Result<ByteBuffer, MMWireError> {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        return self.encode(value, into: &buffer).map { buffer }
    }

    /// Encodes `value` through its generated code, appending to an existing
    /// buffer. On failure nothing is written.
    public func encode<T: MMPackEncodable>(
        _ value: T,
        into buffer: inout ByteBuffer
    ) -> Result<Void, MMWireError> {
        let start = buffer.writerIndex
        // The writer holds the only reference while encoding, so its writes
        // never copy the storage.
        var writer = MPGeneratedWriter(buffer: ByteBuffer())
        swap(&writer.buffer, &buffer)
        let result: Result<Void, MMWireError>
        do {
            try value.encode(mmPack: &writer)
            result = .success(())
        } catch let error as MMWireError {
            result = .failure(error)
        } catch {
            result = .failure(.encodingFailed(description: String(describing: error)))
        }
        swap(&writer.buffer, &buffer)
        if case .failure = result {
            buffer.moveWriterIndex(to: start)
        }
        return result
    }

    /// `encode(_:)` for values of `type`, resolved once: through the type's
    /// generated code when it has some, through `Encodable` otherwise. For
    /// generic code, which cannot pick the overload itself; the returned
    /// function costs no conformance check per call.
    public func encoding<T: Encodable & SendableMetatype>(
        _ type: T.Type
    ) -> @Sendable (T) -> Result<ByteBuffer, MMWireError> {
        guard let generated = type as? any MMPackEncodable.Type else {
            return { value in self.encode(value) }
        }
        return self.generatedEncoding(generated, as: type)
    }

    private func generatedEncoding<Generated: MMPackEncodable, T>(
        _ generated: Generated.Type,
        as type: T.Type
    ) -> @Sendable (T) -> Result<ByteBuffer, MMWireError> {
        let encode: @Sendable (Generated) -> Result<ByteBuffer, MMWireError> = { value in
            self.encode(value)
        }
        // Force cast: `Generated` is `T`, opened from its conformance.
        return encode as! @Sendable (T) -> Result<ByteBuffer, MMWireError>
    }

    /// `encode(_:)` for generic code that has nowhere to keep a resolved
    /// ``encoding(_:)``: checks for the type's generated code on each call. The
    /// check is one conformance lookup, which the runtime caches, and makes no
    /// allocation.
    public func encodeCheckingForGeneratedCode<T: Encodable & SendableMetatype>(
        _ value: T
    ) -> Result<ByteBuffer, MMWireError> {
        guard let generated = T.self as? any MMPackEncodable.Type else {
            return self.encode(value)
        }
        return self.encodeGenerated(value, as: generated)
    }

    private func encodeGenerated<T, Generated: MMPackEncodable>(
        _ value: T,
        as _: Generated.Type
    ) -> Result<ByteBuffer, MMWireError> {
        // Force cast: `Generated` is `T`, opened from its conformance.
        self.encode(value as! Generated)
    }
}

extension MMPackDecoder {
    /// Decodes one value of `type` from the start of `buffer` through its
    /// generated code. Trailing bytes are ignored.
    public func decode<T: MMPackDecodable>(
        _ type: T.Type,
        from buffer: ByteBuffer
    ) -> Result<T, MMWireError> {
        var reader = MPGeneratedReader(buffer: buffer, cap: self.maxDepth)
        do {
            return .success(try T(mmPack: &reader, depth: 0))
        } catch let error as MMWireError {
            return .failure(error)
        } catch {
            return .failure(.decodingFailed(description: String(describing: error)))
        }
    }

    /// `decode(_:from:)` for `type`, resolved once: through the type's
    /// generated code when it has some, through `Decodable` otherwise. For
    /// generic code, which cannot pick the overload itself; the returned
    /// function costs no conformance check per call.
    public func decoding<T: Decodable & SendableMetatype>(
        _ type: T.Type
    ) -> @Sendable (ByteBuffer) -> Result<T, MMWireError> {
        guard let generated = type as? any MMPackDecodable.Type else {
            return { buffer in self.decode(type, from: buffer) }
        }
        return self.generatedDecoding(generated, as: type)
    }

    private func generatedDecoding<Generated: MMPackDecodable, T>(
        _ generated: Generated.Type,
        as type: T.Type
    ) -> @Sendable (ByteBuffer) -> Result<T, MMWireError> {
        let decode: @Sendable (ByteBuffer) -> Result<Generated, MMWireError> = { buffer in
            self.decode(Generated.self, from: buffer)
        }
        // Force cast: `Generated` is `T`, opened from its conformance.
        return decode as! @Sendable (ByteBuffer) -> Result<T, MMWireError>
    }

    /// `decode(_:from:)` for generic code that has nowhere to keep a resolved
    /// ``decoding(_:)``: checks for the type's generated code on each call. The
    /// check is one conformance lookup, which the runtime caches, and makes no
    /// allocation.
    public func decodeCheckingForGeneratedCode<T: Decodable & SendableMetatype>(
        _ type: T.Type,
        from buffer: ByteBuffer
    ) -> Result<T, MMWireError> {
        guard let generated = type as? any MMPackDecodable.Type else {
            return self.decode(type, from: buffer)
        }
        return self.decodeGenerated(generated, as: type, from: buffer)
    }

    private func decodeGenerated<Generated: MMPackDecodable, T>(
        _ generated: Generated.Type,
        as _: T.Type,
        from buffer: ByteBuffer
    ) -> Result<T, MMWireError> {
        // Force cast: `Generated` is `T`, opened from its conformance.
        self.decode(generated, from: buffer).map { $0 as! T }
    }
}

/// The writer generated code writes through: the encode's output buffer,
/// written with the primitives `MMPackEncoder` writes with.
struct MPGeneratedWriter: MMPackWriter {
    var buffer: ByteBuffer

    mutating func writeNil() {
        self.buffer.writeMessagePackNil()
    }

    mutating func writeBool(_ value: Bool) {
        self.buffer.writeMessagePackBool(value)
    }

    mutating func writeInt(_ value: Int) {
        self.buffer.writeMessagePackInt(Int64(value))
    }

    mutating func writeUInt(_ value: UInt64) {
        self.buffer.writeMessagePackUInt(value)
    }

    mutating func writeFloat(_ value: Float) {
        self.buffer.writeMessagePackFloat(value)
    }

    mutating func writeDouble(_ value: Double) {
        self.buffer.writeMessagePackDouble(value)
    }

    mutating func writeString(_ value: String) {
        self.buffer.writeMessagePackString(value)
    }

    mutating func writeBytes(_ value: MMBytes) {
        self.buffer.writeMessagePackBinary(bytes: value.bytes)
    }

    mutating func writeDate(_ value: MMDate) {
        self.buffer.writeMessagePackBinary(bytes: MMVPTS(value).encoded())
    }

    mutating func writeDateTime(_ value: MMDateTime) {
        self.buffer.writeMessagePackBinary(bytes: MMVPTS(value).encoded())
    }

    mutating func writeTimestamp(_ value: MMTimestamp) {
        self.buffer.writeMessagePackBinary(bytes: MMVPTS(value).encoded())
    }

    mutating func writeArrayHeader(count: Int) {
        self.buffer.writeMessagePackArrayHeader(count: count)
    }

    mutating func writeMapHeader(count: Int) {
        self.buffer.writeMessagePackMapHeader(count: count)
    }

    mutating func writeEncodable<Value: Encodable>(_ value: Value) throws {
        try MMPackEncoder().encode(value, into: &self.buffer).get()
    }
}

/// The reader generated code reads through: a cursor over the payload and the
/// decode's nesting limit, read with the primitives `MMPackDecoder` reads with.
struct MPGeneratedReader: MMPackReader {
    var buffer: ByteBuffer
    let cap: Int

    var position: Int { self.buffer.readerIndex }

    mutating func seek(to position: Int) {
        self.buffer.moveReaderIndex(to: position)
    }

    mutating func seek(toRequiredField position: Int?, key: Int) throws {
        guard let position else { throw MMWireError.keyNotFound(key: String(key)) }
        self.buffer.moveReaderIndex(to: position)
    }

    mutating func readNil() -> Bool {
        guard self.buffer.peekMessagePackFormat() == MPFormat.nilByte else { return false }
        self.buffer.moveReaderIndex(forwardBy: 1)
        return true
    }

    mutating func readBool() throws -> Bool {
        try self.buffer.readMessagePackBool().get()
    }

    mutating func readInt() throws -> Int {
        try mpReadInteger(Int.self, from: &self.buffer)
    }

    mutating func readUInt() throws -> UInt64 {
        try mpReadInteger(UInt64.self, from: &self.buffer)
    }

    mutating func readFloat() throws -> Float {
        try self.buffer.readMessagePackFloat().get()
    }

    mutating func readDouble() throws -> Double {
        try self.buffer.readMessagePackDouble().get()
    }

    mutating func readString() throws -> String {
        try self.buffer.readMessagePackString().get()
    }

    mutating func readBytes() throws -> MMBytes {
        try mpReadBytes(from: &self.buffer)
    }

    mutating func readDate() throws -> MMDate {
        try mpReadDate(from: &self.buffer)
    }

    mutating func readDateTime() throws -> MMDateTime {
        try mpReadDateTime(from: &self.buffer)
    }

    mutating func readTimestamp() throws -> MMTimestamp {
        try mpReadTimestamp(from: &self.buffer)
    }

    mutating func readArrayHeader(depth: Int) throws -> Int {
        guard depth < self.cap else { throw MMWireError.nestingTooDeep(limit: self.cap) }
        return try self.buffer.readMessagePackArrayHeader().get()
    }

    mutating func readMapHeader(depth: Int) throws -> Int {
        guard depth < self.cap else { throw MMWireError.nestingTooDeep(limit: self.cap) }
        return try self.buffer.readMessagePackMapHeader().get()
    }

    mutating func readMapKey(depth: Int) throws -> MMPackMapKey {
        try MPDecodingState.readMapKey(from: &self.buffer, keyDepth: depth, cap: self.cap)
    }

    mutating func skipValue(depth: Int) throws {
        try self.buffer.skipMessagePackValue(currentDepth: depth, cap: self.cap).get()
    }

    /// Decodes from the value's exact slice, as a keyed container hands one
    /// to `Decodable`, so the conformance cannot read past its value.
    mutating func readDecodable<Value: Decodable>(_ type: Value.Type, depth: Int) throws -> Value {
        let slice = try self.buffer.sliceMessagePackValue(currentDepth: depth, cap: self.cap).get()
        return try MPDecodingState.decode(type, from: slice, depth: depth, cap: self.cap)
    }
}

/// Writes MessagePack, the wire's payload format, for the code the schema
/// macros generate. MMWire implements it over its output buffer; it is
/// declared here because schema modules see only MMSchema.
///
/// Each method writes the bytes `MMPackEncoder` writes for the same value, so
/// a type's generated code and its `Encodable` conformance agree byte for byte.
public protocol MMPackWriter {
    mutating func writeNil()
    mutating func writeBool(_ value: Bool)
    mutating func writeInt(_ value: Int)
    mutating func writeUInt(_ value: UInt64)
    mutating func writeFloat(_ value: Float)
    mutating func writeDouble(_ value: Double)
    mutating func writeString(_ value: String)
    /// Writes a `bin` holding the bytes.
    mutating func writeBytes(_ value: MMBytes)
    /// Writes a `bin` holding the value's VPTS encoding, as for every wire time kind.
    mutating func writeDate(_ value: MMDate)
    mutating func writeDateTime(_ value: MMDateTime)
    mutating func writeTimestamp(_ value: MMTimestamp)
    /// Writes a `bin` holding the duration's binary encoding.
    mutating func writeDuration(_ value: MMDuration)
    /// Writes a `bin` holding the identifier's 16 bytes.
    mutating func writeUUID(_ value: MMUUID)
    /// Writes the smallest array header for `count`; the caller writes the elements.
    mutating func writeArrayHeader(count: Int)
    /// Writes the smallest map header for `count`; the caller writes the entries.
    mutating func writeMapHeader(count: Int)
    /// Writes the value's bytes as they are.
    mutating func writeRawValue(_ value: MMPackRawValue)
    /// Writes `value` through its `Encodable` conformance: the path for the
    /// types the macros generate no code for (maps and external types).
    mutating func writeEncodable<Value: Encodable>(_ value: Value) throws
}

/// Reads MessagePack payloads for the code the schema macros generate. MMWire
/// implements it over the payload's bytes.
///
/// Each read accepts what `MMPackDecoder` accepts and fails where it fails, so
/// a type's generated code and its `Decodable` conformance agree. A `depth` is
/// a container nesting level, as in `MMPackDecoder`: a container at `depth`
/// fails with `nestingTooDeep` unless `depth` is below the decode's limit.
public protocol MMPackReader {
    /// Where the next value starts.
    var position: Int { get }
    /// Moves to `position`, which this reader reported.
    mutating func seek(to position: Int)
    /// Moves to a required field's value, or fails the way `MMPackDecoder`
    /// fails for a missing key when `position` is nil.
    mutating func seek(toRequiredField position: Int?, key: Int) throws
    /// Consumes a nil and returns true; anything else is left unread.
    mutating func readNil() -> Bool
    mutating func readBool() throws -> Bool
    mutating func readInt() throws -> Int
    mutating func readUInt() throws -> UInt64
    mutating func readFloat() throws -> Float
    mutating func readDouble() throws -> Double
    mutating func readString() throws -> String
    /// Reads a `bin`, or a `str` as its UTF-8 bytes, as `MMPackDecoder` reads
    /// an ``MMBytes``.
    mutating func readBytes() throws -> MMBytes
    /// Reads a `bin` holding a VPTS encoding of the kind's precision; a null
    /// VPTS fails, as wherever a value is required.
    mutating func readDate() throws -> MMDate
    mutating func readDateTime() throws -> MMDateTime
    mutating func readTimestamp() throws -> MMTimestamp
    /// Reads a `bin` holding a duration's canonical binary encoding.
    mutating func readDuration() throws -> MMDuration
    /// Reads a `bin` holding exactly 16 bytes as an identifier.
    mutating func readUUID() throws -> MMUUID
    mutating func readArrayHeader(depth: Int) throws -> Int
    mutating func readMapHeader(depth: Int) throws -> Int
    /// Reads one map key. `depth` is the key's own level: the map's plus one.
    mutating func readMapKey(depth: Int) throws -> MMPackMapKey
    /// Steps over one value, checking its structure and nesting.
    mutating func skipValue(depth: Int) throws
    /// Steps over one value as ``skipValue(depth:)`` does, and returns its
    /// bytes.
    mutating func readRawValue(depth: Int) throws -> MMPackRawValue
    /// Reads `type` through its `Decodable` conformance: the path for the
    /// types the macros generate no code for (maps and external types).
    mutating func readDecodable<Value: Decodable>(_ type: Value.Type, depth: Int) throws -> Value
}

/// A map key as the wire spells it.
public enum MMPackMapKey: Equatable, Sendable {
    case int(Int64)
    case string(String)
    /// A key that can never name a field (out-of-range uint64, invalid UTF-8,
    /// or a non-int/str family); consumed structurally so decoding continues.
    case unusable
}

/// A type the schema macros generated MessagePack code for, which writes the
/// bytes its `Encodable` conformance writes without going through `Encoder`.
/// Its metatype is sendable, so the coders can resolve the generated path once
/// and share it across tasks.
public protocol MMPackEncodable: Encodable, SendableMetatype {
    func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws
}

/// A type the schema macros generated MessagePack code for, which decodes
/// what its `Decodable` conformance decodes without going through `Decoder`.
/// Its metatype is sendable, so the coders can resolve the generated path once
/// and share it across tasks.
public protocol MMPackDecodable: Decodable, SendableMetatype {
    /// Decodes the value at the reader's position, sitting at `depth`, and
    /// leaves the reader just past it.
    init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws
}

public typealias MMPackCodable = MMPackEncodable & MMPackDecodable

// A part declared as `.optional(...)` around a named type has `X?` as its
// payload. These keep it on the generated path: nil, or the wrapped value
// through its own generated code, the bytes `Optional`'s `Codable`
// conformance writes through the coders.

extension Optional: MMPackEncodable where Wrapped: MMPackEncodable {
    @inlinable
    public func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {
        try writer.writeOptional(self) { writer, value in try value.encode(mmPack: &writer) }
    }
}

extension Optional: MMPackDecodable where Wrapped: MMPackDecodable {
    /// The wrapped value sits at the optional's own depth, as with
    /// `Decodable`.
    @inlinable
    public init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {
        self = try reader.readOptional { reader in try Wrapped(mmPack: &reader, depth: depth) }
    }
}

// The shapes generated code composes, inlinable so they specialize into it.

extension MMPackWriter {
    /// Writes nil, or the wrapped value through `writeWrapped`.
    @inlinable
    public mutating func writeOptional<Wrapped>(
        _ value: Wrapped?,
        _ writeWrapped: (inout Self, Wrapped) throws -> Void
    ) rethrows {
        guard let value else { return self.writeNil() }
        try writeWrapped(&self, value)
    }

    /// Writes the array header, then each element through `writeElement`.
    @inlinable
    public mutating func writeArray<Element>(
        _ elements: [Element],
        _ writeElement: (inout Self, Element) throws -> Void
    ) rethrows {
        self.writeArrayHeader(count: elements.count)
        for element in elements {
            try writeElement(&self, element)
        }
    }

    /// Writes a value of an external type through its generated code.
    @inlinable
    public mutating func write<Value: MMPackEncodable>(_ value: Value) throws {
        try value.encode(mmPack: &self)
    }

    /// Writes a value of an external type that has no generated code.
    @inlinable
    public mutating func write<Value: Encodable>(_ value: Value) throws {
        try self.writeEncodable(value)
    }
}

extension MMPackReader {
    /// Reads nil, or the wrapped value through `readWrapped`. The wrapped
    /// value sits at the optional's own depth.
    @inlinable
    public mutating func readOptional<Wrapped>(
        _ readWrapped: (inout Self) throws -> Wrapped
    ) rethrows -> Wrapped? {
        if self.readNil() { return nil }
        return try readWrapped(&self)
    }

    /// Reads the array header at `depth`, then each element through
    /// `readElement`; the elements sit at `depth + 1`.
    @inlinable
    public mutating func readArray<Element>(
        depth: Int,
        _ readElement: (inout Self) throws -> Element
    ) throws -> [Element] {
        let count = try self.readArrayHeader(depth: depth)
        var elements: [Element] = []
        // Never trust a wire-supplied count for allocation sizing beyond this.
        elements.reserveCapacity(Swift.min(count, 64))
        for _ in 0..<count {
            elements.append(try readElement(&self))
        }
        return elements
    }

    /// Reads the next key of a map that has `remaining` entries left, and
    /// counts it off; nil once none is left. The key sits at `depth`.
    @inlinable
    public mutating func readMapKey(remaining: inout Int, depth: Int) throws -> MMPackMapKey? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        return try self.readMapKey(depth: depth)
    }

    /// Reads a value of an external type through its generated code.
    @inlinable
    public mutating func read<Value: MMPackDecodable>(
        _ type: Value.Type,
        depth: Int
    ) throws -> Value {
        try Value(mmPack: &self, depth: depth)
    }

    /// Reads a value of an external type that has no generated code.
    @inlinable
    public mutating func read<Value: Decodable>(_ type: Value.Type, depth: Int) throws -> Value {
        try self.readDecodable(type, depth: depth)
    }

    /// Reads the value under `key` through `readValue`. A `DecodingError`
    /// it throws gets `key` in front of its coding path, as through
    /// `Decodable`, where each keyed container adds its key: so the error
    /// names the fields leading to the failure from the decoded value
    /// down. Only a `Decodable` conformance throws one, which reads with a
    /// path starting at its own value; a read that succeeds costs nothing
    /// more.
    @inlinable
    public mutating func readField<Key: CodingKey, Value>(
        _ key: Key,
        _ readValue: (inout Self) throws -> Value
    ) throws -> Value {
        do {
            return try readValue(&self)
        } catch let error as DecodingError {
            throw error.underKey(key)
        }
    }

    /// Reads a field's value through `readValue`, on a map's first, in-order
    /// path, and notes in `noted` where the value sits and what reading it
    /// gave: the value, or the error it failed with.
    @inlinable
    public mutating func readNoting<Value>(
        _ noted: inout MMPackFieldRead<Value>?,
        _ readValue: (inout Self) throws -> Value
    ) throws -> Value {
        let position = self.position
        do {
            let value = try readValue(&self)
            noted = MMPackFieldRead(position: position, result: .success(value))
            return value
        } catch {
            noted = MMPackFieldRead(position: position, result: .failure(error))
            throw error
        }
    }

    /// Reads a field's value at the reader's position through `readValue`,
    /// on a map's walk-first path; or, when `noted` holds what the first path
    /// read there, gives that value, or throws the error it failed with,
    /// and leaves the reader where it is: the walk-first path moves to each
    /// field, and past the map at its end.
    @inlinable
    public mutating func readUnlessNoted<Value>(
        _ noted: MMPackFieldRead<Value>?,
        _ readValue: (inout Self) throws -> Value
    ) throws -> Value {
        if let noted, noted.position == self.position {
            return try noted.result.get()
        }
        return try readValue(&self)
    }
}

/// What a field's read gave on a map's first, in-order path, and where the
/// value sits. The generated code decodes a map on a second, walk-first path
/// when its keys come out of order or the first path fails, and takes this
/// outcome there instead of reading the value again: reading again would
/// decode a value nested in n such maps up to 2^n times.
public struct MMPackFieldRead<Value> {
    @usableFromInline
    let position: Int
    @usableFromInline
    let result: Result<Value, any Error>

    @usableFromInline
    init(position: Int, result: Result<Value, any Error>) {
        self.position = position
        self.result = result
    }
}

extension DecodingError {
    /// The same error with `key` in front of its coding path.
    @usableFromInline
    func underKey(_ key: any CodingKey) -> DecodingError {
        func underKey(_ context: Context) -> Context {
            Context(
                codingPath: [key] + context.codingPath,
                debugDescription: context.debugDescription,
                underlyingError: context.underlyingError
            )
        }
        switch self {
            case .typeMismatch(let type, let context):
                return .typeMismatch(type, underKey(context))
            case .valueNotFound(let type, let context):
                return .valueNotFound(type, underKey(context))
            case .keyNotFound(let missing, let context):
                return .keyNotFound(missing, underKey(context))
            case .dataCorrupted(let context):
                return .dataCorrupted(underKey(context))
            @unknown default:
                return self
        }
    }
}

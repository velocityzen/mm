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
    /// Writes the smallest array header for `count`; the caller writes the elements.
    mutating func writeArrayHeader(count: Int)
    /// Writes the smallest map header for `count`; the caller writes the entries.
    mutating func writeMapHeader(count: Int)
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
    mutating func readArrayHeader(depth: Int) throws -> Int
    mutating func readMapHeader(depth: Int) throws -> Int
    /// Reads one map key. `depth` is the key's own level: the map's plus one.
    mutating func readMapKey(depth: Int) throws -> MMPackMapKey
    /// Steps over one value, checking its structure and nesting.
    mutating func skipValue(depth: Int) throws
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
}

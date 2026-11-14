import NIOCore

/// Whether a `Dictionary` keyed by `Key` travels as a wire map that `Codable`
/// would not write: true for an integer type other than `Int`, and for a
/// `RawRepresentable` whose raw value is `String` or an integer type. These
/// are the Swift forms of a schema map keyed by `.int`, `.uint` or an
/// enumeration (a generated enum's key schema is a reference to it), which a
/// dynamic peer such as the CLI sends and reads as a map. `Codable` writes
/// them as an array of alternating keys and values.
///
/// `String`, `Int` and `CodingKeyRepresentable` keys need nothing: `Codable`
/// writes them as map keys itself. Any other key keeps `Codable`'s array.
func mpHasWireMapKeys<Key>(_ type: Key.Type) -> Bool {
    if type is any CodingKeyRepresentable.Type {
        return false
    }
    if type is any FixedWidthInteger.Type {
        return true
    }
    guard let rawType = type as? any RawRepresentable.Type else { return false }
    return mpRawValueIsMapKey(rawType)
}

private func mpRawValueIsMapKey<Raw: RawRepresentable>(_ type: Raw.Type) -> Bool {
    Raw.RawValue.self == String.self || Raw.RawValue.self is any FixedWidthInteger.Type
}

/// A wire map key as a `CodingKey`: an integer key carries its `intValue`
/// and a text key none, so ``mpFaithfulIntKey(_:)`` writes and finds each
/// as the kind it is (the text "5" stays text).
struct MPWireMapCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// The wire map key `key` travels as: its own MessagePack encoding, which
/// must be an integer within `Int64` or text, the two kinds of key
/// ``MPDecodingState/readMapKey(from:keyDepth:cap:)`` reads. An integer key
/// skips the encoder, with the same outcome. `scratch` is reused from key
/// to key.
func mpWireMapCodingKey<Key: Encodable>(
    for key: Key,
    scratch: inout ByteBuffer
) throws -> MPWireMapCodingKey {
    if let integer = key as? any FixedWidthInteger {
        guard let exact = Int64(exactly: integer) else {
            throw MMWireError.numberOutOfRange(target: "Int64")
        }
        return MPWireMapCodingKey(intValue: Int(exact))
    }
    scratch.clear()
    try MMPackEncoder().encode(key, into: &scratch).get()
    let format = scratch.peekMessagePackFormat()
    let mapKey: MPWireMapCodingKey
    if let format, MPFormat.isInteger(format) {
        mapKey = MPWireMapCodingKey(intValue: Int(try scratch.readMessagePackInt().get()))
    } else if let format, MPFormat.isString(format) {
        mapKey = MPWireMapCodingKey(stringValue: try scratch.readMessagePackString().get())
    } else {
        throw MMWireError.encodingFailed(
            description: "a \(Key.self) map key must encode as an integer or text"
        )
    }
    guard scratch.readableBytes == 0 else {
        throw MMWireError.encodingFailed(
            description: "a \(Key.self) map key must encode as one integer or text"
        )
    }
    return mapKey
}

// MARK: - Encoding

/// A dictionary ``MMPackEncoder`` writes as a wire map when its keys are
/// ones `Codable` would write as an array; see ``mpHasWireMapKeys(_:)``.
protocol MPWireMapEncodable {
    static var hasWireMapKeys: Bool { get }
    func encodeWireMap(to encoder: MPEncoderImplementation) throws
}

extension Dictionary: MPWireMapEncodable where Key: Encodable, Value: Encodable {
    static var hasWireMapKeys: Bool { mpHasWireMapKeys(Key.self) }

    func encodeWireMap(to encoder: MPEncoderImplementation) throws {
        var container = encoder.container(keyedBy: MPWireMapCodingKey.self)
        var scratch = ByteBuffer()
        for (key, value) in self {
            try container.encode(value, forKey: mpWireMapCodingKey(for: key, scratch: &scratch))
        }
    }
}

/// Encodes `value` through `encoder`: a dictionary with wire map keys as a
/// wire map, anything else through its own `encode(to:)`.
func mpEncode<T: Encodable>(_ value: T, to encoder: MPEncoderImplementation) throws {
    if let mapType = T.self as? any MPWireMapEncodable.Type, mapType.hasWireMapKeys {
        // Guarded force cast: the conformance cast above proves the value's.
        try (value as! any MPWireMapEncodable).encodeWireMap(to: encoder)
    } else {
        try value.encode(to: encoder)
    }
}

// MARK: - Decoding

/// A dictionary ``MMPackDecoder`` reads from a wire map when its keys are
/// ones `Codable` would read from an array; see ``mpHasWireMapKeys(_:)``.
/// Such a dictionary refuses an array, as any map does.
protocol MPWireMapDecodable {
    static var hasWireMapKeys: Bool { get }
    static func decodeWireMap(from decoder: MPDecoderImplementation) throws -> Self
}

extension Dictionary: MPWireMapDecodable where Key: Decodable, Value: Decodable {
    static var hasWireMapKeys: Bool { mpHasWireMapKeys(Key.self) }

    /// Each key decodes as a value of its type from the same bytes, under
    /// the map's coding path: an integer type takes an integer key within
    /// its range, and an enum takes text naming a case (a generated enum
    /// reads any other text as `unknown`). Keys that decode to the same key
    /// keep the value of the first one read.
    static func decodeWireMap(from decoder: MPDecoderImplementation) throws -> Self {
        let container = try decoder.container(keyedBy: MPWireMapCodingKey.self)
        let codingKeys = container.allKeys
        let state = decoder.state
        let depth = state.stack[decoder.frame.index].depth
        var dictionary: Self = [:]
        // Never trust a wire-supplied count for allocation sizing beyond this.
        dictionary.reserveCapacity(Swift.min(codingKeys.count, 64))
        var scratch = ByteBuffer()
        for codingKey in codingKeys {
            scratch.clear()
            if let intKey = codingKey.intValue {
                scratch.writeMessagePackInt(Int64(intKey))
            } else {
                scratch.writeMessagePackString(codingKey.stringValue)
            }
            let key = try state.decodeValue(
                Key.self,
                from: scratch,
                depth: depth + 1,
                parent: decoder.frame.index,
                key: codingKey
            )
            guard dictionary.index(forKey: key) == nil else { continue }
            dictionary[key] = try container.decode(Value.self, forKey: codingKey)
        }
        return dictionary
    }
}

/// Decodes `type` through `decoder`: a dictionary with wire map keys from a
/// wire map, anything else through its own `init(from:)`.
func mpDecode<T: Decodable>(_ type: T.Type, from decoder: MPDecoderImplementation) throws -> T {
    if let mapType = type as? any MPWireMapDecodable.Type, mapType.hasWireMapKeys {
        // Guarded force cast: the conformance cast above proves T.
        return try mapType.decodeWireMap(from: decoder) as! T
    }
    return try T(from: decoder)
}

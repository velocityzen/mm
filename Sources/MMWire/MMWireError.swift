/// Errors produced by the MMWire layer: MessagePack coding, framing, and the envelope.
///
/// One `Sendable`, `Equatable` enum for the whole layer, per the house convention of
/// one typed error per layer with exact `Result` assertions in tests.
public enum MMWireError: Error, Equatable, Hashable, Sendable {
    /// Input ended before a complete value could be read.
    case truncated
    /// A frame length prefix exceeds the configured maximum.
    case frameTooLarge(length: UInt32, limit: UInt32)
    /// The MessagePack format byte does not match the requested type.
    case typeMismatch(expected: String, format: UInt8)
    /// A non-optional key was absent from an encoded map. `key` is the integer key's
    /// decimal representation, or the string key itself.
    case keyNotFound(key: String)
    /// Container nesting exceeded the configured cap.
    case nestingTooDeep(limit: Int)
    /// A `str` payload is not valid UTF-8.
    case invalidUTF8
    /// An integer value cannot be represented in the requested type.
    case numberOutOfRange(target: String)
    /// The reserved MessagePack format byte `0xc1` was encountered.
    case invalidFormat(byte: UInt8)
    /// The envelope kind tag was outside the known table: 0 terminal response,
    /// 1 open call, 2 credit, 3 stream item, 4 END, 5 STOP, 6 CANCEL. Every
    /// other tag — including tags wider than `Int64` — counts as unknown.
    case unknownEnvelope
    /// A wire array had the wrong number of elements. `expected` is exact for the
    /// envelope (4/4/3) and a minimum for evolution-tolerant arrays (`MMErrorObject`).
    case invalidArity(expected: Int, got: Int)
    /// The hello preamble did not begin with the `MM` magic bytes.
    case badMagic
    /// An `Encodable` conformance failed outside MMWire's control.
    case encodingFailed(description: String)
    /// A `Decodable` conformance failed outside MMWire's control.
    case decodingFailed(description: String)
}

/// One MessagePack value's exact bytes, kept as they arrived: what a
/// generated union keeps of a case its contract does not declare, so writing
/// the union again writes the fields it read.
///
/// The MessagePack coders short-circuit this type, as they do ``MMBytes``:
/// they read one value's bytes, checking its structure and nesting, and write
/// them back unchanged. Its own `Codable` (the bytes as a base64 string)
/// serves every other coder — JSON, display, tests.
///
/// The bytes must be exactly one MessagePack value; the coders write them as
/// they are.
public struct MMPackRawValue: Sendable, Hashable {
    public var bytes: [UInt8]

    public init(_ bytes: some Sequence<UInt8>) {
        self.bytes = Array(bytes)
    }
}

extension MMPackRawValue: CustomStringConvertible {
    /// The base64 text, as JSON carries it.
    public var description: String { SchemaValue.encodeBase64(self.bytes) }
}

extension MMPackRawValue: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let bytes = SchemaValue.decodeBase64(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "'\(text)' is not base64"
            )
        }
        self.bytes = bytes
    }
}

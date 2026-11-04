/// Raw bytes in a payload — the Swift type of a `.bytes` field.
///
/// On the wire a value is a MessagePack `bin`: the MessagePack coders
/// short-circuit this type, as they do the time kinds. Its own `Codable` (a
/// base64 string) serves every other coder — JSON, display, tests.
///
/// A distinct type rather than `[UInt8]`, which `Codable` encodes as an array
/// of integers: the wire form follows the type, never a field's context.
public struct MMBytes: Sendable, Hashable {
    public var bytes: [UInt8]

    public init(_ bytes: some Sequence<UInt8>) {
        self.bytes = Array(bytes)
    }

    public init() {
        self.bytes = []
    }
}

extension MMBytes: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: UInt8...) {
        self.bytes = elements
    }
}

extension MMBytes: RandomAccessCollection {
    public var startIndex: Int { self.bytes.startIndex }
    public var endIndex: Int { self.bytes.endIndex }
    public subscript(position: Int) -> UInt8 { self.bytes[position] }
}

extension MMBytes: CustomStringConvertible {
    /// The base64 text, as JSON carries it.
    public var description: String { SchemaValue.encodeBase64(self.bytes) }
}

extension MMBytes: Codable {
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

extension MMBytes: SchemaDescribable {
    public static var schema: TypeSchema { .bytes }
}

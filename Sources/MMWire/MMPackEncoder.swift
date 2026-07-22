import MMSchema
import NIOCore

/// The wire time kinds ride as MessagePack `bin` holding a VPTS encoding
/// (the VPTS article in this catalog) — a coder-level short-circuit like `ByteBuffer`'s, so
/// the types' own `Codable` (canonical ISO strings) keeps serving JSON
/// coders, display, and tests, while the wire gets the compact,
/// byte-sortable binary form. Returns nil for every other type.
func vptsBinary<T: Encodable>(for value: T) -> ByteBuffer? {
    let encoded: [UInt8]
    if let date = value as? MMDate {
        encoded = MMVPTS(date).encoded()
    } else if let dateTime = value as? MMDateTime {
        encoded = MMVPTS(dateTime).encoded()
    } else if let timestamp = value as? MMTimestamp {
        encoded = MMVPTS(timestamp).encoded()
    } else {
        return nil
    }
    return ByteBuffer(bytes: encoded)
}

/// Encodes `Encodable` values as MessagePack directly into `ByteBuffer`.
///
/// Keyed containers encode as maps with integer keys taken from `CodingKeys.intValue`;
/// keys without an `intValue` fall back to string keys. `ByteBuffer` values encode as
/// `bin`; the wire time kinds (`MMDate`, `MMDateTime`, `MMTimestamp`) encode as `bin`
/// holding their VPTS form. Scalars are written straight to bytes — no intermediate
/// `Data`, no boxing.
public struct MMPackEncoder: Sendable {
    public init() {}

    /// Encodes `value` into a fresh buffer.
    public func encode<T: Encodable>(_ value: T) -> Result<ByteBuffer, MMWireError> {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        return self.encode(value, into: &buffer).map { buffer }
    }

    /// Encodes `value`, appending to an existing buffer. On failure nothing is written.
    public func encode<T: Encodable>(
        _ value: T,
        into buffer: inout ByteBuffer
    ) -> Result<Void, MMWireError> {
        if let payload = value as? ByteBuffer {
            buffer.writeMessagePackBinary(payload)
            return .success(())
        }
        if let vpts = vptsBinary(for: value) {
            buffer.writeMessagePackBinary(vpts)
            return .success(())
        }

        let root = MPEncodedNode()
        let encoder = MPEncoderImplementation(sink: .node(root), codingPath: [])
        do {
            try value.encode(to: encoder)
        } catch let error as MMWireError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed(description: String(describing: error)))
        }
        root.write(into: &buffer)
        return .success(())
    }
}

// MARK: - Encoded value tree

/// A slot for exactly one encoded value; used for the root and for deferred
/// (`superEncoder`) positions. An unfilled node writes `nil`.
final class MPEncodedNode {
    enum Value {
        case scalar(ByteBuffer)
        case container(MPEncContainer)
    }

    var value: Value?

    func write(into out: inout ByteBuffer) {
        switch self.value {
            case .none:
                out.writeMessagePackNil()
            case .scalar(let bytes):
                out.writeImmutableBuffer(bytes)
            case .container(let container):
                container.write(into: &out)
        }
    }
}

/// An in-progress array or map. Scalar bytes (including keys) accumulate in `tail`;
/// nested containers interleave as segments so ordering is preserved. The header is
/// written at finalization time, once the element count is known.
final class MPEncContainer {
    enum Style {
        case array
        case map
    }

    enum Segment {
        case bytes(ByteBuffer)
        case child(MPEncContainer)
        case node(MPEncodedNode)
    }

    let style: Style
    var count = 0
    var segments: [Segment] = []
    var tail = ByteBuffer()

    init(style: Style) {
        self.style = style
    }

    /// Snapshot of the container's state, taken before speculatively writing an
    /// element (a map key, or an array slot) whose value encode may throw.
    struct Checkpoint {
        let count: Int
        let segmentCount: Int
        let tailWriterIndex: Int
    }

    func checkpoint() -> Checkpoint {
        Checkpoint(
            count: self.count,
            segmentCount: self.segments.count,
            tailWriterIndex: self.tail.writerIndex
        )
    }

    /// Rolls back everything appended after `checkpoint`. If a child container was
    /// opened in between, `flushTail` moved the then-current tail (committed bytes
    /// plus the speculative key) into the first appended segment; recover it as the
    /// tail before truncating, so committed bytes are preserved and only the
    /// speculative key and the partial child are discarded.
    func restore(to checkpoint: Checkpoint) {
        self.count = checkpoint.count
        if self.segments.count > checkpoint.segmentCount {
            if case .bytes(let flushed) = self.segments[checkpoint.segmentCount] {
                self.tail = flushed
            }
            self.segments.removeSubrange(checkpoint.segmentCount...)
        }
        self.tail.moveWriterIndex(to: checkpoint.tailWriterIndex)
    }

    func addChild(style: Style) -> MPEncContainer {
        self.flushTail()
        let child = MPEncContainer(style: style)
        self.segments.append(.child(child))
        return child
    }

    func addNode() -> MPEncodedNode {
        self.flushTail()
        let node = MPEncodedNode()
        self.segments.append(.node(node))
        return node
    }

    private func flushTail() {
        if self.tail.readableBytes > 0 {
            self.segments.append(.bytes(self.tail))
            self.tail = ByteBuffer()
        }
    }

    func write(into out: inout ByteBuffer) {
        switch self.style {
            case .array:
                out.writeMessagePackArrayHeader(count: self.count)
            case .map:
                out.writeMessagePackMapHeader(count: self.count)
        }
        for segment in self.segments {
            switch segment {
                case .bytes(let bytes):
                    out.writeImmutableBuffer(bytes)
                case .child(let container):
                    container.write(into: &out)
                case .node(let node):
                    node.write(into: &out)
            }
        }
        if self.tail.readableBytes > 0 {
            out.writeImmutableBuffer(self.tail)
        }
    }
}

// MARK: - Encoder

final class MPEncoderImplementation: Encoder {
    enum Sink {
        case node(MPEncodedNode)
        case container(MPEncContainer)
    }

    let sink: Sink
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    private(set) var hasEmitted = false
    private var emittedContainer: MPEncContainer?

    init(sink: Sink, codingPath: [any CodingKey]) {
        self.sink = sink
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            MPKeyedEncoding<Key>(
                container: self.containerForEmission(style: .map),
                codingPath: self.codingPath
            )
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        MPUnkeyedEncoding(
            container: self.containerForEmission(style: .array),
            codingPath: self.codingPath
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MPSingleValueEncoding(encoder: self)
    }

    /// Repeated requests for the same container style return the same container
    /// (required for class-inheritance encoding through a shared encoder).
    private func containerForEmission(style: MPEncContainer.Style) -> MPEncContainer {
        if let existing = self.emittedContainer, existing.style == style {
            return existing
        }
        precondition(!self.hasEmitted, "value already encoded through this encoder")
        self.hasEmitted = true
        let container: MPEncContainer
        switch self.sink {
            case .node(let node):
                container = MPEncContainer(style: style)
                node.value = .container(container)
            case .container(let parent):
                container = parent.addChild(style: style)
        }
        self.emittedContainer = container
        return container
    }

    func emitScalar(_ write: (inout ByteBuffer) -> Void) {
        precondition(!self.hasEmitted, "value already encoded through this encoder")
        self.hasEmitted = true
        switch self.sink {
            case .node(let node):
                var bytes = ByteBuffer()
                write(&bytes)
                node.value = .scalar(bytes)
            case .container(let parent):
                write(&parent.tail)
        }
    }
}

// MARK: - Keyed encoding container

struct MPKeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let container: MPEncContainer
    let codingPath: [any CodingKey]

    /// Integer keys from `CodingKeys.intValue`; string fallback otherwise —
    /// see ``mpFaithfulIntKey(_:)``, the rule the decoder mirrors exactly.
    private func writeKey(_ key: Key) {
        if let intKey = mpFaithfulIntKey(key) {
            self.container.tail.writeMessagePackInt(Int64(intKey))
        } else {
            self.container.tail.writeMessagePackString(key.stringValue)
        }
        self.container.count += 1
    }

    mutating func encodeNil(forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackNil()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackBool(value)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackString(value)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackDouble(value)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackFloat(value)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackInt(Int64(value))
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackInt(Int64(value))
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackInt(Int64(value))
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackInt(Int64(value))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackInt(value)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        self.writeKey(key)
        self.container.tail.writeMessagePackUInt(value)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let checkpoint = self.container.checkpoint()
        self.writeKey(key)
        if let payload = value as? ByteBuffer {
            self.container.tail.writeMessagePackBinary(payload)
            return
        }
        if let vpts = vptsBinary(for: value) {
            self.container.tail.writeMessagePackBinary(vpts)
            return
        }
        let child = MPEncoderImplementation(
            sink: .container(self.container),
            codingPath: self.codingPath + [key]
        )
        do {
            try value.encode(to: child)
        } catch {
            // Roll the speculative key (and any partial child output) back so a
            // caller that swallows the error cannot finalize a map whose count
            // includes a key with no value — structurally corrupt MessagePack.
            self.container.restore(to: checkpoint)
            throw error
        }
        if !child.hasEmitted {
            self.container.tail.writeMessagePackNil()
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        self.writeKey(key)
        return KeyedEncodingContainer(
            MPKeyedEncoding<NestedKey>(
                container: self.container.addChild(style: .map),
                codingPath: self.codingPath + [key]
            )
        )
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        self.writeKey(key)
        return MPUnkeyedEncoding(
            container: self.container.addChild(style: .array),
            codingPath: self.codingPath + [key]
        )
    }

    mutating func superEncoder() -> Encoder {
        self.container.tail.writeMessagePackString("super")
        self.container.count += 1
        return MPEncoderImplementation(
            sink: .node(self.container.addNode()), codingPath: self.codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        self.writeKey(key)
        return MPEncoderImplementation(
            sink: .node(self.container.addNode()),
            codingPath: self.codingPath + [key]
        )
    }
}

// MARK: - Unkeyed encoding container

struct MPUnkeyedEncoding: UnkeyedEncodingContainer {
    let container: MPEncContainer
    let codingPath: [any CodingKey]

    var count: Int { self.container.count }

    mutating func encodeNil() throws {
        self.container.count += 1
        self.container.tail.writeMessagePackNil()
    }

    mutating func encode(_ value: Bool) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackBool(value)
    }

    mutating func encode(_ value: String) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackString(value)
    }

    mutating func encode(_ value: Double) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackDouble(value)
    }

    mutating func encode(_ value: Float) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackFloat(value)
    }

    mutating func encode(_ value: Int) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackInt(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackInt(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackInt(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackInt(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackInt(value)
    }

    mutating func encode(_ value: UInt) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        self.container.count += 1
        self.container.tail.writeMessagePackUInt(value)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let checkpoint = self.container.checkpoint()
        self.container.count += 1
        if let payload = value as? ByteBuffer {
            self.container.tail.writeMessagePackBinary(payload)
            return
        }
        if let vpts = vptsBinary(for: value) {
            self.container.tail.writeMessagePackBinary(vpts)
            return
        }
        let child = MPEncoderImplementation(
            sink: .container(self.container), codingPath: self.codingPath)
        do {
            try value.encode(to: child)
        } catch {
            // Mirror of the keyed rollback: never leave the array's count claiming
            // an element that was not fully written.
            self.container.restore(to: checkpoint)
            throw error
        }
        if !child.hasEmitted {
            self.container.tail.writeMessagePackNil()
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        self.container.count += 1
        return KeyedEncodingContainer(
            MPKeyedEncoding<NestedKey>(
                container: self.container.addChild(style: .map),
                codingPath: self.codingPath
            )
        )
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        self.container.count += 1
        return MPUnkeyedEncoding(
            container: self.container.addChild(style: .array),
            codingPath: self.codingPath
        )
    }

    mutating func superEncoder() -> Encoder {
        self.container.count += 1
        return MPEncoderImplementation(
            sink: .node(self.container.addNode()), codingPath: self.codingPath)
    }
}

// MARK: - Single-value encoding container

struct MPSingleValueEncoding: SingleValueEncodingContainer {
    let encoder: MPEncoderImplementation
    var codingPath: [any CodingKey] { self.encoder.codingPath }

    mutating func encodeNil() throws {
        self.encoder.emitScalar { $0.writeMessagePackNil() }
    }

    mutating func encode(_ value: Bool) throws {
        self.encoder.emitScalar { $0.writeMessagePackBool(value) }
    }

    mutating func encode(_ value: String) throws {
        self.encoder.emitScalar { $0.writeMessagePackString(value) }
    }

    mutating func encode(_ value: Double) throws {
        self.encoder.emitScalar { $0.writeMessagePackDouble(value) }
    }

    mutating func encode(_ value: Float) throws {
        self.encoder.emitScalar { $0.writeMessagePackFloat(value) }
    }

    mutating func encode(_ value: Int) throws {
        self.encoder.emitScalar { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int8) throws {
        self.encoder.emitScalar { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int16) throws {
        self.encoder.emitScalar { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int32) throws {
        self.encoder.emitScalar { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int64) throws {
        self.encoder.emitScalar { $0.writeMessagePackInt(value) }
    }

    mutating func encode(_ value: UInt) throws {
        self.encoder.emitScalar { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt8) throws {
        self.encoder.emitScalar { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt16) throws {
        self.encoder.emitScalar { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt32) throws {
        self.encoder.emitScalar { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt64) throws {
        self.encoder.emitScalar { $0.writeMessagePackUInt(value) }
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let payload = value as? ByteBuffer {
            self.encoder.emitScalar { $0.writeMessagePackBinary(payload) }
            return
        }
        if let vpts = vptsBinary(for: value) {
            self.encoder.emitScalar { $0.writeMessagePackBinary(vpts) }
            return
        }
        try value.encode(to: self.encoder)
    }
}

/// The faithful-int-key rule, stated once for encoder and decoder: `intValue`
/// stands in for the key only when its canonical decimal form equals
/// `stringValue` (dictionary keys like "5" — `_DictionaryCodingKey` derives
/// `intValue` via `Int(stringValue)`), or when `stringValue` is not itself
/// numeric (struct `CodingKeys`, whose `stringValue` is the property name). A
/// numeric-but-non-canonical string key ("05", "+5") travels as a string key —
/// honoring its claimed int would silently rewrite it on round trip and could
/// collide with a distinct real int key.
func mpFaithfulIntKey(_ key: some CodingKey) -> Int? {
    guard let intKey = key.intValue,
        String(intKey) == key.stringValue || Int(key.stringValue) == nil
    else { return nil }
    return intKey
}

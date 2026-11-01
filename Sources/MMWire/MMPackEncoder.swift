import MMSchema
import NIOCore

/// Whether values of `type` take ``mpWriteBinaryShortcut(_:into:)`` instead of
/// their own `Encodable` conformance.
func mpHasBinaryShortcut<T>(_ type: T.Type) -> Bool {
    type == ByteBuffer.self || type == MMDate.self || type == MMDateTime.self
        || type == MMTimestamp.self
}

/// `ByteBuffer` values encode as MessagePack `bin`, and the wire time kinds ride
/// as `bin` holding a VPTS encoding (the VPTS article in this catalog) — a
/// coder-level short-circuit, so the time types' own `Codable` (canonical ISO
/// strings) keeps serving JSON coders, display, and tests, while the wire gets
/// the compact, byte-sortable binary form. Returns false, writing nothing, for
/// every other type.
func mpWriteBinaryShortcut<T: Encodable>(_ value: T, into buffer: inout ByteBuffer) -> Bool {
    // Guarded force casts: each identity check proves T (the standard Codable
    // short-circuit idiom, mirrored by the decoder).
    if T.self == ByteBuffer.self {
        buffer.writeMessagePackBinary(value as! ByteBuffer)
    } else if T.self == MMDate.self {
        buffer.writeMessagePackBinary(bytes: MMVPTS(value as! MMDate).encoded())
    } else if T.self == MMDateTime.self {
        buffer.writeMessagePackBinary(bytes: MMVPTS(value as! MMDateTime).encoded())
    } else if T.self == MMTimestamp.self {
        buffer.writeMessagePackBinary(bytes: MMVPTS(value as! MMTimestamp).encoded())
    } else {
        return false
    }
    return true
}

/// Encodes `Encodable` values as MessagePack directly into `ByteBuffer`.
///
/// Keyed containers encode as maps with integer keys taken from `CodingKeys.intValue`;
/// keys without an `intValue` fall back to string keys. `ByteBuffer` values encode as
/// `bin`; the wire time kinds (`MMDate`, `MMDateTime`, `MMTimestamp`) encode as `bin`
/// holding their VPTS form.
///
/// Values stream straight into the output buffer: a container writes a one-byte
/// header placeholder and patches it with the final count when it closes, so
/// containers must be written in order, as synthesized and standard-library
/// conformances do. Using a container or encoder after its parent (or any
/// container below it) was written to again fails the encode with
/// `.encodingFailed`.
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
        if mpWriteBinaryShortcut(value, into: &buffer) {
            return .success(())
        }
        let start = buffer.writerIndex
        // The state holds the only reference while encoding, so its writes
        // never copy the storage.
        let state = MPEncodingState(buffer: buffer)
        buffer = ByteBuffer()
        let result = state.encodeRoot(value)
        buffer = state.takeBuffer()
        if case .failure = result {
            buffer.moveWriterIndex(to: start)
        }
        return result
    }
}

// MARK: - Encoding state

/// Names an open frame. The identifier tells a frame from a later one pushed
/// at the same index, so a handle outliving its frame is caught, not misrouted.
struct MPFrameReference {
    let index: Int
    let identifier: Int

    /// Never open: handed out where a container or encoder is requested out of order.
    static let invalid = MPFrameReference(index: .max, identifier: 0)
}

/// A slot or container on the path from the root to the value being written.
struct MPEncodingFrame {
    enum Kind {
        /// A position for exactly one value: the root, a value encoded at a key
        /// or array position, or a super encoder's slot.
        case slot
        case map
        case array
    }

    enum Emission {
        case nothing
        case scalar
        /// The container the slot's value encodes as, open just above the slot.
        case container(MPFrameReference)
    }

    let kind: Kind
    let identifier: Int
    /// The key this frame's value sits under in its parent, for `codingPath`.
    let key: (any CodingKey)?
    /// Containers: where the one-byte header placeholder sits.
    let headerOffset: Int
    /// Containers: the entries written so far.
    var count = 0
    /// Slots: what the slot's value wrote.
    var emission = Emission.nothing
}

/// The output buffer and the stack of open frames for one encode, shared by
/// every encoder and container handle in it. Writing to a frame first closes
/// the frames opened above it — that is how a container learns its nested
/// containers and slots are done.
final class MPEncodingState {
    static let outOfOrder = MMWireError.encodingFailed(
        description: "an encoding container was used after its parent was written to"
    )

    // Unchecked exclusivity: each access is a short read or write that never
    // calls an `Encodable` or anything else that could reach this state, so no
    // two accesses overlap and the runtime check would only cost time.
    @exclusivity(unchecked) var buffer: ByteBuffer
    @exclusivity(unchecked) var frames: [MPEncodingFrame] = []
    @exclusivity(unchecked) private var lastIdentifier = 0
    /// Set on misuse, so the encode fails even when the value swallows the error.
    @exclusivity(unchecked) private var usedOutOfOrder = false

    init(buffer: ByteBuffer) {
        self.buffer = buffer
        self.frames.reserveCapacity(8)
    }

    func takeBuffer() -> ByteBuffer {
        var taken = ByteBuffer()
        swap(&taken, &self.buffer)
        return taken
    }

    func encodeRoot<T: Encodable>(_ value: T) -> Result<Void, MMWireError> {
        let root = self.pushSlot(key: nil)
        do {
            try value.encode(to: MPEncoderImplementation(state: self, slot: root))
            try self.closeSlot(root)
        } catch let error as MMWireError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed(description: String(describing: error)))
        }
        return self.usedOutOfOrder ? .failure(Self.outOfOrder) : .success(())
    }

    func isOpen(_ reference: MPFrameReference) -> Bool {
        reference.index < self.frames.count
            && self.frames[reference.index].identifier == reference.identifier
    }

    /// Readies `reference` for a write by closing every frame above it.
    /// Returns false, recording the misuse, when the frame is no longer open.
    func activate(_ reference: MPFrameReference) -> Bool {
        guard self.isOpen(reference) else {
            self.usedOutOfOrder = true
            return false
        }
        while self.frames.count > reference.index + 1 {
            self.closeTop()
        }
        return true
    }

    func codingPath(through reference: MPFrameReference) -> [any CodingKey] {
        guard self.isOpen(reference) else { return [] }
        var path: [any CodingKey] = []
        for frame in self.frames[...reference.index] {
            if let key = frame.key {
                path.append(key)
            }
        }
        return path
    }

    private func push(_ kind: MPEncodingFrame.Kind, key: (any CodingKey)?) -> MPFrameReference {
        self.lastIdentifier += 1
        let reference = MPFrameReference(index: self.frames.count, identifier: self.lastIdentifier)
        self.frames.append(
            MPEncodingFrame(
                kind: kind,
                identifier: self.lastIdentifier,
                key: key,
                headerOffset: self.buffer.writerIndex
            )
        )
        return reference
    }

    func pushSlot(key: (any CodingKey)?) -> MPFrameReference {
        self.push(.slot, key: key)
    }

    func pushContainer(_ kind: MPEncodingFrame.Kind, key: (any CodingKey)?) -> MPFrameReference {
        let reference = self.push(kind, key: key)
        self.buffer.writeInteger(UInt8(0))
        return reference
    }

    /// The container `slot`'s value encodes as. Repeated requests for the same
    /// style return the same container (required for class-inheritance encoding
    /// through a shared encoder).
    func openContainer(
        _ kind: MPEncodingFrame.Kind,
        for slot: MPFrameReference
    ) -> MPFrameReference {
        guard self.isOpen(slot) else {
            self.usedOutOfOrder = true
            return .invalid
        }
        switch self.frames[slot.index].emission {
            case .nothing:
                // Nothing sits above a slot that has written nothing.
                let container = self.pushContainer(kind, key: nil)
                self.frames[slot.index].emission = .container(container)
                return container
            case .container(let existing)
            where self.isOpen(existing) && self.frames[existing.index].kind == kind:
                return existing
            default:
                preconditionFailure("value already encoded through this encoder")
        }
    }

    /// Marks `slot` as holding a scalar, which the caller writes next.
    func beginScalar(in slot: MPFrameReference) throws {
        guard self.isOpen(slot) else {
            self.usedOutOfOrder = true
            throw Self.outOfOrder
        }
        guard case .nothing = self.frames[slot.index].emission else {
            preconditionFailure("value already encoded through this encoder")
        }
        self.frames[slot.index].emission = .scalar
    }

    struct Checkpoint {
        let container: MPFrameReference
        let writerIndex: Int
        let count: Int
    }

    /// Taken in an active container before it counts an entry whose value encode may throw.
    func checkpoint(_ container: MPFrameReference) -> Checkpoint {
        Checkpoint(
            container: container,
            writerIndex: self.buffer.writerIndex,
            count: self.frames[container.index].count
        )
    }

    /// Encodes `value` through a new slot as the entry just counted in the
    /// container `checkpoint` was taken in. On a throw, everything written
    /// since the checkpoint — the entry's key and any partial value — rolls
    /// back, so a caller that swallows the error cannot finalize a container
    /// whose count includes an entry with no value: structurally corrupt
    /// MessagePack.
    func encodeEntry<T: Encodable>(
        _ value: T,
        key: (any CodingKey)?,
        restoring checkpoint: Checkpoint
    ) throws {
        let slot = self.pushSlot(key: key)
        do {
            try value.encode(to: MPEncoderImplementation(state: self, slot: slot))
            try self.closeSlot(slot)
        } catch {
            // A container already closed by misuse has nothing to restore; the
            // misuse fails the encode.
            if self.isOpen(checkpoint.container) {
                self.frames.removeSubrange((checkpoint.container.index + 1)...)
                self.buffer.moveWriterIndex(to: checkpoint.writerIndex)
                self.frames[checkpoint.container.index].count = checkpoint.count
            }
            throw error
        }
    }

    /// Closes `slot`, and the containers its value opened, once the value is encoded.
    func closeSlot(_ slot: MPFrameReference) throws {
        guard self.activate(slot) else { throw Self.outOfOrder }
        self.closeTop()
    }

    /// Pops the innermost frame and finishes its bytes: a container's
    /// placeholder becomes its header, and a slot nothing was written to becomes nil.
    private func closeTop() {
        let frame = self.frames.removeLast()
        switch frame.kind {
            case .slot:
                if case .nothing = frame.emission {
                    self.buffer.writeMessagePackNil()
                }
            case .map:
                self.patchHeader(
                    at: frame.headerOffset,
                    count: frame.count,
                    fixBase: MPFormat.fixmapBase,
                    format16: MPFormat.map16,
                    format32: MPFormat.map32
                )
            case .array:
                self.patchHeader(
                    at: frame.headerOffset,
                    count: frame.count,
                    fixBase: MPFormat.fixarrayBase,
                    format16: MPFormat.array16,
                    format32: MPFormat.array32
                )
        }
    }

    /// Rewrites the placeholder at `offset` as the smallest header for `count`
    /// (the forms `writeMessagePackMapHeader(count:)` and
    /// `writeMessagePackArrayHeader(count:)` choose), moving the body right when
    /// the header takes more than the placeholder's one byte.
    private func patchHeader(
        at offset: Int,
        count: Int,
        fixBase: UInt8,
        format16: UInt8,
        format32: UInt8
    ) {
        precondition(count <= UInt32.max, "container exceeds MessagePack length limits")
        if count < 16 {
            self.buffer.setInteger(fixBase | UInt8(truncatingIfNeeded: count), at: offset)
            return
        }
        let isWide = count > Int(UInt16.max)
        let growth = isWide ? 4 : 2
        let bodyStart = offset + 1
        let bodyLength = self.buffer.writerIndex - bodyStart
        let readerIndex = self.buffer.readerIndex
        self.buffer.writeRepeatingByte(0, count: growth)
        self.buffer.withUnsafeMutableReadableBytes { bytes in
            let body = bodyStart - readerIndex
            // copyMemory moves like memmove, so the overlapping ranges are safe.
            UnsafeMutableRawBufferPointer(rebasing: bytes[(body + growth)...]).copyMemory(
                from: UnsafeRawBufferPointer(rebasing: bytes[body..<(body + bodyLength)])
            )
        }
        if isWide {
            self.buffer.setInteger(format32, at: offset)
            self.buffer.setInteger(UInt32(truncatingIfNeeded: count), at: bodyStart)
        } else {
            self.buffer.setInteger(format16, at: offset)
            self.buffer.setInteger(UInt16(truncatingIfNeeded: count), at: bodyStart)
        }
    }
}

// MARK: - Encoder

/// The encoder for one slot. Like the containers, a small handle onto the
/// shared state, so it fits an existential's inline buffer without boxing.
struct MPEncoderImplementation: Encoder {
    let state: MPEncodingState
    let slot: MPFrameReference

    var codingPath: [any CodingKey] { self.state.codingPath(through: self.slot) }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            MPKeyedEncoding<Key>(
                state: self.state,
                frame: self.state.openContainer(.map, for: self.slot)
            )
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        MPUnkeyedEncoding(
            state: self.state,
            frame: self.state.openContainer(.array, for: self.slot)
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MPSingleValueEncoding(state: self.state, slot: self.slot)
    }
}

// MARK: - Keyed encoding container

struct MPKeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let state: MPEncodingState
    let frame: MPFrameReference

    var codingPath: [any CodingKey] { self.state.codingPath(through: self.frame) }

    /// Integer keys from `CodingKeys.intValue`; string fallback otherwise —
    /// see ``mpFaithfulIntKey(_:)``, the rule the decoder mirrors exactly.
    /// The map must be active.
    private func writeKey(_ key: Key) {
        if let intKey = mpFaithfulIntKey(key) {
            self.state.buffer.writeMessagePackInt(Int64(intKey))
        } else {
            self.state.buffer.writeMessagePackString(key.stringValue)
        }
        self.state.frames[self.frame.index].count += 1
    }

    /// Activates the map and writes `key`. Returns false, writing nothing, when
    /// the map is no longer open.
    private func beginEntry(_ key: Key) -> Bool {
        guard self.state.activate(self.frame) else { return false }
        self.writeKey(key)
        return true
    }

    private func entry(_ key: Key, _ write: (inout ByteBuffer) -> Void) throws {
        guard self.beginEntry(key) else { throw MPEncodingState.outOfOrder }
        write(&self.state.buffer)
    }

    mutating func encodeNil(forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackNil() }
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackBool(value) }
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackString(value) }
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackDouble(value) }
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackFloat(value) }
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackInt(value) }
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try self.entry(key) { $0.writeMessagePackUInt(value) }
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        guard self.state.activate(self.frame) else { throw MPEncodingState.outOfOrder }
        let checkpoint = self.state.checkpoint(self.frame)
        self.writeKey(key)
        if mpWriteBinaryShortcut(value, into: &self.state.buffer) {
            return
        }
        try self.state.encodeEntry(value, key: key, restoring: checkpoint)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let nested = self.beginEntry(key) ? self.state.pushContainer(.map, key: key) : .invalid
        return KeyedEncodingContainer(MPKeyedEncoding<NestedKey>(state: self.state, frame: nested))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nested = self.beginEntry(key) ? self.state.pushContainer(.array, key: key) : .invalid
        return MPUnkeyedEncoding(state: self.state, frame: nested)
    }

    mutating func superEncoder() -> Encoder {
        guard self.state.activate(self.frame) else {
            return MPEncoderImplementation(state: self.state, slot: .invalid)
        }
        self.state.buffer.writeMessagePackString("super")
        self.state.frames[self.frame.index].count += 1
        return MPEncoderImplementation(state: self.state, slot: self.state.pushSlot(key: nil))
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let slot = self.beginEntry(key) ? self.state.pushSlot(key: key) : .invalid
        return MPEncoderImplementation(state: self.state, slot: slot)
    }
}

// MARK: - Unkeyed encoding container

struct MPUnkeyedEncoding: UnkeyedEncodingContainer {
    let state: MPEncodingState
    let frame: MPFrameReference

    var codingPath: [any CodingKey] { self.state.codingPath(through: self.frame) }

    var count: Int {
        self.state.isOpen(self.frame) ? self.state.frames[self.frame.index].count : 0
    }

    /// Activates the array and counts an element. Returns false when the array
    /// is no longer open.
    private func beginElement() -> Bool {
        guard self.state.activate(self.frame) else { return false }
        self.state.frames[self.frame.index].count += 1
        return true
    }

    private func element(_ write: (inout ByteBuffer) -> Void) throws {
        guard self.beginElement() else { throw MPEncodingState.outOfOrder }
        write(&self.state.buffer)
    }

    mutating func encodeNil() throws {
        try self.element { $0.writeMessagePackNil() }
    }

    mutating func encode(_ value: Bool) throws {
        try self.element { $0.writeMessagePackBool(value) }
    }

    mutating func encode(_ value: String) throws {
        try self.element { $0.writeMessagePackString(value) }
    }

    mutating func encode(_ value: Double) throws {
        try self.element { $0.writeMessagePackDouble(value) }
    }

    mutating func encode(_ value: Float) throws {
        try self.element { $0.writeMessagePackFloat(value) }
    }

    mutating func encode(_ value: Int) throws {
        try self.element { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int8) throws {
        try self.element { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int16) throws {
        try self.element { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int32) throws {
        try self.element { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int64) throws {
        try self.element { $0.writeMessagePackInt(value) }
    }

    mutating func encode(_ value: UInt) throws {
        try self.element { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt8) throws {
        try self.element { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt16) throws {
        try self.element { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt32) throws {
        try self.element { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt64) throws {
        try self.element { $0.writeMessagePackUInt(value) }
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        guard self.state.activate(self.frame) else { throw MPEncodingState.outOfOrder }
        let checkpoint = self.state.checkpoint(self.frame)
        self.state.frames[self.frame.index].count += 1
        if mpWriteBinaryShortcut(value, into: &self.state.buffer) {
            return
        }
        try self.state.encodeEntry(value, key: nil, restoring: checkpoint)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let nested = self.beginElement() ? self.state.pushContainer(.map, key: nil) : .invalid
        return KeyedEncodingContainer(MPKeyedEncoding<NestedKey>(state: self.state, frame: nested))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let nested = self.beginElement() ? self.state.pushContainer(.array, key: nil) : .invalid
        return MPUnkeyedEncoding(state: self.state, frame: nested)
    }

    mutating func superEncoder() -> Encoder {
        let slot = self.beginElement() ? self.state.pushSlot(key: nil) : .invalid
        return MPEncoderImplementation(state: self.state, slot: slot)
    }
}

// MARK: - Single-value encoding container

struct MPSingleValueEncoding: SingleValueEncodingContainer {
    let state: MPEncodingState
    let slot: MPFrameReference

    var codingPath: [any CodingKey] { self.state.codingPath(through: self.slot) }

    private func scalar(_ write: (inout ByteBuffer) -> Void) throws {
        try self.state.beginScalar(in: self.slot)
        write(&self.state.buffer)
    }

    mutating func encodeNil() throws {
        try self.scalar { $0.writeMessagePackNil() }
    }

    mutating func encode(_ value: Bool) throws {
        try self.scalar { $0.writeMessagePackBool(value) }
    }

    mutating func encode(_ value: String) throws {
        try self.scalar { $0.writeMessagePackString(value) }
    }

    mutating func encode(_ value: Double) throws {
        try self.scalar { $0.writeMessagePackDouble(value) }
    }

    mutating func encode(_ value: Float) throws {
        try self.scalar { $0.writeMessagePackFloat(value) }
    }

    mutating func encode(_ value: Int) throws {
        try self.scalar { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int8) throws {
        try self.scalar { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int16) throws {
        try self.scalar { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int32) throws {
        try self.scalar { $0.writeMessagePackInt(Int64(value)) }
    }

    mutating func encode(_ value: Int64) throws {
        try self.scalar { $0.writeMessagePackInt(value) }
    }

    mutating func encode(_ value: UInt) throws {
        try self.scalar { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt8) throws {
        try self.scalar { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt16) throws {
        try self.scalar { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt32) throws {
        try self.scalar { $0.writeMessagePackUInt(UInt64(value)) }
    }

    mutating func encode(_ value: UInt64) throws {
        try self.scalar { $0.writeMessagePackUInt(value) }
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if mpHasBinaryShortcut(T.self) {
            try self.scalar { _ = mpWriteBinaryShortcut(value, into: &$0) }
            return
        }
        try value.encode(to: MPEncoderImplementation(state: self.state, slot: self.slot))
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
///
/// Checked cheapest first: a property name fails to parse at its first
/// character, so only a numeric string pays for formatting `intValue`.
func mpFaithfulIntKey(_ key: some CodingKey) -> Int? {
    guard let intKey = key.intValue else { return nil }
    let stringValue = key.stringValue
    guard let parsed = Int(stringValue) else { return intKey }
    return parsed == intKey && String(intKey) == stringValue ? intKey : nil
}

import MMSchema
import NIOCore

/// The decode twin of `mpWriteBinaryShortcut(_:into:)`: the wire time kinds arrive as
/// MessagePack `bin` holding a VPTS encoding, decoded and constrained per
/// kind — a date field only accepts date precision, a datetime a full wall
/// clock without offset, a timestamp one with. The spec's null timestamp is
/// rejected wherever a value is required (payload optionality is MessagePack
/// nil, never VPTS null). Returns nil when `type` is not a wire time kind.
func vptsValue<T>(
    _ type: T.Type, from buffer: inout ByteBuffer
) throws -> T? {
    let isDate = type == MMDate.self
    let isDateTime = type == MMDateTime.self
    let isTimestamp = type == MMTimestamp.self
    guard isDate || isDateTime || isTimestamp else { return nil }
    let bin = try buffer.readMessagePackBinary().get()
    let decoded: MMVPTS?
    switch MMVPTS.decode(bin.readableBytesView) {
        case .success(let value):
            decoded = value
        case .failure(let failure):
            throw MMWireError.decodingFailed(description: "invalid VPTS: \(failure)")
    }
    guard let vpts = decoded else {
        throw MMWireError.decodingFailed(description: "null VPTS where a value is required")
    }
    // Guarded force casts: the identity checks above prove T (the standard
    // Codable short-circuit idiom, as with ByteBuffer).
    if isDate {
        guard let value = vpts.dateValue else {
            throw MMWireError.decodingFailed(description: "VPTS precision is not a date")
        }
        return (value as! T)
    }
    if isDateTime {
        guard let value = vpts.dateTimeValue else {
            throw MMWireError.decodingFailed(
                description: "VPTS is not an offset-free wall-clock datetime")
        }
        return (value as! T)
    }
    guard let value = vpts.timestampValue else {
        throw MMWireError.decodingFailed(description: "VPTS is not a datetime with offset")
    }
    return (value as! T)
}

/// The standard-library scalars schema fields use, read straight from the
/// bytes: what their own `init(from:)` does through a single-value container,
/// without opening a decoder for the value. Returns nil for every other type.
func mpReadScalar<T>(_ type: T.Type, from buffer: inout ByteBuffer) throws -> T? {
    // Guarded force casts: each identity check proves T.
    if type == String.self {
        return (try buffer.readMessagePackString().get() as! T)
    }
    if type == Int.self {
        return (try mpReadInteger(Int.self, from: &buffer) as! T)
    }
    if type == Double.self {
        return (try buffer.readMessagePackDouble().get() as! T)
    }
    if type == Bool.self {
        return (try buffer.readMessagePackBool().get() as! T)
    }
    if type == UInt64.self {
        return (try mpReadInteger(UInt64.self, from: &buffer) as! T)
    }
    if type == Float.self {
        return (try buffer.readMessagePackFloat().get() as! T)
    }
    return nil
}

/// Decodes MessagePack from `ByteBuffer` into `Decodable` values.
///
/// Keyed containers index their map once (integer and string keys); the first
/// occurrence of a duplicate key wins and unknown keys are skipped structurally.
/// `ByteBuffer` targets decode `bin`/`str` payloads as zero-copy slices.
/// Container nesting beyond `maxDepth` fails with `.nestingTooDeep`.
public struct MMPackDecoder: Sendable {
    /// Maximum container nesting depth for both decoding and structural skipping.
    public var maxDepth: Int

    public init(maxDepth: Int = 128) {
        self.maxDepth = maxDepth
    }

    /// Decodes one value of `type` from the start of `buffer`. Trailing bytes are ignored.
    public func decode<T: Decodable>(
        _ type: T.Type,
        from buffer: ByteBuffer
    ) -> Result<T, MMWireError> {
        do {
            let value = try MPDecodingState.decode(
                type,
                from: buffer,
                depth: 0,
                cap: self.maxDepth
            )
            return .success(value)
        } catch let error as MMWireError {
            return .failure(error)
        } catch {
            return .failure(.decodingFailed(description: String(describing: error)))
        }
    }

    /// Partial field access for the router: indexes only the TOP-LEVEL map of `payload`,
    /// decodes only the value at `intKey`, and returns `nil` if the key is absent.
    /// The first occurrence of a duplicate key wins.
    public func decodeField<T: Decodable>(
        at intKey: Int,
        as type: T.Type,
        fromMapPayload payload: ByteBuffer
    ) -> Result<T?, MMWireError> {
        var cursor = payload
        do {
            let count = try cursor.readMessagePackMapHeader().get()
            let target = Int64(intKey)
            for _ in 0..<count {
                let key = try MPDecodingState.readMapKey(
                    from: &cursor,
                    keyDepth: 1,
                    cap: self.maxDepth
                )
                if case .int(let found) = key, found == target {
                    let value = try MPDecodingState.decode(
                        type,
                        from: cursor,
                        depth: 1,
                        cap: self.maxDepth
                    )
                    return .success(value)
                }
                try cursor.skipMessagePackValue(currentDepth: 1, cap: self.maxDepth).get()
            }
            return .success(nil)
        } catch let error as MMWireError {
            return .failure(error)
        } catch {
            return .failure(.decodingFailed(description: String(describing: error)))
        }
    }
}

// MARK: - Decoding state

/// A map key as the wire spells it.
enum MPMapKey: Equatable {
    case int(Int64)
    case string(String)
    /// A key that can never match a `CodingKey` (out-of-range uint64, invalid UTF-8,
    /// or a non-int/str family); consumed structurally so decoding continues.
    case unusable
}

/// Where a map's entries are. Small maps keep theirs on the decode's stack and
/// are searched in order; large ones hash, so lookups stay constant-time.
enum MPMapIndex {
    /// Positions on the stack, in wire order, holding each key's first occurrence only.
    case stack(Range<Int>, hasStringKeys: Bool)
    case hashed(intKeys: [Int64: ByteBuffer], stringKeys: [String: ByteBuffer])

    /// Maps with more entries than this hash.
    static let linearSearchLimit = 32
}

/// One element of a decode's stack: the frame of a value being decoded, or
/// an entry of the map a frame below it indexed.
struct MPDecodingFrame {
    /// Frames: tells a frame from a later one pushed at the same position.
    /// Map entries: 0, which no reference carries.
    let identifier: Int
    /// Frames: the value's bytes, consumed as it decodes. Map entries: the entry's value.
    var buffer: ByteBuffer
    /// Frames: the container nesting level the value sits at (0 at the top).
    let depth: Int
    /// Frames: the frame this value was read from, for `codingPath`; nil at the root.
    let parent: Int?
    /// Frames: the key this value sits under in its parent, for `codingPath`.
    let codingKey: (any CodingKey)?
    /// Map entries: the entry's key.
    let mapKey: MPMapKey
    /// Frames: the index built by the first keyed-container request; repeated
    /// requests reuse it, so the map bytes are consumed exactly once.
    var mapIndex: MPMapIndex?
    /// Frames read through an unkeyed container: its element count and the
    /// next element's position.
    var elementCount = 0
    var currentIndex = 0
}

/// The working storage of one decode, shared by every decoder and container
/// handle in it: a stack holding a frame per value being decoded and, above
/// each indexed map's frame, that map's entries. A value's decode pops what it
/// pushed when it returns, so the stack's storage is reused value after value.
final class MPDecodingState {
    static let stale = MMWireError.decodingFailed(
        description: "a decoding container was used after its value finished decoding"
    )

    let cap: Int
    var stack: [MPDecodingFrame] = []
    /// Where the innermost value decode's part of the stack begins.
    private var scope = 0
    private var lastIdentifier = 0

    init(cap: Int) {
        self.cap = cap
        self.stack.reserveCapacity(16)
    }

    /// Values whose bytes the coder reads itself: `ByteBuffer` (a zero-copy
    /// `bin`/`str` slice), the wire time kinds, and the standard scalars.
    /// Returns nil for every other type.
    static func readDirectly<T>(_ type: T.Type, from buffer: inout ByteBuffer) throws -> T? {
        if type == ByteBuffer.self {
            // Guarded force cast: the == check above proves T is ByteBuffer;
            // the type system cannot carry a metatype comparison into the
            // generic (the standard Codable short-circuit idiom).
            return (try buffer.readMessagePackBinary().get() as! T)
        }
        if let value = try vptsValue(type, from: &buffer) {
            return value
        }
        return try mpReadScalar(type, from: &buffer)
    }

    /// Decodes one value from the head of `buffer`, creating a decode state
    /// only for a value the coder does not read directly.
    static func decode<T: Decodable>(
        _ type: T.Type,
        from buffer: ByteBuffer,
        depth: Int,
        cap: Int
    ) throws -> T {
        var cursor = buffer
        if let value = try Self.readDirectly(type, from: &cursor) {
            return value
        }
        return try MPDecodingState(cap: cap).decodeComposite(
            type,
            from: buffer,
            depth: depth,
            parent: nil,
            key: nil
        )
    }

    func decodeValue<T: Decodable>(
        _ type: T.Type,
        from buffer: ByteBuffer,
        depth: Int,
        parent: Int,
        key: (any CodingKey)?
    ) throws -> T {
        var cursor = buffer
        if let value = try Self.readDirectly(type, from: &cursor) {
            return value
        }
        return try self.decodeComposite(type, from: buffer, depth: depth, parent: parent, key: key)
    }

    /// Decodes `type` through its own `init(from:)` over a new frame, which
    /// opens the value's scope: everything pushed until it returns is popped then.
    private func decodeComposite<T: Decodable>(
        _ type: T.Type,
        from buffer: ByteBuffer,
        depth: Int,
        parent: Int?,
        key: (any CodingKey)?
    ) throws -> T {
        let mark = self.stack.count
        let enclosingScope = self.scope
        let frame = self.pushFrame(buffer: buffer, depth: depth, parent: parent, key: key)
        self.scope = mark
        defer {
            self.stack.removeSubrange(mark...)
            self.scope = enclosingScope
        }
        let decoder = MPDecoderImplementation(state: self, frame: frame)
        // The format byte first: the conformance cast costs a lookup, and only
        // an array payload can take the reserving path.
        if let format = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self),
            MPFormat.isArray(format),
            let arrayType = type as? any MPArrayDecodable.Type
        {
            // Guarded force cast: the conformance cast above proves T.
            return try arrayType.decodeReservingCapacity(from: decoder) as! T
        }
        return try T(from: decoder)
    }

    func pushFrame(
        buffer: ByteBuffer,
        depth: Int,
        parent: Int?,
        key: (any CodingKey)?
    ) -> MPFrameReference {
        self.lastIdentifier += 1
        let reference = MPFrameReference(index: self.stack.count, identifier: self.lastIdentifier)
        self.stack.append(
            MPDecodingFrame(
                identifier: self.lastIdentifier,
                buffer: buffer,
                depth: depth,
                parent: parent,
                codingKey: key,
                mapKey: .unusable
            )
        )
        return reference
    }

    func isOpen(_ reference: MPFrameReference) -> Bool {
        reference.index < self.stack.count
            && self.stack[reference.index].identifier == reference.identifier
    }

    /// The frame's position on the stack, or `stale` once it has been popped.
    func position(of reference: MPFrameReference) throws -> Int {
        guard self.isOpen(reference) else { throw Self.stale }
        return reference.index
    }

    func codingPath(of reference: MPFrameReference) -> [any CodingKey] {
        guard self.isOpen(reference) else { return [] }
        var path: [any CodingKey] = []
        var position: Int? = reference.index
        while let current = position {
            if let key = self.stack[current].codingKey {
                path.append(key)
            }
            position = self.stack[current].parent
        }
        path.reverse()
        return path
    }

    // MARK: Containers

    /// The frame's map index, built on first request.
    func mapIndex(of reference: MPFrameReference) throws -> MPMapIndex {
        let position = try self.position(of: reference)
        guard self.stack[position].depth < self.cap else {
            throw MMWireError.nestingTooDeep(limit: self.cap)
        }
        if let cached = self.stack[position].mapIndex {
            return cached
        }
        // The entries go on the stack in the current value's scope, so they
        // must belong to a frame that scope pops along with them.
        guard position >= self.scope else { throw Self.stale }
        return try self.buildMapIndex(at: position)
    }

    /// Reads the array header at the head of the frame's bytes, readying the
    /// frame for an unkeyed container.
    func openArray(_ reference: MPFrameReference) throws {
        let position = try self.position(of: reference)
        guard self.stack[position].depth < self.cap else {
            throw MMWireError.nestingTooDeep(limit: self.cap)
        }
        let count = try self.stack[position].buffer.readMessagePackArrayHeader().get()
        self.stack[position].elementCount = count
        self.stack[position].currentIndex = 0
    }

    /// Walks the map once, recording a zero-copy value slice per key.
    /// First occurrence of a duplicate key wins; unusable keys are skipped.
    private func buildMapIndex(at position: Int) throws -> MPMapIndex {
        let entryDepth = self.stack[position].depth + 1
        // Read from a copy: entries are appended to the stack as the walk goes.
        var cursor = self.stack[position].buffer
        let count = try cursor.readMessagePackMapHeader().get()
        let index: MPMapIndex
        if count <= MPMapIndex.linearSearchLimit {
            let start = self.stack.count
            var hasStringKeys = false
            for _ in 0..<count {
                let key = try Self.readMapKey(from: &cursor, keyDepth: entryDepth, cap: self.cap)
                let value = try cursor.sliceMessagePackValue(
                    currentDepth: entryDepth,
                    cap: self.cap
                ).get()
                if case .unusable = key { continue }
                if (start..<self.stack.count).contains(where: { self.stack[$0].mapKey == key }) {
                    continue
                }
                if case .string = key { hasStringKeys = true }
                self.stack.append(
                    MPDecodingFrame(
                        identifier: 0,
                        buffer: value,
                        depth: entryDepth,
                        parent: nil,
                        codingKey: nil,
                        mapKey: key
                    )
                )
            }
            index = .stack(start..<self.stack.count, hasStringKeys: hasStringKeys)
        } else {
            var intKeys: [Int64: ByteBuffer] = [:]
            var stringKeys: [String: ByteBuffer] = [:]
            // Never trust a wire-supplied count for allocation sizing.
            intKeys.reserveCapacity(min(count, 64))
            for _ in 0..<count {
                let key = try Self.readMapKey(from: &cursor, keyDepth: entryDepth, cap: self.cap)
                let value = try cursor.sliceMessagePackValue(
                    currentDepth: entryDepth,
                    cap: self.cap
                ).get()
                switch key {
                    case .int(let intKey):
                        if intKeys[intKey] == nil { intKeys[intKey] = value }
                    case .string(let stringKey):
                        if stringKeys[stringKey] == nil { stringKeys[stringKey] = value }
                    case .unusable:
                        break
                }
            }
            index = .hashed(intKeys: intKeys, stringKeys: stringKeys)
        }
        self.stack[position].buffer = cursor
        self.stack[position].mapIndex = index
        return index
    }

    /// The value at `key`, under the encoder's faithful-int-key rule, shared as
    /// ``mpFaithfulIntKey(_:)``: a dictionary key like "05" (whose
    /// `_DictionaryCodingKey.intValue` claims 5) must never read the distinct
    /// int key 5's value.
    func value(forKey key: some CodingKey, in index: MPMapIndex) -> ByteBuffer? {
        switch index {
            case .stack(let positions, let hasStringKeys):
                if let intKey = mpFaithfulIntKey(key) {
                    let wanted = MPMapKey.int(Int64(intKey))
                    if let found = positions.first(where: { self.stack[$0].mapKey == wanted }) {
                        return self.stack[found].buffer
                    }
                }
                guard hasStringKeys else { return nil }
                let wanted = MPMapKey.string(key.stringValue)
                guard let found = positions.first(where: { self.stack[$0].mapKey == wanted })
                else { return nil }
                return self.stack[found].buffer
            case .hashed(let intKeys, let stringKeys):
                if let intKey = mpFaithfulIntKey(key), let found = intKeys[Int64(intKey)] {
                    return found
                }
                return stringKeys[key.stringValue]
        }
    }

    /// Every key of the map that `Key` can represent, in wire order for a
    /// stack index.
    func keys<Key: CodingKey>(in index: MPMapIndex, as type: Key.Type) -> [Key] {
        var keys: [Key] = []
        func append(_ mapKey: MPMapKey) {
            switch mapKey {
                case .int(let intKey):
                    if let exact = Int(exactly: intKey), let key = Key(intValue: exact) {
                        keys.append(key)
                    }
                case .string(let stringKey):
                    if let key = Key(stringValue: stringKey) {
                        keys.append(key)
                    }
                case .unusable:
                    break
            }
        }
        switch index {
            case .stack(let positions, _):
                keys.reserveCapacity(positions.count)
                for position in positions {
                    append(self.stack[position].mapKey)
                }
            case .hashed(let intKeys, let stringKeys):
                keys.reserveCapacity(intKeys.count + stringKeys.count)
                for intKey in intKeys.keys {
                    append(.int(intKey))
                }
                for stringKey in stringKeys.keys {
                    append(.string(stringKey))
                }
        }
        return keys
    }

    // MARK: Map key handling

    /// Reads one map key, tolerating keys that cannot match any `CodingKey`.
    /// `keyDepth` is the nesting level of the key value itself (map level + 1).
    static func readMapKey(
        from buffer: inout ByteBuffer,
        keyDepth: Int,
        cap: Int
    ) throws -> MPMapKey {
        guard let format = buffer.peekMessagePackFormat() else { throw MMWireError.truncated }
        if MPFormat.isInteger(format) {
            switch buffer.readMessagePackInt() {
                case .success(let value):
                    return .int(value)
                case .failure(.numberOutOfRange):
                    try buffer.skipMessagePackValue(currentDepth: keyDepth, cap: cap).get()
                    return .unusable
                case .failure(let error):
                    throw error
            }
        }
        if MPFormat.isString(format) {
            switch buffer.readMessagePackString() {
                case .success(let value):
                    return .string(value)
                case .failure(.invalidUTF8):
                    try buffer.skipMessagePackValue(currentDepth: keyDepth, cap: cap).get()
                    return .unusable
                case .failure(let error):
                    throw error
            }
        }
        try buffer.skipMessagePackValue(currentDepth: keyDepth, cap: cap).get()
        return .unusable
    }
}

/// Arrays decode with their storage reserved up front, where `Array.init(from:)`
/// grows it one append at a time; otherwise the same loop.
protocol MPArrayDecodable {
    static func decodeReservingCapacity(from decoder: MPDecoderImplementation) throws -> Self
}

extension Array: MPArrayDecodable where Element: Decodable {
    static func decodeReservingCapacity(from decoder: MPDecoderImplementation) throws -> Self {
        var container = try decoder.unkeyedDecoding()
        var elements: [Element] = []
        // Never trust a wire-supplied count for allocation sizing beyond this.
        elements.reserveCapacity(Swift.min(container.count ?? 0, 64))
        while !container.isAtEnd {
            elements.append(try container.decode(Element.self))
        }
        return elements
    }
}

/// Reads an integer of any MessagePack width/signedness when representable in `T`.
func mpReadInteger<T: FixedWidthInteger>(
    _ type: T.Type,
    from buffer: inout ByteBuffer
) throws -> T {
    if T.isSigned {
        switch buffer.readMessagePackInt() {
            case .success(let value):
                guard let narrowed = T(exactly: value) else {
                    throw MMWireError.numberOutOfRange(target: "\(T.self)")
                }
                return narrowed
            case .failure(.numberOutOfRange):
                throw MMWireError.numberOutOfRange(target: "\(T.self)")
            case .failure(let error):
                throw error
        }
    } else {
        switch buffer.readMessagePackUInt() {
            case .success(let value):
                guard let narrowed = T(exactly: value) else {
                    throw MMWireError.numberOutOfRange(target: "\(T.self)")
                }
                return narrowed
            case .failure(.numberOutOfRange):
                throw MMWireError.numberOutOfRange(target: "\(T.self)")
            case .failure(let error):
                throw error
        }
    }
}

// MARK: - Decoder

/// The decoder for one value, which is also its single-value container. Like
/// the containers, a small handle onto the shared state, so it fits an
/// existential's inline buffer without boxing.
struct MPDecoderImplementation: Decoder {
    let state: MPDecodingState
    let frame: MPFrameReference

    var codingPath: [any CodingKey] { self.state.codingPath(of: self.frame) }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let index = try self.state.mapIndex(of: self.frame)
        return KeyedDecodingContainer(
            MPKeyedDecoding<Key>(
                state: self.state,
                frame: self.frame,
                depth: self.state.stack[self.frame.index].depth,
                index: index
            )
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        try self.unkeyedDecoding()
    }

    func unkeyedDecoding() throws -> MPUnkeyedDecoding {
        try self.state.openArray(self.frame)
        return MPUnkeyedDecoding(state: self.state, frame: self.frame)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        self
    }
}

// MARK: - Single-value decoding container

extension MPDecoderImplementation: SingleValueDecodingContainer {
    private func readValue<Value>(_ read: (inout ByteBuffer) throws -> Value) throws -> Value {
        let position = try self.state.position(of: self.frame)
        return try read(&self.state.stack[position].buffer)
    }

    func decodeNil() -> Bool {
        guard self.state.isOpen(self.frame),
            self.state.stack[self.frame.index].buffer.peekMessagePackFormat() == MPFormat.nilByte
        else { return false }
        self.state.stack[self.frame.index].buffer.moveReaderIndex(forwardBy: 1)
        return true
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try self.readValue { try $0.readMessagePackBool().get() }
    }

    func decode(_ type: String.Type) throws -> String {
        try self.readValue { try $0.readMessagePackString().get() }
    }

    func decode(_ type: Double.Type) throws -> Double {
        try self.readValue { try $0.readMessagePackDouble().get() }
    }

    func decode(_ type: Float.Type) throws -> Float {
        try self.readValue { try $0.readMessagePackFloat().get() }
    }

    func decode(_ type: Int.Type) throws -> Int {
        try self.readValue { try mpReadInteger(Int.self, from: &$0) }
    }
    func decode(_ type: Int8.Type) throws -> Int8 {
        try self.readValue { try mpReadInteger(Int8.self, from: &$0) }
    }
    func decode(_ type: Int16.Type) throws -> Int16 {
        try self.readValue { try mpReadInteger(Int16.self, from: &$0) }
    }
    func decode(_ type: Int32.Type) throws -> Int32 {
        try self.readValue { try mpReadInteger(Int32.self, from: &$0) }
    }
    func decode(_ type: Int64.Type) throws -> Int64 {
        try self.readValue { try mpReadInteger(Int64.self, from: &$0) }
    }
    func decode(_ type: UInt.Type) throws -> UInt {
        try self.readValue { try mpReadInteger(UInt.self, from: &$0) }
    }
    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try self.readValue { try mpReadInteger(UInt8.self, from: &$0) }
    }
    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try self.readValue { try mpReadInteger(UInt16.self, from: &$0) }
    }
    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try self.readValue { try mpReadInteger(UInt32.self, from: &$0) }
    }
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try self.readValue { try mpReadInteger(UInt64.self, from: &$0) }
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if let value = try self.readValue({ try MPDecodingState.readDirectly(type, from: &$0) }) {
            return value
        }
        return try T(from: self)
    }
}

// MARK: - Keyed decoding container

struct MPKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let state: MPDecodingState
    /// The frame of the decoder whose map this is.
    let frame: MPFrameReference
    /// Nesting level of the map itself; values decode at `depth + 1`.
    let depth: Int
    let index: MPMapIndex

    var codingPath: [any CodingKey] { self.state.codingPath(of: self.frame) }

    var allKeys: [Key] {
        guard self.state.isOpen(self.frame) else { return [] }
        return self.state.keys(in: self.index, as: Key.self)
    }

    private static func describe(_ key: Key) -> String {
        key.intValue.map(String.init) ?? key.stringValue
    }

    private func requireSlice(_ key: Key) throws -> ByteBuffer {
        guard self.state.isOpen(self.frame) else { throw MPDecodingState.stale }
        guard let found = self.state.value(forKey: key, in: self.index) else {
            throw MMWireError.keyNotFound(key: Self.describe(key))
        }
        return found
    }

    func contains(_ key: Key) -> Bool {
        self.state.isOpen(self.frame) && self.state.value(forKey: key, in: self.index) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        try self.requireSlice(key).peekMessagePackFormat() == MPFormat.nilByte
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        var slice = try self.requireSlice(key)
        return try slice.readMessagePackBool().get()
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        var slice = try self.requireSlice(key)
        return try slice.readMessagePackString().get()
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        var slice = try self.requireSlice(key)
        return try slice.readMessagePackDouble().get()
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        var slice = try self.requireSlice(key)
        return try slice.readMessagePackFloat().get()
    }

    private func integer<T: FixedWidthInteger>(_ type: T.Type, forKey key: Key) throws -> T {
        var slice = try self.requireSlice(key)
        return try mpReadInteger(T.self, from: &slice)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try self.integer(Int.self, forKey: key)
    }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try self.integer(Int8.self, forKey: key)
    }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try self.integer(Int16.self, forKey: key)
    }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try self.integer(Int32.self, forKey: key)
    }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try self.integer(Int64.self, forKey: key)
    }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try self.integer(UInt.self, forKey: key)
    }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try self.integer(UInt8.self, forKey: key)
    }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try self.integer(UInt16.self, forKey: key)
    }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try self.integer(UInt32.self, forKey: key)
    }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try self.integer(UInt64.self, forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try self.state.decodeValue(
            type,
            from: try self.requireSlice(key),
            depth: self.depth + 1,
            parent: self.frame.index,
            key: key
        )
    }

    /// A decoder for the value at `key`, in the current value's scope.
    private func childDecoder(at key: Key) throws -> MPDecoderImplementation {
        let child = self.state.pushFrame(
            buffer: try self.requireSlice(key),
            depth: self.depth + 1,
            parent: self.frame.index,
            key: key
        )
        return MPDecoderImplementation(state: self.state, frame: child)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try self.childDecoder(at: key).container(keyedBy: NestedKey.self)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try self.childDecoder(at: key).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        guard self.state.isOpen(self.frame) else { throw MPDecodingState.stale }
        guard let slice = self.state.value(forKey: MPSuperKey(), in: self.index) else {
            throw MMWireError.keyNotFound(key: "super")
        }
        let child = self.state.pushFrame(
            buffer: slice,
            depth: self.depth + 1,
            parent: self.frame.index,
            key: nil
        )
        return MPDecoderImplementation(state: self.state, frame: child)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        try self.childDecoder(at: key)
    }
}

/// The string key "super" that `superEncoder()` writes.
private struct MPSuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }

    init() {}

    init?(stringValue: String) {
        nil
    }

    init?(intValue: Int) {
        nil
    }
}

// MARK: - Unkeyed decoding container

/// Reads its elements from the frame's bytes; the frame also keeps the count
/// and position, so copies of the container stay in step.
struct MPUnkeyedDecoding: UnkeyedDecodingContainer {
    let state: MPDecodingState
    let frame: MPFrameReference

    var codingPath: [any CodingKey] { self.state.codingPath(of: self.frame) }

    var count: Int? {
        self.state.isOpen(self.frame) ? self.state.stack[self.frame.index].elementCount : nil
    }

    var isAtEnd: Bool {
        guard self.state.isOpen(self.frame) else { return true }
        let position = self.frame.index
        return self.state.stack[position].currentIndex >= self.state.stack[position].elementCount
    }

    var currentIndex: Int {
        self.state.isOpen(self.frame) ? self.state.stack[self.frame.index].currentIndex : 0
    }

    /// The frame's position, once it is known to hold another element.
    private func nextElementPosition() throws -> Int {
        let position = try self.state.position(of: self.frame)
        let currentIndex = self.state.stack[position].currentIndex
        guard currentIndex < self.state.stack[position].elementCount else {
            throw MMWireError.keyNotFound(key: "index \(currentIndex)")
        }
        return position
    }

    mutating func decodeNil() throws -> Bool {
        let position = try self.nextElementPosition()
        guard let format = self.state.stack[position].buffer.peekMessagePackFormat() else {
            throw MMWireError.truncated
        }
        guard format == MPFormat.nilByte else { return false }
        self.state.stack[position].buffer.moveReaderIndex(forwardBy: 1)
        self.state.stack[position].currentIndex += 1
        return true
    }

    private mutating func element<T>(_ read: (inout ByteBuffer) throws -> T) throws -> T {
        let position = try self.nextElementPosition()
        let value = try read(&self.state.stack[position].buffer)
        self.state.stack[position].currentIndex += 1
        return value
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        try self.element { try $0.readMessagePackBool().get() }
    }

    mutating func decode(_ type: String.Type) throws -> String {
        try self.element { try $0.readMessagePackString().get() }
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        try self.element { try $0.readMessagePackDouble().get() }
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        try self.element { try $0.readMessagePackFloat().get() }
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        try self.element { try mpReadInteger(Int.self, from: &$0) }
    }
    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        try self.element { try mpReadInteger(Int8.self, from: &$0) }
    }
    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        try self.element { try mpReadInteger(Int16.self, from: &$0) }
    }
    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        try self.element { try mpReadInteger(Int32.self, from: &$0) }
    }
    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try self.element { try mpReadInteger(Int64.self, from: &$0) }
    }
    mutating func decode(_ type: UInt.Type) throws -> UInt {
        try self.element { try mpReadInteger(UInt.self, from: &$0) }
    }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try self.element { try mpReadInteger(UInt8.self, from: &$0) }
    }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try self.element { try mpReadInteger(UInt16.self, from: &$0) }
    }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try self.element { try mpReadInteger(UInt32.self, from: &$0) }
    }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try self.element { try mpReadInteger(UInt64.self, from: &$0) }
    }

    /// Takes the next element as an exact slice, so a decoder that
    /// under-consumes its value cannot desynchronize this container's cursor.
    private mutating func nextElementSlice() throws -> (slice: ByteBuffer, depth: Int) {
        let position = try self.nextElementPosition()
        let depth = self.state.stack[position].depth + 1
        let cap = self.state.cap
        let slice = try self.state.stack[position].buffer.sliceMessagePackValue(
            currentDepth: depth,
            cap: cap
        ).get()
        self.state.stack[position].currentIndex += 1
        return (slice, depth)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let element = try self.nextElementSlice()
        return try self.state.decodeValue(
            type,
            from: element.slice,
            depth: element.depth,
            parent: self.frame.index,
            key: nil
        )
    }

    /// A decoder for the next element, in the current value's scope.
    private mutating func nextElementDecoder() throws -> MPDecoderImplementation {
        let element = try self.nextElementSlice()
        let child = self.state.pushFrame(
            buffer: element.slice,
            depth: element.depth,
            parent: self.frame.index,
            key: nil
        )
        return MPDecoderImplementation(state: self.state, frame: child)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try self.nextElementDecoder().container(keyedBy: NestedKey.self)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try self.nextElementDecoder().unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        try self.nextElementDecoder()
    }
}

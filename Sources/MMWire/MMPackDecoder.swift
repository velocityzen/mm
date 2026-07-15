import NIOCore

/// Decodes MessagePack from `ByteBuffer` into `Decodable` values.
///
/// Keyed containers build a small key-to-slice index per map (integer and string keys);
/// the first occurrence of a duplicate key wins and unknown keys are skipped
/// structurally. `ByteBuffer` targets decode `bin`/`str` payloads as zero-copy slices.
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
        var cursor = buffer
        do {
            let value = try MPDecoderImplementation.decodeValue(
                type,
                from: &cursor,
                depth: 0,
                cap: self.maxDepth,
                codingPath: []
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
                let key = try MPDecoderImplementation.readMapKey(
                    from: &cursor,
                    keyDepth: 1,
                    cap: self.maxDepth
                )
                if case .int(let found) = key, found == target {
                    let value = try MPDecoderImplementation.decodeValue(
                        type,
                        from: &cursor,
                        depth: 1,
                        cap: self.maxDepth,
                        codingPath: []
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

// MARK: - Decoder

/// Decoder for one MessagePack value. `depth` is the container nesting level the value
/// sits at (0 for top level); opening a container requires `depth < cap`.
final class MPDecoderImplementation: Decoder {
    var buffer: ByteBuffer
    let depth: Int
    let cap: Int
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    /// Map index built by the first keyed-container request; repeated requests
    /// reuse it (see `container(keyedBy:)`).
    private var cachedMapIndex: MPMapIndex?

    init(buffer: ByteBuffer, depth: Int, cap: Int, codingPath: [any CodingKey]) {
        self.buffer = buffer
        self.depth = depth
        self.cap = cap
        self.codingPath = codingPath
    }

    /// Decodes one value from `buffer`, advancing it past the value.
    /// `ByteBuffer` targets short-circuit to a zero-copy `bin`/`str` slice.
    static func decodeValue<T: Decodable>(
        _ type: T.Type,
        from buffer: inout ByteBuffer,
        depth: Int,
        cap: Int,
        codingPath: [any CodingKey]
    ) throws -> T {
        if type == ByteBuffer.self {
            return try buffer.readMessagePackBinary().get() as! T
        }
        let impl = MPDecoderImplementation(
            buffer: buffer, depth: depth, cap: cap, codingPath: codingPath)
        let value = try T(from: impl)
        buffer = impl.buffer
        return value
    }

    /// Repeated keyed-container requests return containers over the same map index
    /// (the map bytes are consumed exactly once) — required for class-inheritance
    /// decoding through a shared decoder, mirroring the encoder's shared-container
    /// behavior in `MPEncoderImpl.containerForEmission`.
    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard self.depth < self.cap else { throw MMWireError.nestingTooDeep(limit: self.cap) }
        let index: MPMapIndex
        if let cached = self.cachedMapIndex {
            index = cached
        } else {
            index = try self.buildMapIndex()
            self.cachedMapIndex = index
        }
        return KeyedDecodingContainer(
            MPKeyedDecoding<Key>(
                index: index,
                depth: self.depth,
                cap: self.cap,
                codingPath: self.codingPath
            )
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard self.depth < self.cap else { throw MMWireError.nestingTooDeep(limit: self.cap) }
        let count = try self.buffer.readMessagePackArrayHeader().get()
        return MPUnkeyedDecoding(decoder: self, count: count)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        self
    }

    // MARK: Map key handling

    enum MapKey {
        case int(Int64)
        case string(String)
        /// A key that can never match a `CodingKey` (out-of-range uint64, invalid UTF-8,
        /// or a non-int/str family); consumed structurally so decoding continues.
        case unusable
    }

    /// Reads one map key, tolerating keys that cannot match any `CodingKey`.
    /// `keyDepth` is the nesting level of the key value itself (map level + 1).
    static func readMapKey(
        from buffer: inout ByteBuffer,
        keyDepth: Int,
        cap: Int
    ) throws -> MapKey {
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

    /// Measures the value at the head of `buffer` by structurally skipping a probe copy,
    /// then consumes it as a zero-copy slice.
    static func takeValueSlice(
        from buffer: inout ByteBuffer,
        valueDepth: Int,
        cap: Int
    ) throws -> ByteBuffer {
        var probe = buffer
        try probe.skipMessagePackValue(currentDepth: valueDepth, cap: cap).get()
        let length = probe.readerIndex - buffer.readerIndex
        guard let slice = buffer.readSlice(length: length) else {
            throw MMWireError.truncated
        }
        return slice
    }

    /// Walks the map once, recording a zero-copy value slice per key.
    /// First occurrence of a duplicate key wins; unusable keys are skipped.
    private func buildMapIndex() throws -> MPMapIndex {
        let count = try self.buffer.readMessagePackMapHeader().get()
        var index = MPMapIndex()
        // Never trust a wire-supplied count for allocation sizing.
        index.intKeys.reserveCapacity(min(count, 64))
        for _ in 0..<count {
            let key = try Self.readMapKey(
                from: &self.buffer, keyDepth: self.depth + 1, cap: self.cap)
            let slice = try Self.takeValueSlice(
                from: &self.buffer,
                valueDepth: self.depth + 1,
                cap: self.cap
            )
            switch key {
                case .int(let intKey):
                    if index.intKeys[intKey] == nil { index.intKeys[intKey] = slice }
                case .string(let stringKey):
                    if index.stringKeys[stringKey] == nil { index.stringKeys[stringKey] = slice }
                case .unusable:
                    break
            }
        }
        return index
    }
}

struct MPMapIndex {
    var intKeys: [Int64: ByteBuffer] = [:]
    var stringKeys: [String: ByteBuffer] = [:]
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

// MARK: - Single-value decoding container

extension MPDecoderImplementation: SingleValueDecodingContainer {
    func decodeNil() -> Bool {
        guard self.buffer.peekMessagePackFormat() == MPFormat.nilByte else { return false }
        self.buffer.moveReaderIndex(forwardBy: 1)
        return true
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try self.buffer.readMessagePackBool().get()
    }

    func decode(_ type: String.Type) throws -> String {
        try self.buffer.readMessagePackString().get()
    }

    func decode(_ type: Double.Type) throws -> Double {
        try self.buffer.readMessagePackDouble().get()
    }

    func decode(_ type: Float.Type) throws -> Float {
        try self.buffer.readMessagePackFloat().get()
    }

    func decode(_ type: Int.Type) throws -> Int { try mpReadInteger(Int.self, from: &self.buffer) }
    func decode(_ type: Int8.Type) throws -> Int8 {
        try mpReadInteger(Int8.self, from: &self.buffer)
    }
    func decode(_ type: Int16.Type) throws -> Int16 {
        try mpReadInteger(Int16.self, from: &self.buffer)
    }
    func decode(_ type: Int32.Type) throws -> Int32 {
        try mpReadInteger(Int32.self, from: &self.buffer)
    }
    func decode(_ type: Int64.Type) throws -> Int64 {
        try mpReadInteger(Int64.self, from: &self.buffer)
    }
    func decode(_ type: UInt.Type) throws -> UInt {
        try mpReadInteger(UInt.self, from: &self.buffer)
    }
    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try mpReadInteger(UInt8.self, from: &self.buffer)
    }
    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try mpReadInteger(UInt16.self, from: &self.buffer)
    }
    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try mpReadInteger(UInt32.self, from: &self.buffer)
    }
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try mpReadInteger(UInt64.self, from: &self.buffer)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == ByteBuffer.self {
            return try self.buffer.readMessagePackBinary().get() as! T
        }
        return try T(from: self)
    }
}

// MARK: - Keyed decoding container

struct MPKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let index: MPMapIndex
    /// Nesting level of the map itself; values decode at `depth + 1`.
    let depth: Int
    let cap: Int
    let codingPath: [any CodingKey]

    var allKeys: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(self.index.intKeys.count + self.index.stringKeys.count)
        for intKey in self.index.intKeys.keys {
            if let exact = Int(exactly: intKey), let key = Key(intValue: exact) {
                keys.append(key)
            }
        }
        for stringKey in self.index.stringKeys.keys {
            if let key = Key(stringValue: stringKey) {
                keys.append(key)
            }
        }
        return keys
    }

    private static func describe(_ key: Key) -> String {
        key.intValue.map(String.init) ?? key.stringValue
    }

    /// Mirrors the encoder's faithful-int-key rule: the int lookup is honored only
    /// when `intValue` canonically represents the key — its decimal form equals
    /// `stringValue`, or `stringValue` is not itself numeric (struct `CodingKeys`).
    /// A dictionary key like "05" (whose `_DictionaryCodingKey.intValue` claims 5)
    /// must never read the distinct int key 5's value.
    private func slice(for key: Key) -> ByteBuffer? {
        if let intKey = key.intValue,
            String(intKey) == key.stringValue || Int(key.stringValue) == nil,
            let found = self.index.intKeys[Int64(intKey)]
        {
            return found
        }
        return self.index.stringKeys[key.stringValue]
    }

    private func requireSlice(_ key: Key) throws -> ByteBuffer {
        guard let found = self.slice(for: key) else {
            throw MMWireError.keyNotFound(key: Self.describe(key))
        }
        return found
    }

    func contains(_ key: Key) -> Bool {
        self.slice(for: key) != nil
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
        var slice = try self.requireSlice(key)
        return try MPDecoderImplementation.decodeValue(
            type,
            from: &slice,
            depth: self.depth + 1,
            cap: self.cap,
            codingPath: self.codingPath + [key]
        )
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let child = MPDecoderImplementation(
            buffer: try self.requireSlice(key),
            depth: self.depth + 1,
            cap: self.cap,
            codingPath: self.codingPath + [key]
        )
        return try child.container(keyedBy: NestedKey.self)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let child = MPDecoderImplementation(
            buffer: try self.requireSlice(key),
            depth: self.depth + 1,
            cap: self.cap,
            codingPath: self.codingPath + [key]
        )
        return try child.unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        guard let slice = self.index.stringKeys["super"] else {
            throw MMWireError.keyNotFound(key: "super")
        }
        return MPDecoderImplementation(
            buffer: slice,
            depth: self.depth + 1,
            cap: self.cap,
            codingPath: self.codingPath
        )
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        MPDecoderImplementation(
            buffer: try self.requireSlice(key),
            depth: self.depth + 1,
            cap: self.cap,
            codingPath: self.codingPath + [key]
        )
    }
}

// MARK: - Unkeyed decoding container

struct MPUnkeyedDecoding: UnkeyedDecodingContainer {
    /// Owns the cursor; elements sit at nesting level `decoder.depth + 1`.
    let decoder: MPDecoderImplementation
    let count: Int?
    var currentIndex = 0

    init(decoder: MPDecoderImplementation, count: Int) {
        self.decoder = decoder
        self.count = count
    }

    var codingPath: [any CodingKey] { self.decoder.codingPath }
    var isAtEnd: Bool { self.currentIndex >= (self.count ?? 0) }

    private func ensureNotAtEnd() throws {
        guard !self.isAtEnd else {
            throw MMWireError.keyNotFound(key: "index \(self.currentIndex)")
        }
    }

    mutating func decodeNil() throws -> Bool {
        try self.ensureNotAtEnd()
        guard let format = self.decoder.buffer.peekMessagePackFormat() else {
            throw MMWireError.truncated
        }
        guard format == MPFormat.nilByte else { return false }
        self.decoder.buffer.moveReaderIndex(forwardBy: 1)
        self.currentIndex += 1
        return true
    }

    private mutating func element<T>(_ read: (inout ByteBuffer) throws -> T) throws -> T {
        try self.ensureNotAtEnd()
        let value = try read(&self.decoder.buffer)
        self.currentIndex += 1
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

    /// Hands the next element to a child decoder as an exact slice, so a decoder that
    /// under-consumes its value cannot desynchronize this container's cursor.
    private mutating func nextElementSlice() throws -> ByteBuffer {
        try self.ensureNotAtEnd()
        let slice = try MPDecoderImplementation.takeValueSlice(
            from: &self.decoder.buffer,
            valueDepth: self.decoder.depth + 1,
            cap: self.decoder.cap
        )
        self.currentIndex += 1
        return slice
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        var slice = try self.nextElementSlice()
        return try MPDecoderImplementation.decodeValue(
            type,
            from: &slice,
            depth: self.decoder.depth + 1,
            cap: self.decoder.cap,
            codingPath: self.codingPath
        )
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let child = MPDecoderImplementation(
            buffer: try self.nextElementSlice(),
            depth: self.decoder.depth + 1,
            cap: self.decoder.cap,
            codingPath: self.codingPath
        )
        return try child.container(keyedBy: NestedKey.self)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let child = MPDecoderImplementation(
            buffer: try self.nextElementSlice(),
            depth: self.decoder.depth + 1,
            cap: self.decoder.cap,
            codingPath: self.codingPath
        )
        return try child.unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        MPDecoderImplementation(
            buffer: try self.nextElementSlice(),
            depth: self.decoder.depth + 1,
            cap: self.decoder.cap,
            codingPath: self.codingPath
        )
    }
}

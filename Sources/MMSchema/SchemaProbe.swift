import Synchronization

/// The probing decoder.
///
/// `TypeSchema.of(T.self)` runs `T(from: probe)` exactly once. The probe's
/// containers record `(key, type, optionality)` for every `decode` /
/// `decodeIfPresent` call and hand back zero values (`0`, `""`, `false`, empty
/// collections), so a synthesized `init(from:)` walks all of its fields and the
/// recorded calls assemble the ``TypeSchema`` tree.
///
/// ## What is handled automatically
///
/// - nested structs (recursive probing),
/// - optionals (`decodeIfPresent` records `.optional`),
/// - arrays (the unkeyed container reports `isAtEnd == false` exactly once, so
///   the element type gets probed, then reports `true`),
/// - `RawRepresentable` enums (the raw primitive is recorded before
///   `init(rawValue:)` rejects the zero value; the probe recovers the recorded
///   primitive),
/// - `Dictionary` (special-cased to `.map(key:value:)` — see the policy note),
/// - cycles (a recursive occurrence of an in-flight type probes as `.unknown`;
///   the probe never hangs or overflows),
/// - memoization (successful, cycle-free probes are cached per type in a
///   process-global cache).
///
/// ## Dictionary policy (fixed)
///
/// `Dictionary` is special-cased, not routed through its `init(from:)`: its
/// synthesized decoder branches on the runtime key type and on `allKeys`, which
/// a zero-value probe cannot walk truthfully. Any `Dictionary<Key, Value>`
/// whose `Key` and `Value` are `Decodable` probes as
/// `.map(key: schemaOf(Key), value: schemaOf(Value))`. `Set` is *not*
/// special-cased; it probes through its unkeyed decoder as `.array(Element)`.
///
/// ## What requires ``SchemaDescribable``
///
/// Types with data-dependent `init(from:)` branches — associated-value enums,
/// version switches, validating decoders that reject zero values — MUST adopt
/// ``SchemaDescribable``; the probe checks that conformance first and never
/// runs their decoder. Without it they surface as
/// `SchemaError.probeFailed` / `.unconstructibleType`, or record a wrong shape.
///
/// A non-optional struct field whose type cannot be instantiated from zero
/// values (e.g. a `String`-backed enum with no `""` case) needs one of: make
/// the field optional, conform the enum to `CaseIterable` (the probe grabs any
/// case as the placeholder instance), or adopt ``SchemaDescribable`` on the
/// *containing* type.
///
/// ## Class hierarchies
///
/// A subclass decoding through a *shared* decoder (`super.init(from: decoder)`)
/// merges superclass fields into one structure, matching the wire coder. A
/// subclass decoding through `container.superDecoder()` records the super
/// position as an `.unknown` field named `"super"` (the wire form nests the
/// superclass under that key); adopt ``SchemaDescribable`` for a truthful shape.
extension TypeSchema {
    /// Probes `T` and assembles its wire shape. Checks ``SchemaDescribable``
    /// first and short-circuits; results are memoized per type.
    public static func of<T: Decodable>(_ type: T.Type) -> Result<TypeSchema, SchemaError> {
        schemaFor(type, context: ProbeContext())
    }

    /// Internal recursive entry point sharing one in-flight context per
    /// top-level `of` call.
    static func schemaFor<T: Decodable>(_ type: T.Type, context: ProbeContext) -> Result<
        TypeSchema, SchemaError
    > {
        if let describable = type as? any SchemaDescribable.Type {
            return .success(describable.schema)
        }
        let id = ObjectIdentifier(type)
        if context.inFlightSchema.contains(id) {
            // Recursive occurrence of a type currently being probed: map it to
            // .unknown (and count the hit so tainted results skip the cache).
            context.cycleHits += 1
            return .success(.unknown)
        }
        if let cached = SchemaCache.lookup(id) {
            return .success(cached)
        }
        context.inFlightSchema.insert(id)
        defer { context.inFlightSchema.remove(id) }

        let cycleHitsBefore = context.cycleHits
        let result = probeShape(type, context: context)
        // Cache successes, but never a result that contains a cycle-placeholder
        // .unknown — it is only correct relative to the in-flight stack.
        if case .success(let schema) = result, context.cycleHits == cycleHitsBefore {
            SchemaCache.store(id, schema)
        }
        return result
    }

    /// The decoder-behavior shape of `T`: what `T(from:)` actually does,
    /// **ignoring a top-level ``SchemaDescribable`` conformance** (nested
    /// fields still honor theirs). This is the contract-verification probe: a
    /// self-described type cannot vouch for itself, so `verify(against:)`
    /// compares declarations against this, not against ``of(_:)``.
    ///
    /// Never consults or populates the memoization cache at the top level —
    /// the cache stores `of` semantics (described shapes), which are exactly
    /// what this call exists to bypass.
    public static func probed<T: Decodable>(_ type: T.Type) -> Result<TypeSchema, SchemaError> {
        let context = ProbeContext()
        let id = ObjectIdentifier(type)
        context.inFlightSchema.insert(id)
        defer { context.inFlightSchema.remove(id) }
        return probeShape(type, context: context)
    }

    /// The shared shape-probing branch: optionals and dictionaries bypass
    /// their decoders (see the policies above); everything else runs one.
    private static func probeShape<T: Decodable>(
        _ type: T.Type,
        context: ProbeContext
    ) -> Result<TypeSchema, SchemaError> {
        if let optionalType = type as? any _SchemaOptionalProbing.Type {
            return optionalType._optionalSchema(context: context)
        }
        if let mapType = type as? any _SchemaMapProbing.Type {
            return mapType._mapSchema(context: context)
        }
        return runProbe(type, context: context)
    }

    private static func runProbe<T: Decodable>(_ type: T.Type, context: ProbeContext) -> Result<
        TypeSchema, SchemaError
    > {
        let probe = SchemaProbe(context: context)
        do {
            _ = try T(from: probe)
            return .success(probe.assembled)
        } catch let signal as ProbeSignal {
            return .failure(signal.schemaError)
        } catch {
            // RawRepresentable enums record their raw primitive in a
            // single-value container, then throw from init(rawValue:) because
            // the zero value is not a case. Recover the recorded primitive.
            if case .single(let recorder) = probe.shape, let schema = recorder.schema {
                return .success(schema)
            }
            return .failure(.probeFailed(String(reflecting: type)))
        }
    }

    /// Produces a placeholder instance of `type` so a *containing* type's
    /// decoder can keep walking past a field of this type. Throws
    /// ``ProbeSignal/unconstructible(_:)`` when no instance can be made.
    static func instanceFor<T: Decodable>(_ type: T.Type, context: ProbeContext) throws -> T {
        if let providing = type as? any _ProbeDefaultProviding.Type,
            let instance = providing._probeDefaultAny as? T
        {
            return instance
        }
        let id = ObjectIdentifier(type)
        guard !context.inFlightInstance.contains(id) else {
            // A value type cannot recursively contain itself non-optionally;
            // refuse rather than recurse forever.
            throw ProbeSignal.unconstructible(String(reflecting: type))
        }
        context.inFlightInstance.insert(id)
        defer { context.inFlightInstance.remove(id) }
        do {
            return try T(from: SchemaProbe(context: context))
        } catch let signal as ProbeSignal {
            if let instance = caseIterableInstance(type) {
                return instance
            }
            throw signal  // keep the innermost, most actionable description
        } catch {
            if let instance = caseIterableInstance(type) {
                return instance
            }
            throw ProbeSignal.unconstructible(String(reflecting: type))
        }
    }

    private static func caseIterableInstance<T>(_ type: T.Type) -> T? {
        guard let caseIterable = type as? any CaseIterable.Type else { return nil }
        return firstCase(of: caseIterable) as? T
    }
}

/// Opens the existential metatype to reach `allCases`.
private func firstCase<C: CaseIterable>(of type: C.Type) -> Any? {
    var iterator = C.allCases.makeIterator()
    return iterator.next()
}

// MARK: - Internal probing hooks

/// Per-`of` mutable state: in-flight type tracking for cycle safety. One
/// instance per top-level `TypeSchema.of` call; never shared across threads.
final class ProbeContext {
    var inFlightSchema: Set<ObjectIdentifier> = []
    var inFlightInstance: Set<ObjectIdentifier> = []
    var cycleHits = 0
}

/// Internal control-flow error inside a probe run; mapped to ``SchemaError``
/// at the `of` boundary and never visible outside the module.
enum ProbeSignal: Error {
    case nested(SchemaError)
    case unconstructible(String)

    var schemaError: SchemaError {
        switch self {
            case .nested(let error): return error
            case .unconstructible(let typeName): return .unconstructibleType(typeName)
        }
    }
}

/// Optionals bypass their `init(from:)` (which would erase optionality).
protocol _SchemaOptionalProbing {
    static func _optionalSchema(context: ProbeContext) -> Result<TypeSchema, SchemaError>
}

extension Optional: _SchemaOptionalProbing where Wrapped: Decodable {
    static func _optionalSchema(context: ProbeContext) -> Result<TypeSchema, SchemaError> {
        TypeSchema.schemaFor(Wrapped.self, context: context).map { .optional($0) }
    }
}

/// Dictionaries bypass their `init(from:)`; see the dictionary policy note.
protocol _SchemaMapProbing {
    static func _mapSchema(context: ProbeContext) -> Result<TypeSchema, SchemaError>
}

extension Dictionary: _SchemaMapProbing where Key: Decodable, Value: Decodable {
    static func _mapSchema(context: ProbeContext) -> Result<TypeSchema, SchemaError> {
        TypeSchema.schemaFor(Key.self, context: context).flatMap { keySchema in
            TypeSchema.schemaFor(Value.self, context: context).map { valueSchema in
                .map(key: keySchema, value: valueSchema)
            }
        }
    }
}

/// Types with a trivial empty instance the probe can hand back without running
/// a decoder.
protocol _ProbeDefaultProviding {
    static var _probeDefaultAny: Any { get }
}

extension Optional: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any { Optional<Wrapped>.none as Any }
}

extension Array: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any { Array() }
}

extension Dictionary: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any { Dictionary() }
}

extension Set: _ProbeDefaultProviding {
    static var _probeDefaultAny: Any { Set() }
}

// MARK: - Memoization cache

/// Process-global probe cache keyed by `ObjectIdentifier` of the probed type.
/// Guarded by the standard library's `Mutex` — MMSchema stays NIO-free.
enum SchemaCache {
    private static let storage = Mutex<[ObjectIdentifier: TypeSchema]>([:])

    static func lookup(_ id: ObjectIdentifier) -> TypeSchema? {
        storage.withLock { $0[id] }
    }

    static func store(_ id: ObjectIdentifier, _ schema: TypeSchema) {
        storage.withLock { $0[id] = schema }
    }
}

// MARK: - The Decoder

/// The recording decoder handed to `T(from:)`. One instance per probed type
/// occurrence; confined to a single `of` call.
final class SchemaProbe: Decoder {
    let context: ProbeContext

    enum Shape {
        case unset
        case keyed(KeyedRecorder)
        case unkeyed(UnkeyedRecorder)
        case single(SingleRecorder)
    }

    private(set) var shape: Shape = .unset

    init(context: ProbeContext) {
        self.context = context
    }

    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    /// Repeated keyed-container requests share one recorder, so a class hierarchy
    /// decoding through a shared decoder (subclass keys, then `super.init(from:)`
    /// with the same decoder) merges its fields — mirroring the wire coder, whose
    /// encoder and decoder both hand back the same container for that pattern.
    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let recorder: KeyedRecorder
        if case .keyed(let existing) = shape {
            recorder = existing
        } else {
            recorder = KeyedRecorder()
            shape = .keyed(recorder)
        }
        return KeyedDecodingContainer(KeyedProbeContainer<Key>(probe: self, recorder: recorder))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let recorder = UnkeyedRecorder()
        shape = .unkeyed(recorder)
        return UnkeyedProbeContainer(probe: self, recorder: recorder)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        let recorder = SingleRecorder()
        shape = .single(recorder)
        return SingleValueProbeContainer(probe: self, recorder: recorder)
    }

    /// The schema assembled from whatever the probed decoder did.
    var assembled: TypeSchema {
        switch shape {
            case .unset:
                return .unknown
            case .keyed(let recorder):
                return .structure(fields: recorder.fields)
            case .unkeyed(let recorder):
                return .array(recorder.element ?? .unknown)
            case .single(let recorder):
                return recorder.schema ?? .unknown
        }
    }
}

final class KeyedRecorder {
    /// Fields in the order the decoder requested them — declaration order for
    /// synthesized `Codable`.
    var fields: [TypeSchema.Field] = []
}

final class UnkeyedRecorder {
    var element: TypeSchema?
    var consumed = false
}

final class SingleRecorder {
    var schema: TypeSchema?
}

// MARK: - Keyed container

struct KeyedProbeContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let probe: SchemaProbe
    let recorder: KeyedRecorder

    var codingPath: [any CodingKey] { [] }
    /// Empty on purpose: decoders that branch on present keys (associated-value
    /// enums) cannot be probed and must adopt ``SchemaDescribable``.
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool { true }

    /// Always `false`, so `decodeIfPresent`-style hand-written paths proceed to
    /// the typed decode. Optionality is recorded via `decodeIfPresent` only.
    func decodeNil(forKey key: Key) throws -> Bool { false }

    private func record(_ schema: TypeSchema, forKey key: Key) {
        recorder.fields.append(
            TypeSchema.Field(key: key.intValue, name: key.stringValue, type: schema))
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        record(.bool, forKey: key)
        return false
    }
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        record(.string, forKey: key)
        return ""
    }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        record(.double, forKey: key)
        return 0
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        record(.float, forKey: key)
        return 0
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        record(.int, forKey: key)
        return 0
    }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        record(.int, forKey: key)
        return 0
    }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        record(.int, forKey: key)
        return 0
    }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        record(.int, forKey: key)
        return 0
    }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        record(.int, forKey: key)
        return 0
    }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        record(.uint, forKey: key)
        return 0
    }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        record(.uint, forKey: key)
        return 0
    }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        record(.uint, forKey: key)
        return 0
    }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        record(.uint, forKey: key)
        return 0
    }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        record(.uint, forKey: key)
        return 0
    }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        switch TypeSchema.schemaFor(type, context: probe.context) {
            case .success(let schema):
                record(schema, forKey: key)
            case .failure(let error):
                throw ProbeSignal.nested(error)
        }
        return try TypeSchema.instanceFor(type, context: probe.context)
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        record(.optional(.bool), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        record(.optional(.string), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        record(.optional(.double), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        record(.optional(.float), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        record(.optional(.int), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
        record(.optional(.int), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
        record(.optional(.int), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        record(.optional(.int), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        record(.optional(.int), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? {
        record(.optional(.uint), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
        record(.optional(.uint), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
        record(.optional(.uint), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
        record(.optional(.uint), forKey: key)
        return nil
    }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        record(.optional(.uint), forKey: key)
        return nil
    }
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        switch TypeSchema.schemaFor(type, context: probe.context) {
            case .success(let schema):
                record(.optional(schema), forKey: key)
            case .failure(let error):
                throw ProbeSignal.nested(error)
        }
        return nil
    }

    /// Hand-written decoders using nested containers cannot be attributed a
    /// truthful shape; the field records as `.unknown` and such types should
    /// adopt ``SchemaDescribable``.
    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        record(.unknown, forKey: key)
        return try SchemaProbe(context: probe.context).container(keyedBy: NestedKey.self)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        record(.unknown, forKey: key)
        return try SchemaProbe(context: probe.context).unkeyedContainer()
    }

    /// Superclass fields decoded through `superDecoder()` cannot be attributed a
    /// truthful shape here (the wire form nests them under the string key
    /// `"super"`, and the child probe's recordings never merge back). Record the
    /// position as `.unknown` — matching the nested-container policy above — so
    /// the degradation is visible in the schema instead of the superclass fields
    /// silently vanishing. Such types should adopt ``SchemaDescribable``.
    func superDecoder() throws -> any Decoder {
        recorder.fields.append(TypeSchema.Field(key: nil, name: "super", type: .unknown))
        return SchemaProbe(context: probe.context)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        record(.unknown, forKey: key)
        return SchemaProbe(context: probe.context)
    }
}

// MARK: - Unkeyed container

struct UnkeyedProbeContainer: UnkeyedDecodingContainer {
    let probe: SchemaProbe
    let recorder: UnkeyedRecorder

    var codingPath: [any CodingKey] { [] }
    var count: Int? { nil }
    /// `false` exactly once, so the element type gets probed; `true` after the
    /// first decode.
    var isAtEnd: Bool { recorder.consumed }
    var currentIndex: Int { recorder.consumed ? 1 : 0 }

    mutating func decodeNil() throws -> Bool { false }

    private func record(_ schema: TypeSchema) {
        recorder.element = schema
        recorder.consumed = true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        record(.bool)
        return false
    }
    mutating func decode(_ type: String.Type) throws -> String {
        record(.string)
        return ""
    }
    mutating func decode(_ type: Double.Type) throws -> Double {
        record(.double)
        return 0
    }
    mutating func decode(_ type: Float.Type) throws -> Float {
        record(.float)
        return 0
    }
    mutating func decode(_ type: Int.Type) throws -> Int {
        record(.int)
        return 0
    }
    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        record(.int)
        return 0
    }
    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        record(.int)
        return 0
    }
    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        record(.int)
        return 0
    }
    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        record(.int)
        return 0
    }
    mutating func decode(_ type: UInt.Type) throws -> UInt {
        record(.uint)
        return 0
    }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        record(.uint)
        return 0
    }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        record(.uint)
        return 0
    }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        record(.uint)
        return 0
    }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        record(.uint)
        return 0
    }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        switch TypeSchema.schemaFor(type, context: probe.context) {
            case .success(let schema):
                record(schema)
            case .failure(let error):
                throw ProbeSignal.nested(error)
        }
        return try TypeSchema.instanceFor(type, context: probe.context)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        record(.unknown)
        return try SchemaProbe(context: probe.context).container(keyedBy: NestedKey.self)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        record(.unknown)
        return try SchemaProbe(context: probe.context).unkeyedContainer()
    }

    /// See the keyed container's `superDecoder()`: the position records as
    /// `.unknown` so the degradation is visible.
    mutating func superDecoder() throws -> any Decoder {
        record(.unknown)
        return SchemaProbe(context: probe.context)
    }
}

// MARK: - Single-value container

struct SingleValueProbeContainer: SingleValueDecodingContainer {
    let probe: SchemaProbe
    let recorder: SingleRecorder

    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { false }

    private func record(_ schema: TypeSchema) {
        recorder.schema = schema
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        record(.bool)
        return false
    }
    func decode(_ type: String.Type) throws -> String {
        record(.string)
        return ""
    }
    func decode(_ type: Double.Type) throws -> Double {
        record(.double)
        return 0
    }
    func decode(_ type: Float.Type) throws -> Float {
        record(.float)
        return 0
    }
    func decode(_ type: Int.Type) throws -> Int {
        record(.int)
        return 0
    }
    func decode(_ type: Int8.Type) throws -> Int8 {
        record(.int)
        return 0
    }
    func decode(_ type: Int16.Type) throws -> Int16 {
        record(.int)
        return 0
    }
    func decode(_ type: Int32.Type) throws -> Int32 {
        record(.int)
        return 0
    }
    func decode(_ type: Int64.Type) throws -> Int64 {
        record(.int)
        return 0
    }
    func decode(_ type: UInt.Type) throws -> UInt {
        record(.uint)
        return 0
    }
    func decode(_ type: UInt8.Type) throws -> UInt8 {
        record(.uint)
        return 0
    }
    func decode(_ type: UInt16.Type) throws -> UInt16 {
        record(.uint)
        return 0
    }
    func decode(_ type: UInt32.Type) throws -> UInt32 {
        record(.uint)
        return 0
    }
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        record(.uint)
        return 0
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        switch TypeSchema.schemaFor(type, context: probe.context) {
            case .success(let schema):
                record(schema)
            case .failure(let error):
                throw ProbeSignal.nested(error)
        }
        return try TypeSchema.instanceFor(type, context: probe.context)
    }
}

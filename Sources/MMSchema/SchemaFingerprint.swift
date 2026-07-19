/// The eight-byte schema fingerprint exchanged in the hello preamble.
///
/// ## Stability contract (wire)
///
/// The fingerprint is a **wire contract**: the same set of method signatures
/// must yield the same `UInt64` on every platform, every process launch, and
/// regardless of the order methods were registered in source. Concretely:
///
/// - Signatures are **sorted by name** (byte-wise over UTF-8) before hashing,
///   so source registration order never matters. Signatures sharing a name
///   (illegal in a router, but representable here) tie-break on their full
///   canonical encoding, so the sort is a total order and the fingerprint
///   stays order-insensitive even for duplicate names.
/// - Struct fields are hashed in **declaration order** (the order the probe
///   recorded them). Reordering a struct's fields changes the fingerprint even
///   though integer-keyed MessagePack maps make it wire-compatible — the
///   fingerprint is a fast-path "nothing changed" hint, and a mismatch only
///   triggers client-side discovery, never disconnection.
/// - The hash is an in-repo FNV-1a 64 (`Hasher` is per-process seeded and
///   unusable for wire), over a canonical byte encoding defined below.
///
/// ## Canonical encoding (internal to MMSchema)
///
/// A simple tagged, length-prefixed encoding — deliberately *not* MessagePack;
/// MMSchema cannot depend on MMWire. All integers little-endian:
///
/// - string: `u32 LE` byte count + UTF-8 bytes.
/// - signature: name string, access `u8` (raw bits), request schema, response
///   schema, then **tagged stream entries emitted only when present** — `u8`
///   tag 1 + element schema for a request stream, `u8` tag 2 + element schema
///   for a response stream. An absent stream emits nothing, so any unary-only
///   signature set hashes to exactly its pre-streaming value (a determinism
///   property, pinned by the golden test); the distinct tags keep the two
///   slots asymmetric.
/// - schema: `u8` case tag (the same tag values as the Codable wire encoding:
///   0 bool … 12 reference, 255 unknown), then payload —
///   `optional`/`array`: child schema; `map`: key then value schema;
///   `structure`: `u32 LE` field count, then per field: `u8` key-presence flag
///   (1/0), `i64 LE` key when present, name string, field schema;
///   `enumeration`: `u32 LE` case count, then per case: name string;
///   `reference`: the qualified name string.
/// - type definitions: after the signature stream, definitions sorted by name
///   (byte-wise, tie-break full encoding), each as `u8` tag **3** + name
///   string + schema. An empty type table appends nothing, so every type-free
///   fingerprint keeps its pre-types value.
/// - **descriptions are never hashed** — not the five signature doc slots, not
///   field, case, or definition descriptions. Doc edits are not schema drift.
public enum SchemaFingerprint {
    /// Computes the fingerprint of a method set and the named types it
    /// references. Order-insensitive in both lists; see the stability
    /// contract above.
    public static func compute(
        _ signatures: [MethodSignature],
        types: [TypeDefinition] = []
    ) -> UInt64 {
        // Each list is canonically encoded, sorted (name first, not encoding
        // first: the encoding starts with the name's u32 length prefix, which
        // would order "b" before "aa" and change every existing fingerprint),
        // and concatenated — signatures, then type definitions — into the one
        // hashed stream.
        let encodedSignatures = signatures.map { signature in
            (name: Array(signature.name.utf8), bytes: canonical(signature))
        }
        let encodedTypes = types.map { definition in
            (name: Array(definition.name.utf8), bytes: canonical(definition))
        }
        return fnv1a64(
            Self.sortedCanonically(encodedSignatures).flatMap(\.bytes)
                + Self.sortedCanonically(encodedTypes).flatMap(\.bytes)
        )
    }

    /// The canonical byte encoding of one signature.
    private static func canonical(_ signature: MethodSignature) -> [UInt8] {
        var bytes: [UInt8] = []
        append(signature, into: &bytes)
        return bytes
    }

    /// The canonical byte encoding of one type definition (tag 3 + name +
    /// schema).
    private static func canonical(_ definition: TypeDefinition) -> [UInt8] {
        var bytes: [UInt8] = [3]
        append(definition.name, into: &bytes)
        append(definition.schema, into: &bytes)
        return bytes
    }

    /// The canonical total order (§9.2), shared by the signature and
    /// type-definition streams: byte-wise by name, tie-break on the full
    /// canonical encoding.
    private static func sortedCanonically(
        _ entries: [(name: [UInt8], bytes: [UInt8])]
    ) -> [(name: [UInt8], bytes: [UInt8])] {
        entries.sorted { left, right in
            if left.name != right.name {
                return left.name.lexicographicallyPrecedes(right.name)
            }
            return left.bytes.lexicographicallyPrecedes(right.bytes)
        }
    }

    private static func append(_ signature: MethodSignature, into bytes: inout [UInt8]) {
        append(signature.name, into: &bytes)
        bytes.append(signature.access.rawValue)
        append(signature.request, into: &bytes)
        append(signature.response, into: &bytes)
        if let requestStream = signature.requestStream {
            bytes.append(1)
            append(requestStream, into: &bytes)
        }
        if let responseStream = signature.responseStream {
            bytes.append(2)
            append(responseStream, into: &bytes)
        }
    }

    private static func append(_ string: String, into bytes: inout [UInt8]) {
        let utf8 = Array(string.utf8)
        appendUInt32(UInt32(utf8.count), into: &bytes)
        bytes.append(contentsOf: utf8)
    }

    private static func appendUInt32(_ value: UInt32, into bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    private static func appendInt64(_ value: Int64, into bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    private static func append(_ schema: TypeSchema, into bytes: inout [UInt8]) {
        // One tag table: the canonical stream reuses the wire coder's
        // `TypeSchema.tag` numbers rather than restating them.
        bytes.append(schema.tag)
        switch schema {
            case .bool, .int, .uint, .float, .double, .string, .bytes, .unknown:
                break
            case .optional(let wrapped):
                append(wrapped, into: &bytes)
            case .array(let element):
                append(element, into: &bytes)
            case .map(let key, let value):
                append(key, into: &bytes)
                append(value, into: &bytes)
            case .structure(let fields):
                appendUInt32(UInt32(fields.count), into: &bytes)
                for field in fields {
                    if let key = field.key {
                        bytes.append(1)
                        appendInt64(Int64(key), into: &bytes)
                    } else {
                        bytes.append(0)
                    }
                    append(field.name, into: &bytes)
                    append(field.type, into: &bytes)
                }
            case .enumeration(let cases):
                appendUInt32(UInt32(cases.count), into: &bytes)
                for enumCase in cases {
                    append(enumCase.name, into: &bytes)
                }
            case .reference(let name):
                append(name, into: &bytes)
        }
    }

    /// Stable 64-bit FNV-1a; implemented in-repo because it is a wire
    /// contract. A fold from the offset basis: xor the byte, multiply by the
    /// prime.
    static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }
}

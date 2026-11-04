/// The escape hatch for types the probing decoder cannot walk.
///
/// ``TypeSchema/of(_:)`` checks this conformance **first** and short-circuits:
/// a conforming type's `init(from:)` is never executed by the probe.
///
/// ## Who must adopt this
///
/// The probe runs a type's decoder exactly once with zero values. Any type
/// whose `init(from:)` takes **data-dependent branches** therefore MUST adopt
/// `SchemaDescribable`, or its probed schema will be wrong or an error:
///
/// - enums with associated values (synthesized decoding switches on the
///   single present key — the probe presents none),
/// - version-switch decoders (`if version >= 2 { … }`),
/// - decoders that validate and reject zero values,
/// - types carrying raw bytes that should advertise ``TypeSchema/bytes``.
///
/// Plain structs of primitives, nested structs, optionals, arrays, and
/// `RawRepresentable` enums are handled automatically and do not need it.
public protocol SchemaDescribable {
    /// The wire shape this type encodes as.
    static var schema: TypeSchema { get }
}

/// A ``SchemaDescribable`` type that also hands the probe a placeholder value.
///
/// The probe builds every field of a *containing* struct by decoding zero
/// values. A self-described type whose decoder validates (a parsed identifier,
/// a tagged union) rejects those, which fails the containing type with
/// ``SchemaError/unconstructibleType(_:)``. Conforming types supply a valid
/// instance instead; the probe uses it only to keep walking, never on the wire.
public protocol SchemaPlaceholderProviding: SchemaDescribable {
    /// Any valid instance.
    static var schemaPlaceholder: Self { get }
}

extension SchemaPlaceholderProviding {
    static var _schemaPlaceholderAny: Any { schemaPlaceholder }
}

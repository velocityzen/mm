/// Typed error for the MMSchema layer, per the house convention of one error
/// enum per layer with exact `Result` assertions in tests.
public enum SchemaError: Error, Sendable, Hashable {
    /// The string is not a valid dotted entity path. Carries the offending
    /// string and the first rule it violated.
    case invalidEntityName(String, InvalidEntityNameReason)
    /// The schema probe could not construct a zero-value instance of a field's
    /// type, so the containing type's synthesized decoder could not be walked.
    /// Fix: make the field optional, conform the field's type to `CaseIterable`,
    /// or conform the *containing* type to ``SchemaDescribable``.
    /// The payload is the fully qualified name of the unconstructible type.
    case unconstructibleType(String)
    /// The type's `init(from:)` threw while being probed and did not record a
    /// recognizable shape. Typical cause: a hand-written decoder with
    /// data-dependent branches (associated-value enums, version switches).
    /// Fix: conform the type to ``SchemaDescribable``.
    /// The payload is the fully qualified name of the failing type.
    case probeFailed(String)
}

/// The specific validation rule an entity-name string violated.
public enum InvalidEntityNameReason: Sendable, Hashable {
    /// A segment between dots is empty: leading dot, trailing dot, or `..`.
    case emptySegment
    /// A character outside the allowed set `a-z`, `0-9`, `_`, `-`, `.`.
    case invalidCharacter
}

/// A dotted `domain.area.name` path identifying an entity in the tree.
///
/// ## Validation rules
///
/// A valid entity name is one or more segments joined by single dots. Each
/// segment is non-empty and drawn from the ASCII set `a-z`, `0-9`, `_`, `-`
/// (lowercase only — names are canonical, never case-folded). No leading dot,
/// no trailing dot, no empty segment (`..`). The empty string is reserved for
/// the distinguished ``root`` value and parses to it.
///
/// ## Root semantics
///
/// ``EntityName/root`` means "the whole entity tree". It never names a concrete
/// entity: it exists for discovery-style requests (`server.schema` scoped to root
/// asks about everything the peer can reach). Precisely:
///
/// - It encodes as the empty string on the wire and decodes back from it.
/// - It has no ``parent`` and no ``ancestors`` — there is nothing above it, so
///   the x-on-every-ancestor traversal rule never consults an ACL for root.
/// - Every non-root name `isDescendant(of: .root)`; root is a descendant of
///   nothing, including itself.
/// - `segments` is empty.
///
/// ## Codable
///
/// Encodes as a plain string in a single-value container. Decoding validates;
/// an invalid string fails the decode with `DecodingError.dataCorrupted`.
public struct EntityName: Sendable, Hashable {
    /// The full dotted path; empty exactly for ``root``.
    public let rawValue: String

    /// The whole entity tree. See the type documentation for exact semantics.
    public static let root = EntityName(validated: "")

    /// Trusted initializer for already-validated strings. Internal on purpose:
    /// all public construction goes through ``parse(_:)`` or `Decodable`.
    init(validated: String) {
        self.rawValue = validated
    }

    /// The validating initializer. Returns ``root`` for the empty string,
    /// otherwise enforces the rules documented on the type.
    public static func parse(_ string: String) -> Result<EntityName, SchemaError> {
        if string.isEmpty {
            return .success(.root)
        }
        var previousWasDot = true  // treats a leading dot as an empty segment
        for byte in string.utf8 {
            if byte == UInt8(ascii: ".") {
                if previousWasDot {
                    return .failure(.invalidEntityName(string, .emptySegment))
                }
                previousWasDot = true
            } else if EntityName.isAllowed(byte) {
                previousWasDot = false
            } else {
                return .failure(.invalidEntityName(string, .invalidCharacter))
            }
        }
        if previousWasDot {  // trailing dot
            return .failure(.invalidEntityName(string, .emptySegment))
        }
        return .success(EntityName(validated: string))
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"),
                UInt8(ascii: "_"),
                UInt8(ascii: "-"):
                return true
            default:
                return false
        }
    }

    /// True exactly for ``root``.
    public var isRoot: Bool {
        rawValue.isEmpty
    }

    /// The dot-separated segments in order; empty for ``root``.
    public var segments: [String] {
        guard !isRoot else { return [] }
        return rawValue.split(separator: ".").map(String.init)
    }

    /// All strictly-proper non-root prefixes, outermost first: the ancestors of
    /// `a.b.c` are `[a, a.b]`. A single-segment name and ``root`` have none.
    /// This is the traversal list for the x-on-every-ancestor rule; ``root`` is
    /// deliberately excluded (it carries no ACL).
    public var ancestors: [EntityName] {
        guard !isRoot else { return [] }
        var result: [EntityName] = []
        for index in rawValue.indices where rawValue[index] == "." {
            result.append(EntityName(validated: String(rawValue[..<index])))
        }
        return result
    }

    /// The immediate enclosing name: `a.b.c` → `a.b`. A single-segment name's
    /// parent is ``root`` (the tree encloses all top-level domains); ``root``
    /// itself has no parent.
    public var parent: EntityName? {
        guard !isRoot else { return nil }
        guard let lastDot = rawValue.lastIndex(of: ".") else { return .root }
        return EntityName(validated: String(rawValue[..<lastDot]))
    }

    /// True when `other` is a strict ancestor of `self` at a dot boundary.
    /// `a.b.c` is a descendant of `a.b` and `a`, but `a.bc` is not a descendant
    /// of `a.b` and `journal` is not a descendant of `jour`. Nothing is a
    /// descendant of itself. Every non-root name is a descendant of ``root``;
    /// ``root`` is a descendant of nothing.
    public func isDescendant(of other: EntityName) -> Bool {
        guard !isRoot else { return false }
        if other.isRoot { return true }
        return rawValue.hasPrefix(other.rawValue + ".")
    }
}

extension EntityName: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        switch EntityName.parse(string) {
            case .success(let name):
                self = name
            case .failure:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "invalid entity name: \(string)"
                    )
                )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension EntityName: SchemaDescribable {
    /// An entity name is a plain string on the wire.
    public static var schema: TypeSchema { .string }
}

extension EntityName: CustomStringConvertible {
    public var description: String {
        isRoot ? "(root)" : rawValue
    }
}

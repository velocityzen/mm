/// One pattern of target entities, in the vocabulary a call's declared
/// `Target` and a server route's `Accepts` share.
///
/// - ``all`` or `"*"`: any entity except root.
/// - `"journal.*"`: strict descendants of `journal`, at any depth. The
///   prefix entity itself is not included; list it as a pattern of its own
///   (`"journal"`) when it is a valid target too.
/// - `"tenants.*.journal"`: a `*` **segment** matches exactly one segment,
///   so `tenants.acme.journal` matches and `tenants.a.b.journal` does not.
///   Only a whole segment may be a wildcard (`"jour*"` is invalid), and
///   segment wildcards compose with the trailing form:
///   `"tenants.*.journal.*"` is any tenant's journal subtree.
/// - `"system.log"`: exactly that entity.
/// - ``root``: `EntityName.root`, the whole tree. Root is never matched by
///   `"*"` or any other pattern, only by ``root`` itself, and a string
///   literal never spells it: `""` is refused in source, so opting in to
///   root is always explicit.
///
/// One grammar rule underneath: a pattern is dot-separated segments, each
/// an entity-name segment (`a-z`, `0-9`, `_`, `-`) or `*` (exactly one
/// segment); a **trailing** `.*` means one or more further segments, at any
/// depth. Bare `"*"` is that rule's degenerate case: no prefix, any depth.
///
/// On the wire a pattern is its ``text``: the pattern as written, with root
/// as the empty string (root's entity name).
public struct EntityPattern: Sendable, Hashable, ExpressibleByStringLiteral {
    enum Segment: Sendable, Hashable {
        /// Matches this segment text exactly.
        case literal(String)
        /// `*`: matches exactly one segment, whatever its text.
        case anyOne
    }

    enum Kind: Sendable, Hashable {
        case root
        /// Match `segments` position for position; with `descendants`, one
        /// or more further segments must follow (so no segments with
        /// descendants is any entity except root).
        case entities(segments: [Segment], descendants: Bool)
    }

    let kind: Kind

    /// `EntityName.root` as a target.
    public static let root = EntityPattern(kind: .root)
    /// Any entity except root.
    public static let all = EntityPattern(kind: .entities(segments: [], descendants: true))

    /// The explicit spelling of the string grammar:
    /// `.entity("tenants.*.journal")` is `"tenants.*.journal"`. An invalid
    /// pattern, or the empty string, is a programmer error caught where the
    /// pattern is declared (`#schema` refuses it at compile time).
    public static func entity(_ pattern: String) -> EntityPattern {
        EntityPattern(declaring: pattern)
    }

    public init(stringLiteral value: String) {
        self.init(declaring: value)
    }

    init(kind: Kind) {
        self.kind = kind
    }

    private init(declaring pattern: String) {
        precondition(
            !pattern.isEmpty,
            "Entity pattern \"\" is not valid: write .root to target the whole tree"
        )
        switch Self.parse(pattern) {
            case .success(let parsed):
                self = parsed
            case .failure(let error):
                preconditionFailure("Entity pattern \"\(pattern)\" is not valid: \(error)")
        }
    }

    /// Reads a pattern's ``text``: the empty string is ``root``, anything
    /// else the grammar on the type.
    public static func parse(_ text: String) -> Result<EntityPattern, SchemaError> {
        if text.isEmpty {
            return .success(.root)
        }
        var raw = text.split(separator: ".", omittingEmptySubsequences: false)
        if raw.contains(where: \.isEmpty) {
            return .failure(.invalidEntityPattern(text, .emptySegment))
        }
        var descendants = false
        if raw.last == "*" {
            raw.removeLast()
            descendants = true
        }
        var segments: [Segment] = []
        for segment in raw {
            if segment == "*" {
                segments.append(.anyOne)
                continue
            }
            if segment.contains("*") {
                return .failure(.invalidEntityPattern(text, .partialWildcard))
            }
            // A lone segment is itself an entity name, so parsing it applies
            // the character rules.
            guard case .success = EntityName.parse(String(segment)) else {
                return .failure(.invalidEntityPattern(text, .invalidCharacter))
            }
            segments.append(.literal(String(segment)))
        }
        return .success(
            EntityPattern(kind: .entities(segments: segments, descendants: descendants))
        )
    }

    /// The pattern as the wire carries it: as written (`"journal.*"`,
    /// `"*"`), and the empty string for ``root``.
    public var text: String {
        switch kind {
            case .root:
                return ""
            case .entities(let segments, let descendants):
                let written = segments.map { segment -> String in
                    switch segment {
                        case .literal(let text): text
                        case .anyOne: "*"
                    }
                }
                return (written + (descendants ? ["*"] : [])).joined(separator: ".")
        }
    }

    /// Whether `entity` matches. Runs on every dispatch, so it compares the
    /// name's bytes in place instead of splitting it.
    public func admits(_ entity: EntityName) -> Bool {
        switch kind {
            case .root:
                return entity.isRoot

            case .entities(let segments, let descendants):
                guard !entity.isRoot else { return false }
                let name = entity.rawValue.utf8
                let entitySegmentCount = name.count(where: { $0 == UInt8(ascii: ".") }) + 1
                guard
                    descendants
                        ? entitySegmentCount > segments.count
                        : entitySegmentCount == segments.count
                else {
                    return false
                }
                var start = name.startIndex
                for segment in segments {
                    let end = name[start...].firstIndex(of: UInt8(ascii: ".")) ?? name.endIndex
                    if case .literal(let text) = segment,
                        !text.utf8.elementsEqual(name[start..<end])
                    {
                        return false
                    }
                    start = end == name.endIndex ? end : name.index(after: end)
                }
                return true
        }
    }

    /// Whether every entity this pattern matches, `other` matches too. A
    /// segment name can be anything, so a wildcard falls within only a
    /// wildcard, and a set of patterns covers this one only when one of them
    /// does.
    public func isWithin(_ other: EntityPattern) -> Bool {
        switch (kind, other.kind) {
            case (.root, .root):
                return true
            case (.root, .entities), (.entities, .root):
                return false
            case (
                .entities(let segments, let descendants), .entities(let outer, let outerDescendants)
            ):
                let depthFits: Bool
                switch (descendants, outerDescendants) {
                    // A fixed depth within a fixed depth: the same depth.
                    case (false, false): depthFits = segments.count == outer.count
                    // A fixed depth within "deeper than the outer prefix".
                    case (false, true): depthFits = segments.count > outer.count
                    // Every depth past a prefix never fits one fixed depth.
                    case (true, false): depthFits = false
                    // Every depth past a prefix within every depth past a
                    // prefix no longer than it.
                    case (true, true): depthFits = segments.count >= outer.count
                }
                guard depthFits else { return false }
                return zip(segments, outer).allSatisfy { inner, outer in
                    switch (inner, outer) {
                        case (_, .anyOne): true
                        case (.literal(let text), .literal(let outerText)): text == outerText
                        case (.anyOne, .literal): false
                    }
                }
        }
    }

    /// The literal start every match shares, for completion: `"journal."`
    /// for `"journal.*"`, `"tenants."` for `"tenants.*.journal"`, the entity
    /// itself for `"system.log"`, and empty when the first segment is a
    /// wildcard or the pattern is ``root``.
    public var literalPrefix: String {
        guard case .entities(let segments, let descendants) = kind else { return "" }
        var literals: [String] = []
        for segment in segments {
            guard case .literal(let text) = segment else { break }
            literals.append(text)
        }
        guard !literals.isEmpty else { return "" }
        let complete = literals.count == segments.count && !descendants
        return literals.joined(separator: ".") + (complete ? "" : ".")
    }

    /// The one entity this pattern names, when it names exactly one: all
    /// literal segments, no trailing depth. Nil for root and for any pattern
    /// with a wildcard.
    var entity: EntityName? {
        guard case .entities(let segments, descendants: false) = kind, !segments.isEmpty else {
            return nil
        }
        var literals: [String] = []
        for segment in segments {
            guard case .literal(let text) = segment else { return nil }
            literals.append(text)
        }
        // Validated segments joined by dots are a valid name.
        return EntityName(validated: literals.joined(separator: "."))
    }
}

extension EntityPattern: CustomStringConvertible {
    /// The ``text``, with root shown as `(root)` like `EntityName`'s.
    public var description: String {
        kind == .root ? "(root)" : text
    }
}

extension EntityPattern: Codable {
    /// Encodes as the ``text`` in a single-value container.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    /// Decodes a ``text``; an invalid pattern fails the decode with
    /// `DecodingError.dataCorrupted`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        switch Self.parse(text) {
            case .success(let pattern):
                self = pattern
            case .failure(let error):
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "invalid entity pattern \"\(text)\": \(error)"
                )
        }
    }
}

extension EntityPattern {
    /// A set of patterns as a contract states it: each pattern once, in
    /// byte-wise order of its ``text``. Order means nothing (an entity
    /// matches when any pattern does), so declarations, discovery and the
    /// fingerprint all see this one form.
    public static func normalized(_ patterns: [EntityPattern]) -> [EntityPattern] {
        var seen: Set<EntityPattern> = []
        return
            patterns
            .filter { seen.insert($0).inserted }
            .sorted { $0.text.utf8.lexicographicallyPrecedes($1.text.utf8) }
    }

    /// Whether any of `patterns` matches `entity`.
    public static func admits(_ patterns: [EntityPattern], _ entity: EntityName) -> Bool {
        patterns.contains { $0.admits(entity) }
    }

    /// The single concrete entity `patterns` name, when they name exactly
    /// one: one pattern, all literal, no trailing depth (`"system.log"`).
    /// A caller may omit such a target; it means that entity.
    public static func soleEntity(of patterns: [EntityPattern]) -> EntityName? {
        guard patterns.count == 1 else { return nil }
        return patterns[0].entity
    }

    /// The first of `patterns` that falls within none of `outer`, or nil
    /// when every one falls within some pattern of `outer`.
    public static func firstOutside(
        _ patterns: [EntityPattern],
        _ outer: [EntityPattern]
    ) -> EntityPattern? {
        patterns.first { pattern in !outer.contains { pattern.isWithin($0) } }
    }

    /// The patterns' text for a message: `journal.*`, or
    /// `journal, journal.*` for several.
    public static func listed(_ patterns: [EntityPattern]) -> String {
        patterns.map(\.description).joined(separator: ", ")
    }
}

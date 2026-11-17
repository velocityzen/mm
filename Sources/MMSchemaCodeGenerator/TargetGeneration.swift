import SwiftSyntax

// MARK: - Declared targets

// The macro reads `Target(...)` patterns without MMSchema, by the grammar of
// the runtime's `EntityPattern`, and must refuse exactly what the runtime
// refuses: the property tests compare the two readings.

/// One `Target(...)` pattern as the macro reads it.
package struct TargetPattern: Hashable {
    package enum Segment: Hashable {
        case literal(String)
        case anyOne
    }

    /// True for `.root`; `segments` and `descendants` are then unused.
    package var isRoot: Bool
    package var segments: [Segment]
    package var descendants: Bool

    static let root = TargetPattern(isRoot: true, segments: [], descendants: false)
    static let all = TargetPattern(isRoot: false, segments: [], descendants: true)

    /// The runtime's `EntityPattern.text`: as written, the empty string for
    /// root.
    package var text: String {
        guard !isRoot else { return "" }
        let written = segments.map { segment -> String in
            switch segment {
                case .literal(let text): text
                case .anyOne: "*"
            }
        }
        return (written + (descendants ? ["*"] : [])).joined(separator: ".")
    }

    /// The text for help and messages: `(root)` for root.
    var shown: String { isRoot ? "(root)" : text }

    /// The source expression that rebuilds the pattern at runtime.
    var expression: String { isRoot ? ".root" : quoted(text) }

    /// The one entity the pattern names: all literal segments, no trailing
    /// depth.
    package var entity: String? {
        guard !isRoot, !descendants, !segments.isEmpty else { return nil }
        var literals: [String] = []
        for segment in segments {
            guard case .literal(let text) = segment else { return nil }
            literals.append(text)
        }
        return literals.joined(separator: ".")
    }

    /// The literal start every match shares, as the runtime's
    /// `EntityPattern.literalPrefix` gives it.
    package var literalPrefix: String {
        guard !isRoot else { return "" }
        var literals: [String] = []
        for segment in segments {
            guard case .literal(let text) = segment else { break }
            literals.append(text)
        }
        guard !literals.isEmpty else { return "" }
        let complete = literals.count == segments.count && !descendants
        return literals.joined(separator: ".") + (complete ? "" : ".")
    }
}

/// Why a pattern's text is refused, worded as the runtime's
/// `InvalidEntityPatternReason`.
package enum TargetPatternProblem: Error, Equatable {
    case empty
    case emptySegment
    case invalidCharacter
    case partialWildcard

    var message: String {
        switch self {
            case .empty: "write .root to target the whole tree"
            case .emptySegment: "a segment is empty"
            case .invalidCharacter: "a segment holds a character outside a-z, 0-9, _ and -"
            case .partialWildcard: "only a whole segment may be a wildcard"
        }
    }
}

/// Reads a pattern written as a string literal, by the runtime grammar. The
/// empty string is refused: in source, root is always `.root`.
package func targetPattern(parsing text: String) -> Result<TargetPattern, TargetPatternProblem> {
    guard !text.isEmpty else { return .failure(.empty) }
    var raw = text.split(separator: ".", omittingEmptySubsequences: false)
    if raw.contains(where: \.isEmpty) {
        return .failure(.emptySegment)
    }
    var descendants = false
    if raw.last == "*" {
        raw.removeLast()
        descendants = true
    }
    var segments: [TargetPattern.Segment] = []
    for segment in raw {
        if segment == "*" {
            segments.append(.anyOne)
            continue
        }
        if segment.contains("*") {
            return .failure(.partialWildcard)
        }
        let allowed = segment.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
        guard allowed else { return .failure(.invalidCharacter) }
        segments.append(.literal(String(segment)))
    }
    return .success(TargetPattern(isRoot: false, segments: segments, descendants: descendants))
}

/// Each pattern once, in byte-wise order of its text: the runtime's
/// `EntityPattern.normalized`.
func normalizedTarget(_ patterns: [TargetPattern]) -> [TargetPattern] {
    var seen: Set<TargetPattern> = []
    return
        patterns
        .filter { seen.insert($0).inserted }
        .sorted { $0.text.utf8.lexicographicallyPrecedes($1.text.utf8) }
}

/// Parses `Target(.root, .all, "journal.*", .entity("system.log"))`.
func parseTarget(_ call: FunctionCallExprSyntax, context: String) throws -> [TargetPattern] {
    guard call.trailingClosure == nil else {
        throw SchemaMacroError(description: "\(context): Target takes patterns, not a block")
    }
    var patterns: [TargetPattern] = []
    for argument in call.arguments {
        guard argument.label == nil else {
            throw SchemaMacroError(
                description:
                    "\(context): Target takes unlabeled patterns, got \(argument.trimmedDescription)"
            )
        }
        patterns.append(try targetPattern(argument: argument.expression, context: context))
    }
    guard !patterns.isEmpty else {
        throw SchemaMacroError(
            description:
                "\(context): Target() with no patterns would refuse every entity — declare at least one"
        )
    }
    return normalizedTarget(patterns)
}

/// One `Target` argument: a string literal, `.root`, `.all` or
/// `.entity("...")`, optionally spelled `EntityPattern.x`.
private func targetPattern(argument expression: ExprSyntax, context: String) throws -> TargetPattern
{
    let source = expression.trimmedDescription
    if let text = stringLiteral(expression) {
        return try checkedTargetPattern(text, context: context)
    }
    if let member = expression.as(MemberAccessExprSyntax.self), isEntityPatternBase(member.base) {
        switch member.declName.baseName.text {
            case "root": return .root
            case "all": return .all
            default: break
        }
    }
    if let call = expression.as(FunctionCallExprSyntax.self),
        let member = call.calledExpression.as(MemberAccessExprSyntax.self),
        isEntityPatternBase(member.base),
        member.declName.baseName.text == "entity",
        call.arguments.count == 1,
        call.arguments.first?.label == nil,
        call.trailingClosure == nil,
        let argument = call.arguments.first?.expression,
        let text = stringLiteral(argument)
    {
        return try checkedTargetPattern(text, context: context)
    }
    throw SchemaMacroError(
        description:
            "\(context): a Target pattern is a string literal, .root, .all or .entity(\"...\"), got \(source)"
    )
}

private func isEntityPatternBase(_ base: ExprSyntax?) -> Bool {
    guard let base else { return true }
    return base.trimmedDescription == "EntityPattern"
        || base.trimmedDescription == "MMSchema.EntityPattern"
}

private func checkedTargetPattern(_ text: String, context: String) throws -> TargetPattern {
    switch targetPattern(parsing: text) {
        case .success(let pattern):
            return pattern
        case .failure(let problem):
            throw SchemaMacroError(
                description:
                    "\(context): Target pattern \(quoted(text)) is not valid: \(problem.message)"
            )
    }
}

/// The patterns for help and messages: `journal, journal.*`.
func listedTarget(_ patterns: [TargetPattern]) -> String {
    patterns.map(\.shown).joined(separator: ", ")
}

/// The descriptor's `target:` argument, or empty for an undeclared target.
func targetArgument(for call: ParsedCall) -> String {
    guard let target = call.target else { return "" }
    return ", target: [\(target.map(\.expression).joined(separator: ", "))]"
}

/// The entity a sole-entity target names: one pattern, all literal, no
/// trailing depth.
func soleTargetEntity(_ patterns: [TargetPattern]?) -> String? {
    guard let patterns, patterns.count == 1 else { return nil }
    return patterns[0].entity
}

/// What completion offers for the entity: each pattern's literal prefix,
/// once, skipping patterns that start with a wildcard and root.
func targetCompletions(_ patterns: [TargetPattern]) -> [String] {
    var seen: Set<String> = []
    return patterns.map(\.literalPrefix).filter { !$0.isEmpty && seen.insert($0).inserted }
}

/// The generated entity argument's help: the declared target, and what
/// omitting the entity means.
func entityHelpText(_ target: [TargetPattern]?) -> String {
    guard let target else {
        return
            "Target entity (dotted path); omit when the daemon's route accepts exactly one entity"
    }
    if let entity = soleTargetEntity(target) {
        return "Target entity; omit for \(entity), the call's one target"
    }
    let entities = target.filter { !$0.isRoot }
    guard !entities.isEmpty else {
        return "Omit: the call targets the whole tree"
    }
    let within = "Target entity (dotted path) within \(listedTarget(entities))"
    return target.contains(.root) ? within + "; omit for the whole tree" : within
}

/// The generated entity argument's `completion:` argument: the target's
/// literal prefixes, or nothing when it has none.
func entityCompletion(_ target: [TargetPattern]?) -> String {
    guard let target else { return "" }
    let completions = targetCompletions(target)
    guard !completions.isEmpty else { return "" }
    return ", completion: .list([\(completions.map(quoted).joined(separator: ", "))])"
}

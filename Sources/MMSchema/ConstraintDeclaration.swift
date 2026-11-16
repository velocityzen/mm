/// One rule in a field's or a named scalar's `constraints:` list:
///
/// ```swift
/// Field("limit", .int, constraints: .range(1...1000))
/// Field("ratio", .double, constraints: .range(0.0...1.0))
/// Field("title", .string, constraints: .length(1...200))
/// Field("tags", .array(.string), constraints: .nonEmpty)
/// Alias("Slug", .string, constraints: .length(1...64), .pattern("[a-z0-9-]+"))
/// ```
///
/// A list holds at most one range, one length (``nonEmpty`` is a length)
/// and one pattern. See ``TypeSchema/Constraints`` for what each rule means
/// and which kinds take it.
public struct Constraint: Sendable, Hashable {
    enum Rule: Sendable, Hashable {
        case range(minimum: TypeSchema.Bound?, maximum: TypeSchema.Bound?)
        case length(minimum: Int?, maximum: Int?)
        case pattern(String)

        var kind: String {
            switch self {
                case .range: "range"
                case .length: "length"
                case .pattern: "pattern"
            }
        }
    }

    let rule: Rule

    /// An integer range, both ends inclusive, for an `int` or `uint` value.
    /// On a `float` or `double` value its bounds become floating ones.
    public static func range(_ range: ClosedRange<Int>) -> Constraint {
        Constraint(
            rule: .range(
                minimum: .integer(Int64(range.lowerBound)),
                maximum: .integer(Int64(range.upperBound))
            )
        )
    }

    /// An integer range with no upper end: `.range(1...)`.
    public static func range(_ range: PartialRangeFrom<Int>) -> Constraint {
        Constraint(rule: .range(minimum: .integer(Int64(range.lowerBound)), maximum: nil))
    }

    /// An integer range with no lower end: `.range(...100)`.
    public static func range(_ range: PartialRangeThrough<Int>) -> Constraint {
        Constraint(rule: .range(minimum: nil, maximum: .integer(Int64(range.upperBound))))
    }

    /// A floating range, both ends inclusive, for a `float` or `double`
    /// value. Its bounds are finite.
    public static func range(_ range: ClosedRange<Double>) -> Constraint {
        Constraint(
            rule: .range(
                minimum: .floating(range.lowerBound),
                maximum: .floating(range.upperBound)
            )
        )
    }

    /// A floating range with no upper end: `.range(0.0...)`.
    public static func range(_ range: PartialRangeFrom<Double>) -> Constraint {
        Constraint(rule: .range(minimum: .floating(range.lowerBound), maximum: nil))
    }

    /// A floating range with no lower end: `.range(...1.0)`.
    public static func range(_ range: PartialRangeThrough<Double>) -> Constraint {
        Constraint(rule: .range(minimum: nil, maximum: .floating(range.upperBound)))
    }

    /// A length, both ends inclusive: a string's Unicode scalars, a byte
    /// string's bytes, an array's elements or a map's entries.
    public static func length(_ range: ClosedRange<Int>) -> Constraint {
        Constraint(rule: .length(minimum: range.lowerBound, maximum: range.upperBound))
    }

    /// A length with no upper end: `.length(1...)`.
    public static func length(_ range: PartialRangeFrom<Int>) -> Constraint {
        Constraint(rule: .length(minimum: range.lowerBound, maximum: nil))
    }

    /// A length with no lower end: `.length(...200)`.
    public static func length(_ range: PartialRangeThrough<Int>) -> Constraint {
        Constraint(rule: .length(minimum: nil, maximum: range.upperBound))
    }

    /// A length of at least one: `.length(1...)`.
    public static let nonEmpty = Constraint.length(1...)

    /// A regular expression a string matches whole, as if written `^...$`,
    /// in the syntax ECMAScript and PCRE share.
    public static func pattern(_ pattern: String) -> Constraint {
        Constraint(rule: .pattern(pattern))
    }
}

/// The constraints a `constraints:` list declares on a value of `type`, or
/// nil for an empty list. Integer bounds on a `float` or `double` value
/// become floating ones; a rule that does not fit the kind, a second rule of
/// one kind, a non-finite bound or a pattern that does not compile is
/// programmer error.
func combinedConstraints(
    _ rules: [Constraint],
    for type: TypeSchema,
    context: String
) -> TypeSchema.Constraints? {
    guard !rules.isEmpty else { return nil }
    if let duplicate = firstDuplicate(rules.map(\.rule.kind)) {
        preconditionFailure("\(context) declares a \(duplicate) twice")
    }
    var kind = type
    while case .optional(let wrapped) = kind { kind = wrapped }
    let floatingKind = kind == .float || kind == .double
    func bound(_ bound: TypeSchema.Bound?) -> TypeSchema.Bound? {
        switch bound {
            case .integer(let value) where floatingKind:
                return .floating(Double(value))
            case .floating(let value):
                precondition(value.isFinite, "\(context) declares a non-finite bound")
                // -0.0 and 0.0 are one bound; keep one encoding of it.
                return .floating(value == 0 ? 0 : value)
            default:
                return bound
        }
    }
    var constraints = TypeSchema.Constraints()
    for constraint in rules {
        switch constraint.rule {
            case .range(let minimum, let maximum):
                constraints.minimum = bound(minimum)
                constraints.maximum = bound(maximum)
            case .length(let minimum, let maximum):
                constraints.minimumLength = minimum
                constraints.maximumLength = maximum
            case .pattern(let pattern):
                constraints.pattern = pattern
        }
    }
    if let problem = constraints.problem(applyingTo: type) {
        preconditionFailure("\(context): \(problem)")
    }
    return constraints
}

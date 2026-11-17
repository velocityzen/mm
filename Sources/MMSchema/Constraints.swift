import Synchronization

extension TypeSchema {
    /// The rules a value keeps beyond its shape, declared on a field
    /// (`Field("limit", .int, constraints: .range(1...1000))`) or on a named
    /// scalar (`Alias("Slug", .string, constraints: .pattern("[a-z0-9-]+"))`).
    ///
    /// Each rule applies to the value itself, after an optional is
    /// unwrapped:
    ///
    /// - ``minimum`` and ``maximum`` bound a number or a duration, both ends
    ///   inclusive: an integer bound on `int` and `uint`, a floating one on
    ///   `float` and `double`, a duration on `duration`.
    /// - ``minimumLength`` and ``maximumLength`` bound a length, both ends
    ///   inclusive: a string's Unicode scalars (`"café"` is 4 precomposed and
    ///   5 decomposed), a byte string's bytes, an array's elements, a map's
    ///   entries.
    /// - ``pattern`` is a regular expression a string matches whole, as if
    ///   written `^...$`, in the syntax ECMAScript and PCRE share.
    ///
    /// ## Wire encoding (fixed)
    ///
    /// A map with integer keys, each rule left out when absent: **0** the
    /// minimum and **1** the maximum (a number, or for a duration a `bin`
    /// holding its binary form), **2** the minimum length
    /// and **3** the maximum length (non-negative integers), **4** the
    /// pattern (a string). A rule this peer cannot read decodes as absent,
    /// like a key it does not know, so an older peer sees a value as less
    /// constrained, never as unreadable.
    public struct Constraints: Sendable, Hashable {
        public var minimum: Bound?
        public var maximum: Bound?
        public var minimumLength: Int?
        public var maximumLength: Int?
        public var pattern: String?

        public init(
            minimum: Bound? = nil,
            maximum: Bound? = nil,
            minimumLength: Int? = nil,
            maximumLength: Int? = nil,
            pattern: String? = nil
        ) {
            self.minimum = minimum
            self.maximum = maximum
            self.minimumLength = minimumLength
            self.maximumLength = maximumLength
            self.pattern = pattern
        }

        /// Whether no rule is set.
        public var isEmpty: Bool {
            self.minimum == nil && self.maximum == nil && self.minimumLength == nil
                && self.maximumLength == nil && self.pattern == nil
        }

        enum CodingKeys: Int, CodingKey {
            case minimum = 0
            case maximum = 1
            case minimumLength = 2
            case maximumLength = 3
            case pattern = 4
        }
    }

    /// One end of a range: an integer for `int` and `uint` values, a finite
    /// floating-point number for `float` and `double` values, a duration for
    /// `duration` values.
    public enum Bound: Sendable, Hashable, CustomStringConvertible {
        case integer(Int64)
        case floating(Double)
        case duration(MMDuration)

        public var description: String {
            switch self {
                case .integer(let value): "\(value)"
                case .floating(let value): "\(value)"
                case .duration(let value): "\(value)"
            }
        }
    }
}

extension TypeSchema.Constraints: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.minimum, forKey: .minimum)
        try container.encodeIfPresent(self.maximum, forKey: .maximum)
        try container.encodeIfPresent(self.minimumLength, forKey: .minimumLength)
        try container.encodeIfPresent(self.maximumLength, forKey: .maximumLength)
        try container.encodeIfPresent(self.pattern, forKey: .pattern)
    }

    /// Never throws for a rule it cannot read: that rule decodes as absent.
    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        func length(_ key: CodingKeys) -> Int? {
            (try? container.decodeIfPresent(Int.self, forKey: key)).flatMap { $0 }
                .flatMap { $0 >= 0 ? $0 : nil }
        }
        self.init(
            minimum: (try? container.decodeIfPresent(TypeSchema.Bound.self, forKey: .minimum))
                .flatMap { $0 },
            maximum: (try? container.decodeIfPresent(TypeSchema.Bound.self, forKey: .maximum))
                .flatMap { $0 },
            minimumLength: length(.minimumLength),
            maximumLength: length(.maximumLength),
            pattern: (try? container.decodeIfPresent(String.self, forKey: .pattern)).flatMap { $0 }
        )
    }
}

extension TypeSchema.Bound: SchemaDescribable {
    /// A bound is an integer, a floating number or a duration, and its
    /// decoder reads whichever the value is, so its shape depends on the
    /// value: `unknown` by construction, as for ``TypeSchema``'s own payload
    /// slots.
    public static var schema: TypeSchema { .unknown }
}

extension TypeSchema.Bound: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case .integer(let value): try container.encode(value)
            case .floating(let value): try container.encode(value)
            // A `bin` holding the binary form on the wire, ISO 8601 text in
            // JSON: the coders' own form of a duration.
            case .duration(let value): try container.encode(value)
        }
    }

    /// An integer reads as ``integer(_:)``, any other number as
    /// ``floating(_:)``, a duration as ``duration(_:)``; a non-finite number
    /// or an integer past `Int64.max` is no bound.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
            return
        }
        if let floating = try? container.decode(Double.self) {
            guard floating.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "a bound is a finite number"
                )
            }
            self = .floating(floating)
            return
        }
        self = .duration(try container.decode(MMDuration.self))
    }
}

// MARK: - Checking

extension TypeSchema.Constraints {
    /// Why an integer breaks these constraints, or nil when it keeps them.
    public func violation(of value: Int64) -> String? {
        if let minimum, Self.isBelow(value, minimum) {
            return "is \(value), less than the minimum \(minimum)"
        }
        if let maximum, Self.isAbove(value, maximum) {
            return "is \(value), more than the maximum \(maximum)"
        }
        return nil
    }

    /// Why an unsigned integer breaks these constraints, or nil when it
    /// keeps them.
    public func violation(of value: UInt64) -> String? {
        if let minimum, Self.isBelow(value, minimum) {
            return "is \(value), less than the minimum \(minimum)"
        }
        if let maximum, Self.isAbove(value, maximum) {
            return "is \(value), more than the maximum \(maximum)"
        }
        return nil
    }

    /// Why a floating-point number breaks these constraints, or nil when it
    /// keeps them. NaN keeps no range.
    public func violation(of value: Double) -> String? {
        if value.isNaN, self.minimum != nil || self.maximum != nil {
            return "is not a number, outside every range"
        }
        if let minimum, let limit = minimum.doubleValue, value < limit {
            return "is \(value), less than the minimum \(minimum)"
        }
        if let maximum, let limit = maximum.doubleValue, value > limit {
            return "is \(value), more than the maximum \(maximum)"
        }
        return nil
    }

    /// Whether either end of the range is a duration.
    var hasDurationBound: Bool {
        if case .duration? = self.minimum { return true }
        if case .duration? = self.maximum { return true }
        return false
    }

    /// Why a duration breaks these constraints, or nil when it keeps them.
    /// Only duration bounds bound a duration.
    public func violation(of value: MMDuration) -> String? {
        if case .duration(let limit)? = self.minimum, value < limit {
            return "is \(value), less than the minimum \(limit)"
        }
        if case .duration(let limit)? = self.maximum, value > limit {
            return "is \(value), more than the maximum \(limit)"
        }
        return nil
    }

    /// Why a length — a string's Unicode scalars, a byte string's bytes, an
    /// array's elements, a map's entries — breaks these constraints, or nil
    /// when it keeps them.
    public func violation(ofLength length: Int) -> String? {
        if let minimumLength, length < minimumLength {
            return "has length \(length), less than the minimum length \(minimumLength)"
        }
        if let maximumLength, length > maximumLength {
            return "has length \(length), more than the maximum length \(maximumLength)"
        }
        return nil
    }

    /// Why a string breaks these constraints, or nil when it keeps them:
    /// its length in Unicode scalars first, then its pattern. The pattern is
    /// compiled for this one check; ``TypeSchema/ConstraintChecker`` keeps
    /// it compiled across checks.
    public func violation(of value: String) -> String? {
        if let problem = self.violation(ofLength: value.unicodeScalars.count) {
            return problem
        }
        guard let pattern else { return nil }
        return Self.matches(value, pattern: pattern) ? nil : Self.patternProblem(pattern)
    }

    /// Whether `value` matches `pattern` whole. A pattern that does not
    /// compile matches nothing.
    static func matches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? Regex(pattern) else { return false }
        return value.wholeMatch(of: regex) != nil
    }

    static func patternProblem(_ pattern: String) -> String {
        "does not match the pattern \(pattern)"
    }

    // A duration bound bounds no number.

    private static func isBelow(_ value: Int64, _ bound: TypeSchema.Bound) -> Bool {
        switch bound {
            case .integer(let limit): value < limit
            case .floating(let limit): Double(value) < limit
            case .duration: false
        }
    }

    private static func isAbove(_ value: Int64, _ bound: TypeSchema.Bound) -> Bool {
        switch bound {
            case .integer(let limit): value > limit
            case .floating(let limit): Double(value) > limit
            case .duration: false
        }
    }

    private static func isBelow(_ value: UInt64, _ bound: TypeSchema.Bound) -> Bool {
        switch bound {
            case .integer(let limit): limit >= 0 && value < UInt64(limit)
            case .floating(let limit): Double(value) < limit
            case .duration: false
        }
    }

    private static func isAbove(_ value: UInt64, _ bound: TypeSchema.Bound) -> Bool {
        switch bound {
            case .integer(let limit): limit < 0 || value > UInt64(limit)
            case .floating(let limit): Double(value) > limit
            case .duration: false
        }
    }
}

extension TypeSchema.Bound {
    /// The bound as a number; nil for a duration.
    var doubleValue: Double? {
        switch self {
            case .integer(let value): Double(value)
            case .floating(let value): value
            case .duration: nil
        }
    }

    /// Whether this bound lies above `other`: exactly for two integers,
    /// which a `Double` cannot tell apart near the ends of `Int64`, and for
    /// two durations. A number and a duration are not ordered.
    func isMore(than other: Self) -> Bool {
        switch (self, other) {
            case (.integer(let value), .integer(let otherValue)):
                return value > otherValue
            case (.duration(let value), .duration(let otherValue)):
                return value > otherValue
            case (.duration, _), (_, .duration):
                return false
            default:
                return self.doubleValue! > other.doubleValue!
        }
    }
}

extension TypeSchema {
    /// A field's or a named scalar's constraints, ready to check values of
    /// the generated Swift types many times: the pattern is compiled once
    /// and matched under a lock, since a compiled `Regex` is not `Sendable`.
    public final class ConstraintChecker: Sendable {
        public let constraints: Constraints
        private let compiled: Mutex<Regex<AnyRegexOutput>?>

        public init(_ constraints: Constraints) {
            self.constraints = constraints
            self.compiled = Mutex(constraints.pattern.flatMap { try? Regex($0) })
        }

        public func violation(of value: Int64) -> String? {
            self.constraints.violation(of: value)
        }

        public func violation(of value: UInt64) -> String? {
            self.constraints.violation(of: value)
        }

        public func violation(of value: Double) -> String? {
            self.constraints.violation(of: value)
        }

        public func violation(of value: MMDuration) -> String? {
            self.constraints.violation(of: value)
        }

        public func violation(ofLength length: Int) -> String? {
            self.constraints.violation(ofLength: length)
        }

        /// Why a string breaks these constraints: its length in Unicode
        /// scalars first, then its pattern.
        public func violation(of value: String) -> String? {
            if let problem = self.constraints.violation(ofLength: value.unicodeScalars.count) {
                return problem
            }
            guard let pattern = self.constraints.pattern else { return nil }
            let matched = self.compiled.withLock { regex in
                regex.map { value.wholeMatch(of: $0) != nil } ?? false
            }
            return matched ? nil : Constraints.patternProblem(pattern)
        }
    }
}

// MARK: - Where rules apply

extension TypeSchema.Constraints {
    /// Why these constraints cannot apply to a value of `schema` (optionals
    /// unwrapped), or nil when every rule fits its kind. A field of a named
    /// type takes its constraints from the type. Shared by the runtime DSL;
    /// `#schema` applies the same rules to its source.
    public func problem(applyingTo schema: TypeSchema) -> String? {
        var kind = schema
        while case .optional(let wrapped) = kind { kind = wrapped }
        if case .reference(let name) = kind {
            return "a field of the named type \(name) takes its constraints from the type"
        }
        if self.minimum != nil || self.maximum != nil {
            let bounds = [self.minimum, self.maximum].compactMap { $0 }
            switch kind {
                case .int, .uint:
                    for bound in bounds {
                        guard case .integer = bound else {
                            return "a range on \(kind.kindName) takes integer bounds"
                        }
                    }
                case .float, .double:
                    for case .duration in bounds {
                        return "a range on \(kind.kindName) takes numeric bounds"
                    }
                case .duration:
                    for bound in bounds {
                        guard case .duration = bound else {
                            return "a range on duration takes duration bounds"
                        }
                    }
                default:
                    return
                        "a range applies to int, uint, float, double or duration, not \(kind.kindName)"
            }
        }
        if let minimum, let maximum, minimum.isMore(than: maximum) {
            return "a range's minimum \(minimum) is more than its maximum \(maximum)"
        }
        if self.minimumLength != nil || self.maximumLength != nil {
            switch kind {
                case .string, .bytes, .array, .map: break
                default:
                    return "a length applies to string, bytes, an array or a map, not \(kind.kindName)"
            }
        }
        if let minimumLength, minimumLength < 0 {
            return "a minimum length is not negative"
        }
        if let maximumLength, maximumLength < 0 {
            return "a maximum length is not negative"
        }
        if let minimumLength, let maximumLength, maximumLength < minimumLength {
            return
                "a length's minimum \(minimumLength) is more than its maximum \(maximumLength)"
        }
        if let pattern {
            guard case .string = kind else {
                return "a pattern applies to string, not \(kind.kindName)"
            }
            if (try? Regex(pattern)) == nil {
                return "the pattern \(pattern) does not compile"
            }
        }
        return nil
    }
}

extension TypeSchema {
    /// The kinds a named scalar (`Alias`) may stand for.
    public var isScalarKind: Bool {
        switch self {
            case .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime,
                .timestamp, .duration, .uuid:
                true
            default:
                false
        }
    }

    /// The kind's name in constraint diagnostics.
    var kindName: String {
        switch self {
            case .bool: "bool"
            case .int: "int"
            case .uint: "uint"
            case .float: "float"
            case .double: "double"
            case .string: "string"
            case .bytes: "bytes"
            case .date: "date"
            case .datetime: "datetime"
            case .timestamp: "timestamp"
            case .duration: "duration"
            case .uuid: "uuid"
            case .optional: "an optional"
            case .array: "an array"
            case .map: "a map"
            case .structure: "a structure"
            case .enumeration: "an enumeration"
            case .union: "a union"
            case .reference(let name): name
            case .unknown: "unknown"
        }
    }
}

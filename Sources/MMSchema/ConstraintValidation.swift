/// A value that checks the constraints its contract declares, on itself and
/// on every value it holds. Every type `#schema` generates conforms; a type
/// with nothing constrained anywhere inside it answers nil at once.
public protocol MMConstraintValidating {
    /// The first value under this one, in field order, that breaks a declared
    /// constraint: its dotted path under `path` (`"line.tags[2]"`) and the
    /// rule it broke. Nil when every constraint holds.
    func constraintViolation(at path: String) -> SchemaValueError?
}

/// The constraint check a descriptor runs on the values its client sends:
/// the request, or each element of a request stream. `#schema` generates one
/// for a call whose request or request-stream element holds a constrained
/// value.
///
/// The server runs the check at ingress in every build, after decoding and
/// before the handler. A client runs it before encoding only when
/// ``beforeSending`` is true, which the generated code sets in debug builds
/// of the module that declares the call: a release client sends what it is
/// given, and the server's answer names the failing field.
public struct MMConstraintCheck<Value>: Sendable {
    /// Whether a client checks before sending.
    public let beforeSending: Bool
    private let check: @Sendable (Value) -> SchemaValueError?

    public init(
        beforeSending: Bool,
        _ check: @escaping @Sendable (Value) -> SchemaValueError?
    ) {
        self.beforeSending = beforeSending
        self.check = check
    }

    /// The first constraint `value` breaks, with its path, or nil.
    public func violation(of value: Value) -> SchemaValueError? {
        self.check(value)
    }
}

extension MMConstraintCheck where Value: MMConstraintValidating & Sendable {
    /// The check of a generated type: its own
    /// ``MMConstraintValidating/constraintViolation(at:)`` from the root.
    public init(beforeSending: Bool) {
        self.init(beforeSending: beforeSending) { $0.constraintViolation(at: "") }
    }
}

/// The paths generated constraint checks name, built the way
/// ``SchemaValue/validated(against:resolver:path:checkingConstraints:)``
/// builds them.
public enum MMConstraintPath {
    /// A field or map entry under `path`: `"line"`, `"line.text"`.
    public static func member(_ name: String, under path: String) -> String {
        SchemaValue.appending(name, to: path)
    }

    /// An array element under `path`: `"tags[2]"`.
    public static func element(_ index: Int, under path: String) -> String {
        "\(path)[\(index)]"
    }

    /// `path` inside request-stream item `seq`, as an ingress error names
    /// it: `"[3].text"`, `"[3]"` for the item itself, `"[3][0]"` inside an
    /// array item.
    public static func item(_ seq: UInt32, path: String) -> String {
        let item = Self.element(Int(seq), under: "")
        return path.isEmpty || path.hasPrefix("[") ? item + path : "\(item).\(path)"
    }
}

extension MMConstraintPath {
    /// The first constraint `value` breaks, with its path under `path`: its
    /// own ``MMConstraintValidating/constraintViolation(at:)``. Generated
    /// checks call it on a value of a type declared elsewhere, which may
    /// check constraints or not.
    public static func violation<Value: MMConstraintValidating>(
        in value: Value,
        at path: String
    ) -> SchemaValueError? {
        value.constraintViolation(at: path)
    }

    /// No violation: `Value` checks no constraints of its own.
    public static func violation<Value>(in value: Value, at path: String) -> SchemaValueError? {
        nil
    }
}

extension MMConstraintCheck {
    /// No check: `Value` checks no constraints of its own.
    public static func ifConstrained(beforeSending: Bool) -> Self? {
        nil
    }
}

extension MMConstraintCheck where Value: MMConstraintValidating & Sendable {
    /// The check of a type that checks its own constraints, as for
    /// ``init(beforeSending:)``. Generated descriptors call it on a request
    /// of a type declared elsewhere, which may check constraints or not.
    public static func ifConstrained(beforeSending: Bool) -> Self? {
        Self(beforeSending: beforeSending)
    }
}

extension Optional: MMConstraintValidating where Wrapped: MMConstraintValidating {
    /// The wrapped value's violation; nil for nil.
    public func constraintViolation(at path: String) -> SchemaValueError? {
        self?.constraintViolation(at: path) ?? nil
    }
}

extension Array: MMConstraintValidating where Element: MMConstraintValidating {
    /// The first element's violation, in index order, under `path[index]`.
    public func constraintViolation(at path: String) -> SchemaValueError? {
        for (index, element) in self.enumerated() {
            if let violation = element.constraintViolation(
                at: MMConstraintPath.element(index, under: path))
            {
                return violation
            }
        }
        return nil
    }
}

extension Dictionary: MMConstraintValidating where Value: MMConstraintValidating {
    /// A violating entry's violation, under `path.key`: of the entries that
    /// break a constraint, the one whose key's text sorts first, so the
    /// answer does not hang on the dictionary's order.
    public func constraintViolation(at path: String) -> SchemaValueError? {
        var first: (key: String, violation: SchemaValueError)?
        for (key, value) in self {
            let name = "\(key)"
            if let first, first.key <= name { continue }
            if let violation = value.constraintViolation(
                at: MMConstraintPath.member(name, under: path))
            {
                first = (name, violation)
            }
        }
        return first?.violation
    }
}

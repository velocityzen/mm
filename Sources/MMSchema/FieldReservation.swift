/// Keys and names a fields block has retired, declared among its fields as
/// ``Reserved(_:)``. A removed field's key and name stay reserved so a later
/// field cannot take them and a peer built from an older contract never
/// reads a new value under an old meaning.
///
/// A reservation is a declaration rule only: it is never served, hashed or
/// compared, and removing one is not a wire change.
public struct FieldReservation: Sendable, Hashable {
    /// One reserved key (an integer literal) or name (a string literal).
    public struct Entry: Sendable, Hashable, ExpressibleByIntegerLiteral,
        ExpressibleByStringLiteral
    {
        enum Kind: Sendable, Hashable {
            case key(Int)
            case name(String)
        }

        let kind: Kind

        public init(integerLiteral value: Int) { self.kind = .key(value) }
        public init(stringLiteral value: String) { self.kind = .name(value) }
    }

    let keys: [Int]
    let names: [String]
}

/// Retires keys and names in a fields block:
///
/// ```swift
/// Type("Line") {
///     Field("text", .string)
///     Reserved(1, "author")
///     Field("at", .timestamp)
/// }
/// ```
///
/// A field may not pin a reserved key or take a reserved name, and an
/// unpinned field skips reserved keys like pinned ones, so reserving a
/// removed field's key keeps the auto keys after it where they were.
public func Reserved(_ entries: FieldReservation.Entry...) -> FieldReservation {
    precondition(!entries.isEmpty, "Reserved() lists no keys or names")
    var keys: [Int] = []
    var names: [String] = []
    for entry in entries {
        switch entry.kind {
            case .key(let key):
                precondition(key >= 0, "Reserved(\(key)): field keys are non-negative integers")
                keys.append(key)
            case .name(let name):
                precondition(!name.isEmpty, "Reserved(\"\"): a field name is not empty")
                names.append(name)
        }
    }
    return FieldReservation(keys: keys, names: names)
}

/// Why a fields block's keys and names cannot stand.
package enum FieldKeyConflict: Error, Hashable, CustomStringConvertible {
    /// Two fields pin one key.
    case duplicateKey(Int, field: String)
    /// A field pins a reserved key.
    case reservedKey(Int, field: String)
    /// A field takes a reserved name.
    case reservedName(String)

    package var description: String {
        switch self {
            case .duplicateKey(let key, let field):
                "duplicate field key \(key) (\(field))"
            case .reservedKey(let key, let field):
                "field key \(key) is reserved (\(field))"
            case .reservedName(let name):
                "field name \"\(name)\" is reserved"
        }
    }
}

/// The keys a fields block's fields take, in declaration order, or the
/// first field that breaks a rule. A pinned field keeps its pin; an unpinned
/// one takes the lowest key from 0 that no field pins, no reservation holds,
/// and no earlier unpinned field took. A key pinned twice, a pinned key that
/// is reserved, and a reserved name are refused, checked field by field in
/// declaration order.
package func fieldKeys(
    for fields: [(pinnedKey: Int?, name: String)],
    reservedKeys: Set<Int>,
    reservedNames: Set<String>
) -> Result<[Int], FieldKeyConflict> {
    var used: Set<Int> = []
    for field in fields {
        if reservedNames.contains(field.name) {
            return .failure(.reservedName(field.name))
        }
        guard let pin = field.pinnedKey else { continue }
        if reservedKeys.contains(pin) {
            return .failure(.reservedKey(pin, field: field.name))
        }
        if !used.insert(pin).inserted {
            return .failure(.duplicateKey(pin, field: field.name))
        }
    }
    used.formUnion(reservedKeys)
    var next = 0
    return .success(
        fields.map { field in
            if let pin = field.pinnedKey { return pin }
            while used.contains(next) { next += 1 }
            used.insert(next)
            return next
        }
    )
}

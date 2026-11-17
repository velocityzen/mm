/// Marks where the generated Swift types break their cycles: the fields and
/// union cases through which declared types hold each other by value.
///
/// The wire allows a named type to hold itself (see `TypeResolver`): a value
/// nests only as deep as it does. Swift lays out a struct's stored
/// properties and an enum's associated values inline, so a generated struct
/// can't hold itself, `Node` holding a `Node?`, and an enum case can't hold
/// its own enum. A type holds another by value through an optional or a
/// nested `Field("x") { ... }` structure; an array or a map keeps its
/// elements out of line, and a type from another container can't hold one
/// of this block's.
///
/// A field of a declared `Type` that holds, by value, a type on a cycle
/// through that `Type` keeps its value in an `MMIndirect` box, and a union
/// case with such a field is `indirect`. Each cycle then passes through a box
/// or an indirect case at every step, so every type has a finite size. The
/// property types, the initializers and the wire bytes stay as declared.
///
/// Throws for a type with no finite value: one whose every value holds
/// another value of a type on its cycle, through fields that are not
/// optional, without end.
func breakingValueCycles(_ types: [ParsedTypeDecl]) throws -> [ParsedTypeDecl] {
    let holds = Dictionary(
        types.map { ($0.name, typesHeldByValue(in: $0)) },
        uniquingKeysWith: { first, _ in first }
    )
    // The declared types each type reaches by value, itself included only
    // through a cycle.
    var reaches: [String: Set<String>] = [:]
    for type in types {
        var reached: Set<String> = []
        var pending = Array(holds[type.name] ?? [])
        while let name = pending.popLast() {
            guard reached.insert(name).inserted else { continue }
            pending.append(contentsOf: holds[name] ?? [])
        }
        reaches[type.name] = reached
    }
    try requireFiniteValues(types)
    /// Whether a value of `type`, held by the declared type `owner`, can
    /// lead back to `owner` by value.
    func closesCycle(_ type: ParsedType, owner: String) -> Bool {
        typesHeldByValue(in: type).contains { held in
            held == owner || reaches[held]?.contains(owner) == true
        }
    }
    return types.map { type in
        var type = type
        switch type.payload {
            case .structure(var fields):
                for index in fields.indices {
                    fields[index].isIndirect = closesCycle(fields[index].type, owner: type.name)
                }
                type.payload = .structure(fields)
            case .union(var cases):
                for index in cases.indices {
                    cases[index].isIndirect = cases[index].fields.contains { field in
                        closesCycle(field.type, owner: type.name)
                    }
                }
                type.payload = .union(cases)
            case .enumeration, .alias:
                break
        }
        return type
    }
}

/// The names of the declared types a value of `declaration` holds by value.
private func typesHeldByValue(in declaration: ParsedTypeDecl) -> Set<String> {
    switch declaration.payload {
        case .structure(let fields):
            return fields.reduce(into: []) { $0.formUnion(typesHeldByValue(in: $1.type)) }
        case .union(let cases):
            return cases.reduce(into: []) { held, unionCase in
                for field in unionCase.fields {
                    held.formUnion(typesHeldByValue(in: field.type))
                }
            }
        case .enumeration, .alias:
            return []
    }
}

/// The names of the declared types a value of `type` holds by value: through
/// optionals and nested structures, not arrays, maps or other containers'
/// types.
private func typesHeldByValue(in type: ParsedType) -> Set<String> {
    switch type {
        case .bool, .int, .uint, .float, .double, .string, .bytes,
            .date, .datetime, .timestamp, .array, .map, .external:
            return []
        case .optional(let wrapped):
            return typesHeldByValue(in: wrapped)
        case .structure(_, let fields):
            return fields.reduce(into: []) { $0.formUnion(typesHeldByValue(in: $1.type)) }
        case .reference(let name):
            return [name]
    }
}

/// Throws for the first declared type that has no finite value. A type has
/// one when it is an enum or an alias, a structure whose every field has
/// one, or a union with a case whose every field has one; a field has one
/// when it is optional, an array, a map, a scalar, another container's type,
/// or a structure or declared type that has one.
private func requireFiniteValues(_ types: [ParsedTypeDecl]) throws {
    var finite: Set<String> = []
    func hasFiniteValue(_ type: ParsedType) -> Bool {
        switch type {
            case .bool, .int, .uint, .float, .double, .string, .bytes,
                .date, .datetime, .timestamp, .optional, .array, .map, .external:
                return true
            case .structure(_, let fields):
                return fields.allSatisfy { hasFiniteValue($0.type) }
            case .reference(let name):
                return finite.contains(name)
        }
    }
    var changed = true
    while changed {
        changed = false
        for type in types where !finite.contains(type.name) {
            let hasOne =
                switch type.payload {
                    case .enumeration, .alias:
                        true
                    case .structure(let fields):
                        fields.allSatisfy { hasFiniteValue($0.type) }
                    case .union(let cases):
                        cases.contains { $0.fields.allSatisfy { hasFiniteValue($0.type) } }
                }
            if hasOne {
                finite.insert(type.name)
                changed = true
            }
        }
    }
    guard let endless = types.first(where: { !finite.contains($0.name) }) else { return }
    let declaration =
        if case .union = endless.payload { "Union(\"\(endless.name)\")" } else {
            "Type(\"\(endless.name)\")"
        }
    throw SchemaMacroError(
        description:
            "\(declaration) has no finite value: every value of it holds another value of a type on its cycle, without end — make a field on the way optional, or an array"
    )
}

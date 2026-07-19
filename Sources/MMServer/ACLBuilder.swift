import MMSchema

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The declarative form of a static ACL table — sugar over
/// ``InMemoryACLProvider``, in the same element slot as a passed instance:
///
/// ```swift
/// MMService {
///     Configuration(endpoint: .unix(path: sock))
///     ACLProvider {
///         Entity("journal", owner: uid, group: gid, mode: 0o750) {
///             Entity("notes")                            // inherits owner/group; mode 0o750
///             Entity("system", owner: 0, group: 0, mode: 0o700)
///         }
///     }
///     ...
/// }
/// ```
///
/// The tree mirrors the filesystem model the authorization semantics come
/// from: nested entities take their path relative to the parent
/// (`"notes"` under `"journal"` is `journal.notes`), inherit the parent's
/// `owner`/`group` unless overridden, and default their `mode` to
/// `EntityACL.defaultCreationMode` (0o750) — the library's creation default.
/// Top-level entities must state `owner` and `group` explicitly; there is
/// nothing to inherit from and authorization is never defaulted.
///
/// ## Static tables only — the protocol remains the real authority
///
/// A declarative block is a snapshot assembled at startup. Hosts whose ACLs
/// live in storage and change at runtime (the SQLite-backed provider of the
/// integration guide) implement ``EntityACLProvider`` and pass the instance:
/// `ACLProvider(provider)`. The two forms share the element slot; the builder
/// yields an ``InMemoryACLProvider``, which stays mutable afterwards via its
/// `set`/`remove` if you keep a reference.
public struct ACLEntry {
    let path: String
    let owner: uid_t?
    let group: gid_t?
    let mode: UInt16?
    let children: [ACLEntry]
}

/// Declares one entity's ACL, with optional children declared relative to it.
/// See ``ACLEntry`` for inheritance and defaulting rules.
public func Entity(
    _ path: String,
    owner: uid_t? = nil,
    group: gid_t? = nil,
    mode: UInt16? = nil,
    @ACLBuilder _ children: () -> [ACLEntry] = { [] }
) -> ACLEntry {
    ACLEntry(
        path: path,
        owner: owner,
        group: group,
        mode: mode,
        children: children()
    )
}

@resultBuilder
public enum ACLBuilder: MMListBuilding {
    public typealias Element = ACLEntry

    public static func buildExpression(_ entry: ACLEntry) -> [ACLEntry] { [entry] }
    public static func buildExpression(_ entries: [ACLEntry]) -> [ACLEntry] { entries }
}

/// Assembles a declared entity tree into the flat table an
/// ``InMemoryACLProvider`` holds. Violations (invalid paths, duplicates, a
/// top-level entity without owner/group) are programmer error and fail at
/// startup, per the builder discipline.
func assembleACLTable(_ entries: [ACLEntry]) -> [EntityName: EntityACL] {
    var table: [EntityName: EntityACL] = [:]
    func walk(_ entry: ACLEntry, parentPath: String?, inherited: (owner: uid_t, group: gid_t)?) {
        let fullPath = parentPath.map { "\($0).\(entry.path)" } ?? entry.path
        guard case .success(let name) = EntityName.parse(fullPath), !name.isRoot else {
            preconditionFailure(
                "ACLProvider declares \"\(fullPath)\", which is not a valid non-root entity path"
            )
        }
        let owner = entry.owner ?? inherited?.owner
        let group = entry.group ?? inherited?.group
        guard let owner, let group else {
            preconditionFailure(
                "ACLProvider: \"\(fullPath)\" has no owner/group and no enclosing Entity to inherit from — authorization is never defaulted"
            )
        }
        let acl = EntityACL(
            owner: owner,
            group: group,
            mode: entry.mode ?? EntityACL.defaultCreationMode
        )
        precondition(
            table.updateValue(acl, forKey: name) == nil,
            "ACLProvider declares \"\(fullPath)\" twice"
        )
        for child in entry.children {
            walk(child, parentPath: fullPath, inherited: (owner, group))
        }
    }
    for entry in entries {
        walk(entry, parentPath: nil, inherited: nil)
    }
    return table
}

extension InMemoryACLProvider {
    /// Builds the provider from a declared entity tree. See ``ACLEntry``.
    public init(@ACLBuilder _ entities: () -> [ACLEntry]) {
        self.init(assembleACLTable(entities()))
    }
}

/// Builder-element form: declares the static ACL table inline. Equivalent to
/// `ACLProvider(InMemoryACLProvider { ... })`.
public func ACLProvider(@ACLBuilder _ entities: () -> [ACLEntry]) -> ServerPart {
    ServerPart(kind: .aclProvider(InMemoryACLProvider(assembleACLTable(entities()))))
}

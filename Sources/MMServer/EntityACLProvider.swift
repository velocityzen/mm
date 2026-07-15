import MMSchema

/// The host application's source of entity ACLs. Real providers typically sit
/// on SQLite (hence `async`); the library ships ``InMemoryACLProvider`` for
/// tests and small daemons.
///
/// ## Contract
///
/// - `.success(nil)` means "no ACL record exists for this entity". The router
///   translates that to `permissionDenied` — never to "not found" — so a peer
///   cannot probe for entity existence.
/// - `.failure` means the provider itself broke (storage error). The router
///   logs it and answers the peer with `internalError`; provider detail never
///   reaches the wire.
public protocol EntityACLProvider: Sendable {
    /// Resolves the ACL for one entity. `EntityName.root` is never a concrete
    /// entity and providers are not required to have a record for it.
    func acl(for entity: EntityName) async -> Result<EntityACL?, ACLProviderError>

    /// Cache-invalidation hook for chmod-equivalent mutations.
    ///
    /// Semantics: implementations that **cache** ACL lookups must drop any
    /// cached entry for `entity` before returning, so the next `acl(for:)`
    /// observes the mutation. The router itself does not cache in v1, so
    /// dispatch correctness never depends on this hook — it exists so hosts
    /// can layer caching providers without changing the router.
    func invalidate(_ entity: EntityName) async
}

/// A dictionary-backed ``EntityACLProvider`` for tests and small daemons.
///
/// An actor so `set`/`remove` may race with in-flight dispatches safely; each
/// lookup reads the live dictionary.
public actor InMemoryACLProvider: EntityACLProvider {
    private var acls: [EntityName: EntityACL]

    public init(_ acls: [EntityName: EntityACL] = [:]) {
        self.acls = acls
    }

    /// Sets (or replaces) the ACL for `entity`.
    public func set(_ acl: EntityACL, for entity: EntityName) {
        self.acls[entity] = acl
    }

    /// Removes the ACL record for `entity`, if any.
    public func remove(_ entity: EntityName) {
        self.acls[entity] = nil
    }

    public func acl(for entity: EntityName) async -> Result<EntityACL?, ACLProviderError> {
        .success(self.acls[entity])
    }

    /// A no-op, documented as such: this provider never caches — every lookup
    /// reads the live dictionary, so there is nothing to drop.
    public func invalidate(_ entity: EntityName) async {}
}

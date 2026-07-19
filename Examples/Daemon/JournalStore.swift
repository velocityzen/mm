import MMExampleAPI
import MMSchema

/// The in-memory journal the handlers mutate — one actor, one serialization
/// point. A real daemon would put a database here (see the integration guide,
/// MMServer.docc/IntegrationGuide.md, for the SQLite-on-NIOThreadPool pattern).
///
/// ## Cross-connection change fan-out
///
/// The store also brokers `journal.follow`: every append (whether from a unary
/// `journal.append` or a streamed `journal.import`, on *any* connection)
/// broadcasts a `ChangeEvent` to every follower registered for that journal.
/// Cross-connection fan-out is application infrastructure, not library policy —
/// the library gives each `follow` call a correlated, flow-controlled response
/// stream; wiring one journal's appends to its followers is the example
/// demonstrating what to build on top.
///
/// The follower registry itself lives in ``FollowerHub``, outside the actor:
/// stream termination handlers are synchronous, so registering their cleanup
/// needs a lock-guarded hub, not actor isolation. The hub is independently
/// thread-safe, which is why ``follow(_:)`` and ``unfollow(_:from:)`` are
/// `nonisolated` — only the journal data itself needs the actor.
actor JournalStore {
    private var journals: [EntityName: [String]] = [:]

    /// The `journal.follow` fan-out registry; see ``FollowerHub`` for the
    /// lifecycle and locking story.
    private nonisolated let followers = FollowerHub()

    func append(_ line: String, to entity: EntityName) -> Int {
        journals[entity, default: []].append(line)
        let count = journals[entity, default: []].count
        followers.broadcast(
            ChangeEvent(entity: entity.rawValue, line: line, count: count),
            to: entity
        )
        return count
    }

    func read(_ entity: EntityName) -> [String] {
        journals[entity] ?? []
    }

    /// Total lines currently held for `entity` — used by the import terminal.
    func count(of entity: EntityName) -> Int {
        journals[entity]?.count ?? 0
    }

    /// Registers a follower for `entity` and returns its token and the element
    /// stream the follow handler drains. The handler passes the token back to
    /// ``unfollow(_:from:)`` on exit; if its task dies before reaching that,
    /// the stream's termination unregisters the follower instead.
    nonisolated func follow(_ entity: EntityName) -> (
        token: UInt64, stream: AsyncStream<ChangeEvent>
    ) {
        self.followers.follow(entity)
    }

    /// Unregisters a follower and finishes its stream. Idempotent.
    nonisolated func unfollow(_ token: UInt64, from entity: EntityName) {
        self.followers.unfollow(token, from: entity)
    }
}

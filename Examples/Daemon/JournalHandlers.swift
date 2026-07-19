import MMExampleAPI
import MMServer

/// The `journal.*` handlers as a reusable, separately-declared group — the
/// handler analogue of a custom SwiftUI view. It carries its own dependency
/// (the store) and drops into the daemon's `For(Journal.self)` block; the
/// daemon file stays pure wiring.
struct JournalHandlers: RouteGroup {
    let store: JournalStore

    @RouterBuilder var routes: [Route] {
        On(Journal.append) { auth, request in
            // The store broadcasts the change to every follower of this
            // journal (any connection) as part of the append. Cross-connection
            // fan-out is application infrastructure — the library gives each
            // follow call a correlated stream; the store wires appends to it.
            let count = await store.append(request.line, to: auth.entity)
            return .success(AppendResponse(count: count))
        }
        On(Journal.read) { auth, request in
            .success(ReadResponse(lines: await store.read(auth.entity)))
        }
        // Server → client stream: register a follower, relay its change
        // events through the credit-gated response sink, return the count as
        // the terminal. A journal can be quiet for arbitrarily long, so the
        // client's STOP is observed on BOTH edges: `send` reports it as
        // `.peerStopped` mid-relay, and a `stopRequested()` watcher catches it
        // while the relay is parked on a quiet source — it unfollows, which
        // finishes `changes` and ends the relay promptly. Unregister is
        // idempotent (both edges may fire); if this task dies before either,
        // the stream's termination handler unregisters instead (see
        // FollowerHub).
        On(Journal.follow) { auth, request, sink in
            let (token, changes) = store.follow(auth.entity)
            var delivered = 0
            await withTaskGroup(of: Void.self) { watcher in
                watcher.addTask {
                    await sink.stopRequested()
                    store.unfollow(token, from: auth.entity)
                }
                loop: for await event in changes {
                    switch await sink.send(event) {
                        case .sent:
                            delivered += 1
                        case .peerStopped, .callEnded:
                            break loop
                    }
                }
                // Relay ended first (source finished or send reported the
                // stop): release a still-parked watcher.
                watcher.cancelAll()
            }
            store.unfollow(token, from: auth.entity)
            return .success(FollowSummary(delivered: delivered))
        }
        // Client → server stream: append every streamed line (which itself
        // broadcasts to followers), and answer with how many this call
        // imported plus the journal's total. The `elements` sequence ending
        // is the client's graceful END.
        On(Journal.import) { auth, request, elements in
            var imported = 0
            for await element in elements {
                _ = await store.append(element.line, to: auth.entity)
                imported += 1
            }
            let total = await store.count(of: auth.entity)
            return .success(ImportSummary(imported: imported, total: total))
        }
        // Duplex: append each inbound line (which also broadcasts to any
        // followers) and echo the resulting ChangeEvent straight back through
        // this call's own credit-gated response sink. The request stream
        // ending is the client's END; the shared terminal totals what landed.
        On(Journal.sync) { auth, request, elements, sink in
            var synced = 0
            loop: for await element in elements {
                let count = await store.append(element.line, to: auth.entity)
                let event = ChangeEvent(
                    entity: auth.entity.rawValue, line: element.line, count: count)
                switch await sink.send(event) {
                    case .sent:
                        synced += 1
                    case .peerStopped, .callEnded:
                        break loop
                }
            }
            return .success(
                SyncSummary(synced: synced, total: await store.count(of: auth.entity)))
        }
    }
}

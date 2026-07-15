import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMClient

/// A no-op ``ClientStreamControl`` for CallTable-level unit tests: it lets a
/// `.stream` entry exist in the table without a live connection behind it. No
/// method is exercised by the wrap tests — they only need a value in the slot.
final class StubStreamControl: ClientStreamControl {
    let hasResponseStream = true
    let hasRequestStream = false
    func validateInboundItem(seq: UInt32) -> InboundItemValidation { .drop }
    func deliverInboundItem(_ item: ByteBuffer) -> InboundDeliveryOutcome { .dropped }
    func awaitInboundDemand() async {}
    func serverEndInbound() {}
    func grantOutbound(_ credits: UInt32) {}
    func serverStopOutbound() {}
    func resolveTerminal(_ slots: ResponseSlots) {}
    func failTerminal(_ reason: MMCallError) {}
    func cancelLocally() {}
}

@Suite("msgid allocation")
struct MsgidTests {
    @Test("allocation wraps through UInt32.max to 0")
    func wrapAtMax() {
        var table = CallTable()
        table.nextMsgid = UInt32.max
        #expect(table.reserve(cap: 8) == .success(UInt32.max))
        #expect(table.reserve(cap: 8) == .success(0))
        #expect(table.reserve(cap: 8) == .success(1))
    }

    @Test("wrap-around is visible on the wire")
    func wrapOnTheWire() async throws {
        let (msgids, _) = try await withRunningConnection { client in
            client.connection._seedNextMsgid(UInt32.max)
            var seen: [UInt32] = []
            for value: UInt8 in [1, 2] {
                async let reply = client.connection.call(
                    ClientTestMethods.boxGet, on: entity("box"), boxRequest(value))
                let (msgid, _, _) = try await client.readRequestFrame()
                seen.append(msgid)
                try await client.channel.writeInbound(
                    responseFrame(msgid: msgid, result: BoxResponse(value: value + 100))
                )
                let outcome = await reply
                #expect(outcome == .success(BoxResponse(value: value + 100)))
            }
            return seen
        }
        #expect(msgids == [UInt32.max, 0])
    }

    @Test("allocation skips a live msgid instead of colliding (long-lived streams)")
    func allocationSkipsLiveMsgid() {
        var table = CallTable()
        // Seed a live entry exactly where the allocator would land, plus the
        // next one, so allocation must skip both.
        table.nextMsgid = 5
        table.entries[5] = .reserved
        table.entries[6] = .reserved
        // 5 and 6 are live: allocation skips to 7.
        #expect(table.reserve(cap: 8) == .success(7))
        // 7 is now taken; 8 is free.
        #expect(table.reserve(cap: 8) == .success(8))
    }

    @Test("allocation skips a live msgid across the wrap boundary")
    func allocationSkipsAcrossWrap() {
        var table = CallTable()
        table.nextMsgid = UInt32.max
        table.entries[UInt32.max] = .reserved  // a long-lived id
        table.entries[0] = .reserved  // and the wrapped landing spot
        // max and 0 are live: allocation skips to 1.
        #expect(table.reserve(cap: 8) == .success(1))
    }

    @Test("allocation skips a live STREAM id at wrap (long-lived streams stay live)")
    func allocationSkipsLiveStreamAtWrap() {
        var table = CallTable()
        // A long-lived stream holds UInt32.max indefinitely. The allocator lands
        // there on wrap and must skip it (not collide), then hand out 0.
        table.nextMsgid = UInt32.max
        table.entries[UInt32.max] = .stream(StubStreamControl())
        #expect(table.reserve(cap: 8) == .success(0))
        // The stream id is still live and untouched.
        guard case .stream = table.entries[UInt32.max] else {
            Issue.record("the live stream id was overwritten")
            return
        }
    }

    @Test("reserve enforces the cap before allocating")
    func reserveEnforcesCap() {
        var table = CallTable()
        #expect(table.reserve(cap: 1) == .success(1))
        #expect(table.reserve(cap: 1) == .failure(.tooManyInFlight))
    }

    @Test("reserve on a closed table fails with the close reason")
    func reserveAfterClose() {
        var table = CallTable()
        _ = table.close(reason: .connectionClosed)
        #expect(table.reserve(cap: 8) == .failure(.connectionClosed))
    }

    @Test("a response parked before the caller suspends is claimed by register")
    func parkedOutcomeClaimedOnRegister() async {
        var table = CallTable()
        let msgid = try! table.reserve(cap: 8).get()
        let slots = ResponseSlots(error: nil, result: nil)
        guard case .parked = table.complete(msgid: msgid, outcome: .success(slots)) else {
            Issue.record("expected the outcome to park on the reserved entry")
            return
        }
        // A duplicate response for the same msgid drops.
        guard case .dropped = table.complete(msgid: msgid, outcome: .success(slots)) else {
            Issue.record("expected the duplicate response to drop")
            return
        }
        // Claim it through the real continuation machinery.
        let finalTable = NIOLockedValueBox(table)
        let outcome: CallTable.Outcome = await withCheckedContinuation { continuation in
            let immediate = finalTable.withLockedValue {
                $0.register(msgid: msgid, continuation: continuation)
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
        guard case .success = outcome else {
            Issue.record("expected the parked outcome, got \(outcome)")
            return
        }
        #expect(finalTable.withLockedValue { $0.entries[msgid] } == nil)
    }

    @Test("cancel before register makes register resume cancelled; the response then drops")
    func cancelBeforeRegister() async {
        var table = CallTable()
        let msgid = try! table.reserve(cap: 8).get()
        #expect(table.cancel(msgid: msgid) == nil)  // reservation removed, nothing suspended
        let box = NIOLockedValueBox(table)
        let outcome: CallTable.Outcome = await withCheckedContinuation { continuation in
            let immediate = box.withLockedValue {
                $0.register(msgid: msgid, continuation: continuation)
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
        #expect(outcome == .failure(.cancelled))
        // The late response finds no entry: dropped.
        guard
            case .dropped = box.withLockedValue({
                $0.complete(msgid: msgid, outcome: .success(ResponseSlots(error: nil, result: nil)))
            })
        else {
            Issue.record("expected the late response to drop")
            return
        }
    }

    @Test("writer waiter cancellation racing registration resolves cancelled, never parks")
    func writerWaiterCancellationRace() async {
        var table = CallTable()
        let id = table.allocateWriterWaiterID()
        // Cancellation handler runs before the waiter registered (the
        // withTaskCancellationHandler already-cancelled path): nothing to
        // resume yet, so a tombstone is left for registration to observe.
        #expect(table.cancelWriterWaiter(id: id) == nil)
        #expect(table.cancelledWriterWaiters.contains(id))
        let box = NIOLockedValueBox(table)
        // Registration must observe the tombstone and resolve immediately
        // with .cancelled — parking here would suspend the (already
        // cancelled) caller forever, since its cancellation handler has
        // already run. Driven through the real continuation machinery: if
        // registration parks despite the tombstone, nothing resumes this
        // continuation and the test hangs (caught by the harness deadline).
        let outcome: Result<CallTable.Writer, MMCallError> = await withCheckedContinuation {
            continuation in
            let immediate = box.withLockedValue {
                $0.registerWriterWaiter(id: id, continuation: continuation)
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
        #expect(failure(outcome) == .cancelled)
        box.withLockedValue { table in
            // Nothing parked, and the tombstone was consumed, not leaked.
            #expect(table.writerWaiters.isEmpty)
            #expect(!table.cancelledWriterWaiters.contains(id))
        }
    }

    @Test("close drains parked writer waiters and parks reserved msgids for their callers")
    func closeDrainsWriterWaitersAndReservations() async {
        let box = NIOLockedValueBox(CallTable())
        // A call that reserved its msgid but has not suspended yet (its
        // caller is still parked on the writer slot).
        let msgid = box.withLockedValue { try! $0.reserve(cap: 8).get() }
        let id = box.withLockedValue { $0.allocateWriterWaiterID() }
        let outcome: Result<CallTable.Writer, MMCallError> = await withCheckedContinuation {
            continuation in
            let immediate = box.withLockedValue {
                $0.registerWriterWaiter(id: id, continuation: continuation)
            }
            if let immediate {
                continuation.resume(returning: immediate)
                return
            }
            // Parked (run() never produced a writer). close() must drain the
            // waiter — otherwise the caller suspends forever — and park the
            // reservation as a failure for its caller to claim.
            let (calls, waiters, streams) = box.withLockedValue {
                $0.close(reason: .connectionClosed)
            }
            #expect(calls.isEmpty)  // the reserved caller has not suspended
            #expect(waiters.count == 1)
            #expect(streams.isEmpty)
            for waiter in waiters {
                waiter.resume(returning: .failure(.connectionClosed))
            }
        }
        #expect(failure(outcome) == .connectionClosed)
        // The caller's abandon (its write never happened) claims the parked
        // failure instead of leaving a stale entry behind.
        let parked = box.withLockedValue { $0.abandon(msgid: msgid) }
        #expect(parked == .failure(.connectionClosed))
        #expect(box.withLockedValue { $0.entries.isEmpty })
    }
}

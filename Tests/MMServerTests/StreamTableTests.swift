import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMServer

/// Hand-rolled seeded PRNG (SplitMix64) for the state-machine property test.
/// Never an unseeded RNG in tests — a fixed seed set reproduces every failure.
/// (A copy of the MMWireTests helper; test modules do not share sources.)
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A recording ``StreamControl`` fake: it records every effect the table drives
/// so the state-machine tests assert on *what the table decided*, independent of
/// the real source/sink machinery.
final class RecordingStreamControl: StreamControl {
    struct Log: Sendable, Equatable {
        var delivered = 0
        var endedRequest = false
        var grants: [UInt32] = []
        var stopped = false
        var streamsEnded = false
        var cancelled = false
    }

    let hasRequestStream: Bool
    let hasResponseStream: Bool
    /// When true, `deliver` reports a decode-style violation.
    private let failDeliver: Bool
    /// Credits the request source still holds (models the overrun check). When
    /// zero, `requestHasCredit()` is false.
    private let credit: NIOLockedValueBox<Int>
    /// Whether the request source has terminated (handler returned / stopped).
    private let terminated = NIOLockedValueBox(false)
    private let log = NIOLockedValueBox(Log())

    init(request: Bool, response: Bool, failDeliver: Bool = false, credit: Int = .max) {
        self.hasRequestStream = request
        self.hasResponseStream = response
        self.failDeliver = failDeliver
        self.credit = NIOLockedValueBox(credit)
    }

    var snapshot: Log { self.log.withLockedValue { $0 } }

    /// Test hook: mark the request source terminated (server-side end race).
    func markTerminated() { self.terminated.withLockedValue { $0 = true } }
    /// Test hook: set the remaining request credit.
    func setCredit(_ value: Int) { self.credit.withLockedValue { $0 = value } }

    func requestHasCredit() -> Bool {
        self.hasRequestStream && self.credit.withLockedValue { $0 } > 0
    }

    func requestSourceTerminated() -> Bool {
        guard self.hasRequestStream else { return true }
        return self.terminated.withLockedValue { $0 }
    }

    func deliver(_ item: ByteBuffer) -> Result<Void, MMWireError> {
        if self.failDeliver {
            return .failure(.unknownEnvelope)
        }
        self.log.withLockedValue { $0.delivered += 1 }
        return .success(())
    }

    func clientEndRequest() { self.log.withLockedValue { $0.endedRequest = true } }
    func grantResponse(_ credits: UInt32) { self.log.withLockedValue { $0.grants.append(credits) } }
    func clientStopResponse() { self.log.withLockedValue { $0.stopped = true } }
    func endStreams() { self.log.withLockedValue { $0.streamsEnded = true } }
    func cancelHandler() { self.log.withLockedValue { $0.cancelled = true } }
    func attachCancel(_ cancel: @escaping @Sendable () -> Void) {}
}

private func entry(_ control: RecordingStreamControl) -> StreamTable.Entry {
    StreamTable.Entry(
        control: control,
        hasRequestStream: control.hasRequestStream,
        hasResponseStream: control.hasResponseStream
    )
}

@Suite("Stream table state machine")
struct StreamTableTests {
    // MARK: - Registration and caps

    @Test("registerStream succeeds once; a reused live msgid is rejected")
    func registerRejectsReuse() {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: false)
        let first = table.registerStream(msgid: 5, entry: entry(control))
        #expect(first)
        #expect(table.openStreamCount == 1)
        // Same msgid still live: reuse rejected.
        let reused = table.registerStream(msgid: 5, entry: entry(control))
        #expect(!reused)
        // A msgid marked as a live unary call also blocks a stream registration.
        let unaryRegistered = table.registerUnary(msgid: 6)
        #expect(unaryRegistered)
        let unaryClash = table.registerStream(msgid: 6, entry: entry(control))
        #expect(!unaryClash)
    }

    @Test("registerUnary rejects a msgid already owned by a live stream or unary call")
    func registerUnaryRejectsReuse() {
        var table = StreamTable()
        // A live unary msgid cannot be reused for another unary call.
        let firstUnary = table.registerUnary(msgid: 3)
        #expect(firstUnary)
        let reusedUnary = table.registerUnary(msgid: 3)
        #expect(!reusedUnary)
        // A live stream msgid blocks a unary registration on the same id.
        let control = RecordingStreamControl(request: true, response: false)
        _ = table.registerStream(msgid: 4, entry: entry(control))
        let unaryOnStream = table.registerUnary(msgid: 4)
        #expect(!unaryOnStream)
        // isOwned reports both.
        #expect(table.isOwned(msgid: 3))
        #expect(table.isOwned(msgid: 4))
        #expect(!table.isOwned(msgid: 99))
    }

    // MARK: - Item routing / seq validation

    @Test("in-order items deliver and advance seq")
    func inOrderItemsDeliver() {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: false)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        for seq in UInt32(0)..<3 {
            guard case .deliver = table.routeItem(msgid: 1, seq: seq) else {
                Issue.record("seq \(seq) should deliver")
                return
            }
        }
    }

    @Test("a seq gap is a violation and retires the stream")
    func seqGapViolation() {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: false)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        guard case .deliver = table.routeItem(msgid: 1, seq: 0) else {
            Issue.record("seq 0 should deliver")
            return
        }
        // Expected 1, got 2 → gap.
        guard case .violation = table.routeItem(msgid: 1, seq: 2) else {
            Issue.record("gap should be a violation")
            return
        }
        // The stream is retired: a follow-up frame drops.
        #expect(!table.isStreamLive(msgid: 1))
        guard case .drop = table.routeItem(msgid: 1, seq: 3) else {
            Issue.record("post-violation item should drop")
            return
        }
    }

    @Test("an item on a stream with no request direction is a violation")
    func itemOnUndeclaredDirectionViolation() {
        var table = StreamTable()
        // Server-stream-only: no request direction.
        let control = RecordingStreamControl(request: false, response: true)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        guard case .violation = table.routeItem(msgid: 1, seq: 0) else {
            Issue.record("item on undeclared request direction should be a violation")
            return
        }
        #expect(!table.isStreamLive(msgid: 1))
    }

    @Test(
        "an item after the server terminated the request source is a (late) drop, not a violation")
    func itemAfterServerTerminationDrops() {
        // Regression: an in-flight request item racing the handler's graceful
        // return (source terminated, entry not yet retired) must drop-and-count,
        // exactly like a post-client-END item — never a code-6 violation. The
        // credit check alone would misclassify it as an overrun (credit 0 on a
        // terminated source), so termination is checked first.
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: false, credit: 0)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        // The handler returned: the source is terminated, but the entry is still
        // live (finishStream has not run yet).
        control.markTerminated()
        // A legitimately in-flight item at the next expected seq: a drop, not a
        // violation — even though credit is 0 (the terminated source, not an
        // overrun on a live one).
        guard case .drop = table.routeItem(msgid: 1, seq: 0) else {
            Issue.record("item racing server-side termination should drop, not violate")
            return
        }
        // The entry survives so the handler's own terminal still flushes.
        #expect(table.isStreamLive(msgid: 1))
    }

    @Test("a credit overrun on a still-live source is a violation")
    func creditOverrunOnLiveSourceViolates() {
        // The complement to the termination drop: zero credit on a NON-terminated
        // source is a genuine overrun and stays a code-6 violation.
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: false, credit: 0)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        guard case .violation = table.routeItem(msgid: 1, seq: 0) else {
            Issue.record("an overrun on a live source should be a violation")
            return
        }
        #expect(!table.isStreamLive(msgid: 1))
    }

    @Test("an item after the client END is a (late) drop, not a violation")
    func itemAfterEndDrops() {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: false)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        guard case .end = table.routeEnd(msgid: 1) else {
            Issue.record("END should route")
            return
        }
        // The stream is still live (only the request direction ended); a late
        // item is a drop, not a violation.
        #expect(table.isStreamLive(msgid: 1))
        guard case .drop = table.routeItem(msgid: 1, seq: 0) else {
            Issue.record("item after END should drop")
            return
        }
    }

    @Test("an item for an unknown/retired msgid drops")
    func itemUnknownDrops() {
        var table = StreamTable()
        guard case .drop = table.routeItem(msgid: 99, seq: 0) else {
            Issue.record("unknown msgid item should drop")
            return
        }
    }

    // MARK: - END routing

    @Test("a second END drops; END on undeclared request direction is a violation")
    func endRules() {
        var table = StreamTable()
        let client = RecordingStreamControl(request: true, response: false)
        _ = table.registerStream(msgid: 1, entry: entry(client))
        guard case .end = table.routeEnd(msgid: 1) else {
            Issue.record("first END routes")
            return
        }
        guard case .drop = table.routeEnd(msgid: 1) else {
            Issue.record("second END drops")
            return
        }
        // END on a server-stream-only method (no request direction) is a
        // violation.
        let server = RecordingStreamControl(request: false, response: true)
        _ = table.registerStream(msgid: 2, entry: entry(server))
        guard case .violation = table.routeEnd(msgid: 2) else {
            Issue.record("END on undeclared request direction is a violation")
            return
        }
    }

    // MARK: - Credit / STOP routing

    @Test("credit routes only to streams with a response direction")
    func creditRouting() {
        var table = StreamTable()
        let server = RecordingStreamControl(request: false, response: true)
        let client = RecordingStreamControl(request: true, response: false)
        _ = table.registerStream(msgid: 1, entry: entry(server))
        _ = table.registerStream(msgid: 2, entry: entry(client))
        #expect(table.routeCredit(msgid: 1) != nil)  // response direction present
        #expect(table.routeCredit(msgid: 2) == nil)  // none → drop
        #expect(table.routeCredit(msgid: 99) == nil)  // unknown → drop
    }

    @Test("STOP routes only to streams with a response direction")
    func stopRouting() {
        var table = StreamTable()
        let server = RecordingStreamControl(request: false, response: true)
        let client = RecordingStreamControl(request: true, response: false)
        _ = table.registerStream(msgid: 1, entry: entry(server))
        _ = table.registerStream(msgid: 2, entry: entry(client))
        #expect(table.routeStop(msgid: 1) != nil)
        #expect(table.routeStop(msgid: 2) == nil)  // advisory, no response stream → drop
        #expect(table.routeStop(msgid: 99) == nil)
    }

    // MARK: - CANCEL / retirement

    @Test("CANCEL removes the entry and returns its control once")
    func cancelRetires() {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: true)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        let cancelled = table.routeCancel(msgid: 1)
        #expect(cancelled != nil)
        #expect(!table.isStreamLive(msgid: 1))
        // A second CANCEL (or any frame) drops — the entry is gone.
        let again = table.routeCancel(msgid: 1)
        #expect(again == nil)
    }

    @Test("retireStream is true once then false — the single-terminal guarantee")
    func retireOnce() {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: true)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        let first = table.retireStream(msgid: 1)
        #expect(first)
        let second = table.retireStream(msgid: 1)
        #expect(!second)
    }

    @Test("a CANCEL then a handler completion never double-terminates")
    func cancelThenCompletionSingleTerminal() {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: true)
        _ = table.registerStream(msgid: 1, entry: entry(control))
        // CANCEL retires the entry (runtime sends code-7).
        let cancelled = table.routeCancel(msgid: 1)
        #expect(cancelled != nil)
        // The handler later completes and asks to retire: already gone, so its
        // terminal is suppressed.
        let retired = table.retireStream(msgid: 1)
        #expect(!retired)
    }

    // MARK: - Unary-msgid guard

    @Test("a stream item on a live unary msgid is a unary violation and suppresses its terminal")
    func unaryViolationSuppresses() {
        var table = StreamTable()
        _ = table.registerUnary(msgid: 7)
        guard case .unaryViolation = table.routeItem(msgid: 7, seq: 0) else {
            Issue.record("item on a live unary msgid is a unary violation")
            return
        }
        // The unary handler's terminal is now suppressed.
        let suppressed = table.consumeUnaryTerminal(msgid: 7)
        #expect(!suppressed)
    }

    @Test("an END on a live unary msgid is a unary violation")
    func unaryEndViolation() {
        var table = StreamTable()
        _ = table.registerUnary(msgid: 7)
        guard case .unaryViolation = table.routeEnd(msgid: 7) else {
            Issue.record("END on a live unary msgid is a unary violation")
            return
        }
        let suppressed = table.consumeUnaryTerminal(msgid: 7)
        #expect(!suppressed)
    }

    @Test("a normal unary call keeps its terminal; retiring an unknown msgid is allowed")
    func unaryTerminalKept() {
        var table = StreamTable()
        _ = table.registerUnary(msgid: 7)
        let live = table.consumeUnaryTerminal(msgid: 7)
        #expect(live)  // live → send
        // Retiring again (unknown now) still returns true — nothing to suppress.
        let again = table.consumeUnaryTerminal(msgid: 7)
        #expect(again)
    }

    // MARK: - Teardown

    @Test("liveControls returns every open stream without removing them")
    func liveControlsSnapshot() {
        var table = StreamTable()
        let a = RecordingStreamControl(request: true, response: false)
        let b = RecordingStreamControl(request: false, response: true)
        _ = table.registerStream(msgid: 1, entry: entry(a))
        _ = table.registerStream(msgid: 2, entry: entry(b))
        #expect(table.liveControls().count == 2)
        // Entries remain, so each handler's completion still retires + flushes.
        #expect(table.isStreamLive(msgid: 1))
        #expect(table.isStreamLive(msgid: 2))
    }
}

// MARK: - Property / interleaving test (the plan's headline unit deliverable)

/// A pure state-machine property test: seeded random interleavings of
/// items / credits / END / STOP / CANCEL / terminal against a reference model,
/// asserting the plan's named invariants — **never double-terminate**, **never
/// overrun credit** (an accepted item was always within the window), and
/// **always converge** (a terminal-authorizing transition retires the msgid).
///
/// Uses the seeded `SplitMix64` (no unseeded RNG in tests) over a fixed seed
/// set, so any failure reproduces exactly.
@Suite("Stream table state-machine property")
struct StreamTablePropertyTests {
    /// The reference model of one stream's per-direction state, kept in lockstep
    /// with the table so we can predict each decision independently.
    struct Model {
        var hasRequest: Bool
        var hasResponse: Bool
        var expectedInSeq: UInt32 = 0
        /// Remaining request credit (server is the receiver). Starts at the
        /// window; spent per delivered item; the model never grants more, so an
        /// overrun is reachable.
        var credit: Int
        var requestEnded = false
        var sourceTerminated = false
        /// The msgid has been retired (a terminal was authorized for it).
        var retired = false
    }

    /// The seeded PRNG driver. Returns the count of terminal-authorizing
    /// transitions observed per msgid — asserted to never exceed one.
    private func runInterleavings(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var table = StreamTable()
        let window = Int(MMStreamFlowControl.initialWindow)
        // A small msgid space so reuse/collisions actually happen.
        let msgids: [UInt32] = [1, 2, 3]
        var models: [UInt32: Model] = [:]
        var controls: [UInt32: RecordingStreamControl] = [:]
        // Terminal-authorizing transitions seen for the CURRENT incarnation of
        // each msgid. Reset to 0 on every accepted open (a msgid is retired
        // before it can be reused), so this counts terminals per live call — the
        // single-terminal invariant is "≤ 1 per incarnation", not per run.
        var terminalCount: [UInt32: Int] = [:]
        // Whether each msgid is currently registered as a live unary call.
        var unaryLive: Set<UInt32> = []

        func note(terminal msgid: UInt32) {
            terminalCount[msgid, default: 0] += 1
            #expect(
                terminalCount[msgid, default: 0] <= 1,
                "msgid \(msgid) double-terminated in one incarnation (seed \(seed))"
            )
        }
        func beginIncarnation(_ msgid: UInt32) { terminalCount[msgid] = 0 }

        for _ in 0..<400 {
            let msgid = msgids[Int(rng.next() % UInt64(msgids.count))]
            let action = rng.next() % 8
            switch action {
                case 0:  // open a stream
                    guard models[msgid] == nil, !unaryLive.contains(msgid) else {
                        // Reuse: the table must reject; no terminal is authorized here
                        // (the caller drops-and-counts).
                        let control = RecordingStreamControl(request: true, response: true)
                        let rejected = table.registerStream(msgid: msgid, entry: entry(control))
                        #expect(!rejected)
                        continue
                    }
                    let hasReq = rng.next() % 3 != 0  // mostly true
                    let hasResp = rng.next() % 2 == 0
                    let control = RecordingStreamControl(
                        request: hasReq, response: hasResp, credit: hasReq ? window : 0
                    )
                    let registered = table.registerStream(msgid: msgid, entry: entry(control))
                    #expect(registered)
                    beginIncarnation(msgid)
                    controls[msgid] = control
                    models[msgid] = Model(
                        hasRequest: hasReq, hasResponse: hasResp, credit: hasReq ? window : 0
                    )
                case 1:  // open a unary call
                    guard models[msgid] == nil, !unaryLive.contains(msgid) else {
                        let rejected = table.registerUnary(msgid: msgid)
                        #expect(!rejected)
                        continue
                    }
                    let unaryRegistered = table.registerUnary(msgid: msgid)
                    #expect(unaryRegistered)
                    beginIncarnation(msgid)
                    unaryLive.insert(msgid)
                case 2:  // route an item
                    if unaryLive.contains(msgid) {
                        guard case .unaryViolation = table.routeItem(msgid: msgid, seq: 0) else {
                            Issue.record(
                                "item on live unary should be unaryViolation (seed \(seed))")
                            return
                        }
                        unaryLive.remove(msgid)
                        note(terminal: msgid)  // code-6 terminal + suppresses unary terminal
                        // Consume the (now suppressed) unary terminal.
                        let suppressed = table.consumeUnaryTerminal(msgid: msgid)
                        #expect(!suppressed)
                        continue
                    }
                    guard var model = models[msgid], let control = controls[msgid] else {
                        // Unknown/retired: pure drop, no terminal.
                        guard case .drop = table.routeItem(msgid: msgid, seq: 0) else {
                            Issue.record("unknown-msgid item should drop (seed \(seed))")
                            return
                        }
                        continue
                    }
                    // Pick a seq: mostly in-order, sometimes a gap.
                    let seq: UInt32 =
                        rng.next() % 4 == 0
                        ? model.expectedInSeq &+ 1 : model.expectedInSeq
                    // Mirror the model's credit/terminated onto the control before the
                    // table consults them.
                    control.setCredit(model.credit)
                    if model.sourceTerminated { control.markTerminated() }
                    let decision = table.routeItem(msgid: msgid, seq: seq)
                    // Predict.
                    if !model.hasRequest {
                        guard case .violation = decision else {
                            Issue.record("undeclared direction should violate (seed \(seed))")
                            return
                        }
                        models[msgid] = nil
                        controls[msgid] = nil
                        note(terminal: msgid)
                    } else if model.requestEnded {
                        guard case .drop = decision else {
                            Issue.record("post-END item should drop (seed \(seed))")
                            return
                        }
                    } else if model.sourceTerminated {
                        guard case .drop = decision else {
                            Issue.record("post-termination item should drop (seed \(seed))")
                            return
                        }
                    } else if seq != model.expectedInSeq {
                        guard case .violation = decision else {
                            Issue.record("seq gap should violate (seed \(seed))")
                            return
                        }
                        models[msgid] = nil
                        controls[msgid] = nil
                        note(terminal: msgid)
                    } else if model.credit <= 0 {
                        guard case .violation = decision else {
                            Issue.record("overrun should violate (seed \(seed))")
                            return
                        }
                        models[msgid] = nil
                        controls[msgid] = nil
                        note(terminal: msgid)
                    } else {
                        guard case .deliver = decision else {
                            Issue.record("in-window item should deliver (seed \(seed))")
                            return
                        }
                        // Never overrun: an accepted item was within the window.
                        #expect(model.credit > 0, "delivered past credit window (seed \(seed))")
                        model.expectedInSeq &+= 1
                        model.credit -= 1
                        models[msgid] = model
                    }
                case 3:  // END the request direction
                    if unaryLive.contains(msgid) {
                        guard case .unaryViolation = table.routeEnd(msgid: msgid) else {
                            Issue.record(
                                "END on live unary should be unaryViolation (seed \(seed))")
                            return
                        }
                        unaryLive.remove(msgid)
                        note(terminal: msgid)
                        let suppressed = table.consumeUnaryTerminal(msgid: msgid)
                        #expect(!suppressed)
                        continue
                    }
                    guard var model = models[msgid] else {
                        guard case .drop = table.routeEnd(msgid: msgid) else {
                            Issue.record("unknown END should drop (seed \(seed))")
                            return
                        }
                        continue
                    }
                    let decision = table.routeEnd(msgid: msgid)
                    if !model.hasRequest {
                        guard case .violation = decision else {
                            Issue.record("END on undeclared should violate (seed \(seed))")
                            return
                        }
                        models[msgid] = nil
                        controls[msgid] = nil
                        note(terminal: msgid)
                    } else if model.requestEnded {
                        guard case .drop = decision else {
                            Issue.record("second END should drop (seed \(seed))")
                            return
                        }
                    } else {
                        guard case .end = decision else {
                            Issue.record("first END should route (seed \(seed))")
                            return
                        }
                        model.requestEnded = true
                        models[msgid] = model
                    }
                case 4:  // credit grant
                    let control = table.routeCredit(msgid: msgid)
                    if let model = models[msgid], model.hasResponse {
                        #expect(control != nil)
                    } else {
                        #expect(control == nil)  // no response direction / unknown → drop
                    }
                case 5:  // STOP
                    let control = table.routeStop(msgid: msgid)
                    if let model = models[msgid], model.hasResponse {
                        #expect(control != nil)
                    } else {
                        #expect(control == nil)
                    }
                case 6:  // the handler terminates its source (server-side end race)
                    if var model = models[msgid] {
                        model.sourceTerminated = true
                        models[msgid] = model
                    }
                case 7:  // CANCEL or retire (the handler's terminal)
                    if unaryLive.contains(msgid) {
                        // A unary handler's terminal: authorized once.
                        let send = table.consumeUnaryTerminal(msgid: msgid)
                        unaryLive.remove(msgid)
                        if send { note(terminal: msgid) }
                        continue
                    }
                    guard models[msgid] != nil else {
                        // Retiring an unknown msgid: returns true (nothing to
                        // suppress) but authorizes no wire terminal for a live call.
                        _ = table.retireStream(msgid: msgid)
                        continue
                    }
                    // Half CANCEL, half graceful retire.
                    if rng.next() % 2 == 0 {
                        let cancelled = table.routeCancel(msgid: msgid)
                        #expect(cancelled != nil)
                        note(terminal: msgid)  // runtime sends code-7
                    } else {
                        let retired = table.retireStream(msgid: msgid)  // handler terminal
                        #expect(retired)
                        note(terminal: msgid)
                    }
                    models[msgid] = nil
                    controls[msgid] = nil
                default:
                    break
            }
        }

        // Convergence: drive every still-live entry to its terminal exactly once
        // and confirm no msgid ever exceeded one terminal.
        for msgid in msgids {
            if unaryLive.contains(msgid) {
                if table.consumeUnaryTerminal(msgid: msgid) { note(terminal: msgid) }
            } else if models[msgid] != nil {
                let retired = table.retireStream(msgid: msgid)
                #expect(retired)
                note(terminal: msgid)
            }
            #expect(
                !table.isStreamLive(msgid: msgid), "msgid \(msgid) did not converge (seed \(seed))")
            #expect(terminalCount[msgid, default: 0] <= 1)
        }
    }

    @Test(
        "random interleavings never double-terminate, never overrun, always converge",
        arguments: [
            0x1, 0xDEAD_BEEF, 0xC0FF_EE, 0x1234_5678_9ABC_DEF0,
            0xFACE, 0xBADC_0DE, 0x5EED, 0xA5A5_A5A5, 0x0F0F_0F0F, 0x7,
        ] as [UInt64]
    )
    func propertyHolds(seed: UInt64) {
        self.runInterleavings(seed: seed)
    }
}

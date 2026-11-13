import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMServer

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
        #expect(first != nil)
        #expect(table.openStreamCount == 1)
        // Same msgid still live: reuse rejected.
        let reused = table.registerStream(msgid: 5, entry: entry(control))
        #expect(reused == nil)
        // A msgid marked as a live unary call also blocks a stream registration.
        let unaryRegistered = table.registerUnary(msgid: 6)
        #expect(unaryRegistered != nil)
        let unaryClash = table.registerStream(msgid: 6, entry: entry(control))
        #expect(unaryClash == nil)
        // Every registration is its own call.
        #expect(first != unaryRegistered)
    }

    @Test("registerUnary rejects a msgid already owned by a live stream or unary call")
    func registerUnaryRejectsReuse() {
        var table = StreamTable()
        // A live unary msgid cannot be reused for another unary call.
        let firstUnary = table.registerUnary(msgid: 3)
        #expect(firstUnary != nil)
        let reusedUnary = table.registerUnary(msgid: 3)
        #expect(reusedUnary == nil)
        // A live stream msgid blocks a unary registration on the same id.
        let control = RecordingStreamControl(request: true, response: false)
        _ = table.registerStream(msgid: 4, entry: entry(control))
        let unaryOnStream = table.registerUnary(msgid: 4)
        #expect(unaryOnStream == nil)
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
    func retireOnce() throws {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: true)
        let registration = table.registerStream(msgid: 1, entry: entry(control))
        let call = try #require(registration)
        let first = table.retireStream(msgid: 1, call: call)
        #expect(first)
        let second = table.retireStream(msgid: 1, call: call)
        #expect(!second)
    }

    @Test("a CANCEL then a handler completion never double-terminates")
    func cancelThenCompletionSingleTerminal() throws {
        var table = StreamTable()
        let control = RecordingStreamControl(request: true, response: true)
        let registration = table.registerStream(msgid: 1, entry: entry(control))
        let call = try #require(registration)
        // CANCEL retires the entry (runtime sends code-7).
        let cancelled = table.routeCancel(msgid: 1)
        #expect(cancelled != nil)
        // The handler later completes and asks to retire: already gone, so its
        // terminal is suppressed.
        let retired = table.retireStream(msgid: 1, call: call)
        #expect(!retired)
    }

    @Test("a handler that returns after its call was answered leaves a reused msgid alone")
    func lateHandlerLeavesReusedMsgid() throws {
        var table = StreamTable()
        let first = RecordingStreamControl(request: true, response: true)
        let firstRegistration = table.registerStream(msgid: 1, entry: entry(first))
        let firstCall = try #require(firstRegistration)
        // The code-7 answers the first call, so the client may reuse msgid 1
        // while the first handler is still running.
        #expect(table.routeCancel(msgid: 1) != nil)
        let second = RecordingStreamControl(request: true, response: true)
        let secondRegistration = table.registerStream(msgid: 1, entry: entry(second))
        let secondCall = try #require(secondRegistration)
        #expect(secondCall != firstCall)
        // The first handler returns: nothing of its own to retire.
        let firstRetired = table.retireStream(msgid: 1, call: firstCall)
        #expect(!firstRetired)
        #expect(table.isStreamLive(msgid: 1))
        let secondRetired = table.retireStream(msgid: 1, call: secondCall)
        #expect(secondRetired)
        #expect(!table.isStreamLive(msgid: 1))
    }

    // MARK: - Unary-msgid guard

    @Test("a stream item on a live unary msgid is a unary violation and suppresses its terminal")
    func unaryViolationSuppresses() throws {
        var table = StreamTable()
        let registration = table.registerUnary(msgid: 7)
        let call = try #require(registration)
        guard case .unaryViolation = table.routeItem(msgid: 7, seq: 0) else {
            Issue.record("item on a live unary msgid is a unary violation")
            return
        }
        // The unary handler's terminal is now suppressed.
        let suppressed = table.consumeUnaryTerminal(msgid: 7, call: call)
        #expect(!suppressed)
    }

    @Test("an END on a live unary msgid is a unary violation")
    func unaryEndViolation() throws {
        var table = StreamTable()
        let registration = table.registerUnary(msgid: 7)
        let call = try #require(registration)
        guard case .unaryViolation = table.routeEnd(msgid: 7) else {
            Issue.record("END on a live unary msgid is a unary violation")
            return
        }
        let suppressed = table.consumeUnaryTerminal(msgid: 7, call: call)
        #expect(!suppressed)
    }

    @Test("only the first stream frame on a live unary msgid is a violation; later ones drop")
    func unaryViolationAnswersOnce() throws {
        var table = StreamTable()
        let registration = table.registerUnary(msgid: 7)
        let call = try #require(registration)
        guard case .unaryViolation = table.routeEnd(msgid: 7) else {
            Issue.record("the first END on a live unary msgid is a unary violation")
            return
        }
        // Its code-6 terminal answered the call, so no frame earns a second one.
        guard case .drop = table.routeEnd(msgid: 7) else {
            Issue.record("a second END on an answered unary msgid drops")
            return
        }
        guard case .drop = table.routeItem(msgid: 7, seq: 0) else {
            Issue.record("an item on an answered unary msgid drops")
            return
        }
        let send = table.consumeUnaryTerminal(msgid: 7, call: call)
        #expect(!send)
    }

    @Test("a unary msgid answered by a code-6 is free for a new call before its handler returns")
    func unaryMsgidReusedAfterViolation() throws {
        var table = StreamTable()
        let firstRegistration = table.registerUnary(msgid: 7)
        let firstCall = try #require(firstRegistration)
        guard case .unaryViolation = table.routeItem(msgid: 7, seq: 0) else {
            Issue.record("item on a live unary msgid is a unary violation")
            return
        }
        // The client has its terminal, so it may reuse msgid 7.
        #expect(!table.isOwned(msgid: 7))
        let secondRegistration = table.registerUnary(msgid: 7)
        let secondCall = try #require(secondRegistration)
        // The first handler returns: its terminal stays dropped, and the
        // second call keeps the msgid.
        let firstSends = table.consumeUnaryTerminal(msgid: 7, call: firstCall)
        #expect(!firstSends)
        #expect(table.isOwned(msgid: 7))
        let secondSends = table.consumeUnaryTerminal(msgid: 7, call: secondCall)
        #expect(secondSends)
        #expect(!table.isOwned(msgid: 7))
    }

    @Test("a normal unary call sends its terminal once")
    func unaryTerminalKept() throws {
        var table = StreamTable()
        let registration = table.registerUnary(msgid: 7)
        let call = try #require(registration)
        let live = table.consumeUnaryTerminal(msgid: 7, call: call)
        #expect(live)  // live → send
        // The call is retired: a second consume finds nothing to send.
        let again = table.consumeUnaryTerminal(msgid: 7, call: call)
        #expect(!again)
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

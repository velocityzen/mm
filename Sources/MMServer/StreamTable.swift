import MMWire

/// The per-connection stream state machine: msgid → per-stream direction state,
/// plus the set of live unary msgids (so a stream frame misaddressed to a unary
/// call is a violation, not a silent drop).
///
/// A **pure value type**, wrapped by the connection in one `NIOLockedValueBox`.
/// It lives with the connection (the request loop's scope), never in the
/// ``Router`` — the router is shared across every connection and stays
/// stateless. Every routing decision (deliver / violation / drop / grant / stop
/// / cancel / retire) is computed here under the connection's lock and returned
/// as an *action*; the connection applies the side effects (yielding elements,
/// resuming senders, writing terminals, cancelling tasks) **outside** the lock.
/// No lock is ever held across a suspension point.
///
/// ## State machine (per msgid, mirrored on the client)
///
/// Each declared item direction is `open → ended`. The request direction ends
/// on client END, and the whole entry retires on the terminal from any state.
/// Late items racing the request direction's end — an item after the client's
/// own END, or after the server terminated the request source (handler returned
/// / stopped consuming) — are dropped-and-counted, never violations (the
/// in-flight-race tolerance). The four **true** violations return `.violation`,
/// which the connection answers with a code-6 terminal that also retires the
/// msgid:
///
/// 1. an item on an undeclared request direction,
/// 2. a seq gap,
/// 3. a credit overrun on a still-live source,
/// 4. a request item whose payload fails to decode as the declared element type.
///
/// A stream frame addressed to a live unary msgid is a separate case
/// (`.unaryViolation`), also answered with a code-6 terminal.
///
/// ## Single-terminal invariant
///
/// A msgid is present in exactly one of `streams` or `unary`, or in neither
/// (never registered, or already retired). Every terminal-producing transition
/// (a `.violation` decision, `routeCancel`, and the handler-completion
/// `retireStream`) removes the entry in the same locked mutation that
/// authorizes the terminal, so the connection sends exactly one terminal per
/// msgid and a second frame for a retired msgid can only reach the drop path.
/// `retireStream` returns false once the entry is gone, which is how a handler
/// completing *after* a CANCEL/violation has its now-redundant terminal
/// suppressed.
struct StreamTable: Sendable {
    /// One live stream's direction bookkeeping. The erased `control` applies
    /// effects; the flags here decide legality without touching `Element` types.
    struct Entry {
        let control: any StreamControl
        let hasRequestStream: Bool
        let hasResponseStream: Bool
        /// Next inbound request-item seq expected, u32 from 0; validated
        /// strictly (any other value is a gap violation).
        var expectedInSeq: UInt32 = 0
        /// The client sent END for its request direction; further items are
        /// (late) drops, and a second END is a drop.
        var requestEnded = false
    }

    /// A live unary call's terminal disposition.
    enum UnaryState {
        /// Dispatch is running; its terminal will be sent when the handler
        /// returns.
        case live
        /// A stream frame hit this live unary msgid: the connection already
        /// answered with a code-6 terminal, so the unary handler's own terminal
        /// must be suppressed to preserve the single-terminal guarantee.
        case suppressed
    }

    private var streams: [UInt32: Entry] = [:]
    /// Live unary-call msgids and whether their terminal is still owed, so a
    /// stream frame addressed to one is classified as a violation (not an
    /// unknown-msgid drop) and the redundant unary terminal is suppressed.
    private var unary: [UInt32: UnaryState] = [:]

    /// Count of currently open streams, against
    /// `maxConcurrentStreamsPerConnection`.
    var openStreamCount: Int { self.streams.count }

    // MARK: - Registration

    /// Registers an accepted stream open. Fails (returns false) if the msgid is
    /// already in use — a client bug (msgid reuse while live); the connection
    /// answers such an open with an internal-error terminal. The cap is checked
    /// by the caller before this (an over-cap open never reaches here).
    mutating func registerStream(msgid: UInt32, entry: Entry) -> Bool {
        guard self.streams[msgid] == nil, self.unary[msgid] == nil else {
            return false
        }
        self.streams[msgid] = entry
        return true
    }

    /// Whether `msgid` is already owned by a live stream or a live unary call.
    /// A reopen on such a msgid is a client bug: the original call still owns the
    /// single terminal for it, so the reopen must be dropped-and-counted (no new
    /// terminal), never rejected with a terminal of its own.
    func isOwned(msgid: UInt32) -> Bool {
        self.streams[msgid] != nil || self.unary[msgid] != nil
    }

    /// Marks a msgid as a live unary call for the duration of its dispatch, so
    /// stream frames targeting it are violations. Fails (returns false) if the
    /// msgid is already owned by a live stream or unary call — a reused msgid,
    /// which the caller drops-and-counts rather than registering a second
    /// competing terminal owner (the single-terminal invariant).
    mutating func registerUnary(msgid: UInt32) -> Bool {
        guard self.streams[msgid] == nil, self.unary[msgid] == nil else {
            return false
        }
        self.unary[msgid] = .live
        return true
    }

    /// Whether the unary handler's terminal for `msgid` should be sent, then
    /// retires the unary entry. Returns false when a stream frame already forced
    /// a code-6 terminal for this msgid (state `.suppressed`), so the connection
    /// drops the redundant unary terminal.
    mutating func consumeUnaryTerminal(msgid: UInt32) -> Bool {
        switch self.unary.removeValue(forKey: msgid) {
            case .suppressed: return false
            case .live, nil: return true
        }
    }

    // MARK: - Frame routing actions

    /// Routes one stream item (kind 3).
    mutating func routeItem(msgid: UInt32, seq: UInt32) -> ItemDecision {
        if self.unary[msgid] != nil {
            self.unary[msgid] = .suppressed
            return .unaryViolation
        }
        guard var entry = self.streams[msgid] else { return .drop }
        guard entry.hasRequestStream else {
            self.streams[msgid] = nil
            return .violation(entry.control)
        }
        if entry.requestEnded {
            // Late item after the client's own END: a drop, not a violation
            // (in-flight races are tolerated).
            return .drop
        }
        if entry.control.requestSourceTerminated() {
            // The server ended the request direction (handler returned or
            // stopped consuming) but the entry has not been retired yet. An
            // item racing that teardown is the same tolerated in-flight race as
            // an item after the client's own END — drop-and-count, never a
            // violation. Checked before seq/credit so a legitimately in-flight
            // item is not punished for a race the plan says must be tolerated.
            return .drop
        }
        guard seq == entry.expectedInSeq else {
            self.streams[msgid] = nil
            return .violation(entry.control)
        }
        guard entry.control.requestHasCredit() else {
            self.streams[msgid] = nil
            return .violation(entry.control)
        }
        entry.expectedInSeq &+= 1
        self.streams[msgid] = entry
        return .deliver(entry.control)
    }

    /// The outcome of `routeItem` — mirrors ``Action`` but names only the item
    /// cases, so the connection's item path is exhaustive without a default.
    enum ItemDecision {
        case deliver(any StreamControl)
        case violation(any StreamControl)
        case unaryViolation
        case drop
    }

    /// Routes a credit grant (kind 2). Grants for the response direction reach
    /// the sink; grants on a stream with no response direction, or an unknown
    /// msgid, are dropped.
    func routeCredit(msgid: UInt32) -> (any StreamControl)? {
        guard let entry = self.streams[msgid], entry.hasResponseStream else { return nil }
        return entry.control
    }

    /// Routes a client END (kind 4). Returns the control to finish the request
    /// direction, or nil to drop (unknown msgid, no request direction, or a
    /// second END).
    mutating func routeEnd(msgid: UInt32) -> EndDecision {
        if self.unary[msgid] != nil {
            self.unary[msgid] = .suppressed
            return .unaryViolation
        }
        guard var entry = self.streams[msgid] else { return .drop }
        guard entry.hasRequestStream else {
            self.streams[msgid] = nil
            return .violation(entry.control)
        }
        guard !entry.requestEnded else { return .drop }
        entry.requestEnded = true
        self.streams[msgid] = entry
        return .end(entry.control)
    }

    enum EndDecision {
        case end(any StreamControl)
        case violation(any StreamControl)
        case unaryViolation
        case drop
    }

    /// Routes a client STOP (kind 5) for the response direction. Advisory: on a
    /// stream with no response direction, or an unknown msgid, it is a drop
    /// (never a violation). A STOP addressed to a live unary msgid is also just
    /// dropped — the caller has no response stream to stop and the call answers
    /// itself.
    func routeStop(msgid: UInt32) -> (any StreamControl)? {
        guard let entry = self.streams[msgid], entry.hasResponseStream else { return nil }
        return entry.control
    }

    /// Routes a client CANCEL (kind 6). Removes and returns the entry's control
    /// so the connection cancels the handler and sends a code-7 terminal; a
    /// CANCEL for an unknown/retired msgid, or a live unary msgid, is a drop
    /// (unary calls answer with their own terminal and CANCEL is client→whole
    /// call — retiring an already-answering unary would double-terminate).
    mutating func routeCancel(msgid: UInt32) -> (any StreamControl)? {
        guard let entry = self.streams[msgid] else { return nil }
        self.streams[msgid] = nil
        return entry.control
    }

    // MARK: - Retirement

    /// Retires a stream on its handler's terminal (graceful return or the
    /// code-6/7 terminal already accounted). Returns false if the entry was
    /// already gone (a CANCEL or violation retired it first), so the connection
    /// suppresses the now-redundant terminal — the single-terminal guarantee.
    mutating func retireStream(msgid: UInt32) -> Bool {
        self.streams.removeValue(forKey: msgid) != nil
    }

    /// Whether a stream entry is still live (test/debug aid).
    func isStreamLive(msgid: UInt32) -> Bool {
        self.streams[msgid] != nil
    }

    /// Connection teardown / graceful shutdown: returns every live stream's
    /// control so the connection can cancel each handler and finish its streams.
    /// **Does not remove the entries** — each handler's completion still runs
    /// through `retireStream`/`finishStream`, so its terminal flushes through
    /// the writer before the channel closes (the graceful-drain contract).
    /// Unary msgids need no teardown (their tasks are in the same group).
    func liveControls() -> [any StreamControl] {
        self.streams.values.map(\.control)
    }
}

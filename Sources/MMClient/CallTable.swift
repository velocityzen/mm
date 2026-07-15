import MMWire
import NIOCore

/// The raw error/result slots of one response envelope, handed from the
/// inbound loop to the awaiting call task. Payload decoding happens in the
/// *call* task, so a result that fails to decode fails exactly that call and
/// nothing else.
struct ResponseSlots: Sendable, Equatable {
    var error: MMErrorObject?
    var result: ByteBuffer?
}

/// The connection's whole multiplexing state machine: msgid allocation, the
/// pending-call map, the in-flight cap, the outbound-writer slot, and the
/// closed flag. Pure value type — the connection wraps it in one
/// `NIOLockedValueBox` (a lock is required over an actor because task
/// *cancellation handlers are synchronous* and must resolve pending entries
/// without suspending).
///
/// ## Unary and stream entries
///
/// A msgid entry is either a unary call (the `reserved`/`waiting`/`completed`
/// continuation lifecycle above) or a live `stream` — a `ClientStreamControl`
/// that owns the inbound element producer, the outbound credit gate, and the
/// terminal continuation(s). A stream is opened by `reserve` (unary-style) then
/// `installStream`; retired only by its terminal (`complete` → `.stream`),
/// a client CANCEL (`retireStreamForCancel`), or `close`. The single-terminal
/// invariant holds for streams too: every terminal-producing transition removes
/// the entry in the same locked mutation, so a second terminal for a retired
/// msgid can only reach the drop path.
///
/// ## Single-resume invariant (audited per path)
///
/// A `CheckedContinuation` is only ever stored inside `Entry.waiting`, and
/// every transition that produces a continuation *removes it from the table in
/// the same locked mutation*. Since removal is the only way to obtain a stored
/// continuation, and each mutating method returns at most one continuation per
/// entry, resuming exactly once is structural, not disciplinary. The paths:
///
/// - **response**: `complete` — `.waiting` → removed + resumed; `.reserved`
///   (response raced ahead of the caller's suspension) → `.completed(outcome)`
///   parked for `register` to claim; unknown msgid → dropped.
/// - **caller suspends**: `register` — `.reserved` → `.waiting`; a parked
///   `.completed` is claimed (removed) and resumed immediately by the caller;
///   a missing entry means cancellation raced ahead → resumed `.cancelled`.
/// - **cancellation**: `cancel` — `.waiting` → removed + resumed
///   `.cancelled`; `.reserved` → removed (the later `register` observes the
///   missing entry); `.completed` → left for `register`, the response wins.
/// - **write failure / encode failure**: `abandon` — `.reserved` → removed
///   (caller supplies its own error, no continuation exists yet).
/// - **connection death / teardown**: `close` — every `.waiting` removed +
///   resumed with the close reason; every `.reserved` parked as
///   `.completed(failure)` for its caller's `register` to claim. Idempotent:
///   a second `close` returns nothing.
///
/// The lock is never held across a suspension point: all methods here are
/// synchronous, and callers resume the returned continuations *after*
/// releasing the lock.
struct CallTable: Sendable {
    typealias Outcome = Result<ResponseSlots, MMCallError>
    typealias Continuation = CheckedContinuation<Outcome, Never>
    typealias Writer = NIOAsyncChannelOutboundWriter<ByteBuffer>
    typealias WriterContinuation = CheckedContinuation<Result<Writer, MMCallError>, Never>

    enum Entry {
        /// msgid allocated, request not yet awaited (encode/write in progress).
        case reserved
        /// The caller is suspended on this continuation.
        case waiting(Continuation)
        /// The outcome arrived before the caller suspended; parked for pickup.
        case completed(Outcome)
        /// A live streaming call. The erased control owns the inbound producer,
        /// the outbound credit gate, and the terminal continuation(s); the
        /// inbound loop routes kinds 2-6 and the terminal to it. A stream entry
        /// is retired only by its terminal / cancel / connection death (never by
        /// unary `complete`).
        case stream(any ClientStreamControl)
    }

    /// Where the connection is in its life. `starting` = `run()` has not yet
    /// produced the outbound writer; calls park as writer waiters.
    enum Phase {
        case starting
        case running(Writer)
        case closed(MMCallError)
    }

    var phase: Phase = .starting
    var entries: [UInt32: Entry] = [:]
    /// Next msgid to hand out. Starts at 1 and wraps through the full `u32`
    /// range (0 is produced after wrap; msgid values carry no semantics).
    var nextMsgid: UInt32 = 1
    var writerWaiters: [UInt64: WriterContinuation] = [:]
    /// Waiter ids whose cancellation handler ran before the waiter registered
    /// its continuation (cancellation can race registration).
    var cancelledWriterWaiters: Set<UInt64> = []
    var nextWriterWaiterID: UInt64 = 0

    // MARK: - Call lifecycle

    /// Allocates a msgid and reserves its slot, enforcing the in-flight cap.
    /// Excess calls fail immediately — bounded, never queued.
    ///
    /// ## Wrap policy: skip live ids
    ///
    /// Long-lived streams keep a msgid live indefinitely, so a collision at wrap
    /// is *reachable* (unlike the unary-only world, where 2^32 concurrently
    /// pending calls was impossible). Allocation therefore **skips** any msgid
    /// still live in the table, scanning forward from `nextMsgid`. The in-flight
    /// cap bounds the number of live ids far below 2^32, so a free id always
    /// exists within a bounded scan; the `precondition` fires only in the truly
    /// pathological all-4-billion-live case, which the cap makes unreachable.
    mutating func reserve(cap: Int) -> Result<UInt32, MMCallError> {
        if case .closed(let reason) = self.phase {
            return .failure(reason)
        }
        guard self.entries.count < cap else {
            return .failure(.tooManyInFlight)
        }
        var scanned: UInt64 = 0
        while self.entries[self.nextMsgid] != nil {
            self.nextMsgid &+= 1
            scanned &+= 1
            precondition(
                scanned < UInt64(UInt32.max) + 1,
                "no free msgid: all 2^32 ids are live"
            )
        }
        let msgid = self.nextMsgid
        self.nextMsgid &+= 1
        self.entries[msgid] = .reserved
        return .success(msgid)
    }

    /// What the inbound loop should do with a response for `msgid`.
    enum CompleteAction {
        /// Resume this continuation with the outcome, outside the lock.
        case resume(Continuation)
        /// Outcome parked; the caller had not suspended yet.
        case parked
        /// The msgid is a live stream: hand the terminal slots to its control
        /// (which decodes, resolves the terminal, and finishes the sequence).
        /// The entry is retired here so no second terminal can route.
        case stream(any ClientStreamControl)
        /// No such msgid (late response for an abandoned call, or a server
        /// bug): drop it, log, count.
        case dropped
    }

    /// Routes a terminal response to its pending call or live stream.
    mutating func complete(msgid: UInt32, outcome: Outcome) -> CompleteAction {
        switch self.entries[msgid] {
            case nil, .completed:
                // Unknown msgid, or a duplicate response racing a parked outcome:
                // first one wins, this one drops.
                return .dropped
            case .reserved:
                self.entries[msgid] = .completed(outcome)
                return .parked
            case .waiting(let continuation):
                self.entries[msgid] = nil
                return .resume(continuation)
            case .stream(let control):
                // The terminal retires the whole stream call. Removing the entry in
                // this same mutation guarantees a second terminal for the msgid can
                // only hit the drop path (single-terminal invariant).
                self.entries[msgid] = nil
                return .stream(control)
        }
    }

    /// The caller registers its continuation. Returns a non-nil outcome when
    /// the wait is already over (parked response, or cancellation raced
    /// ahead); the caller resumes its own continuation with it immediately.
    mutating func register(msgid: UInt32, continuation: Continuation) -> Outcome? {
        switch self.entries[msgid] {
            case nil:
                // cancel() removed the reservation before we suspended.
                return .failure(.cancelled)
            case .reserved:
                self.entries[msgid] = .waiting(continuation)
                return nil
            case .completed(let outcome):
                self.entries[msgid] = nil
                return outcome
            case .waiting:
                preconditionFailure("msgid \(msgid) registered twice")
            case .stream:
                preconditionFailure("msgid \(msgid) is a stream; unary register is invalid")
        }
    }

    /// Task-cancellation path (synchronous — called from a cancellation
    /// handler). Returns the continuation to resume with `.cancelled`, if the
    /// caller was already suspended.
    mutating func cancel(msgid: UInt32) -> Continuation? {
        switch self.entries[msgid] {
            case nil, .completed:
                // Already resolved, or the response won the race — `register`
                // delivers the parked outcome; cancellation loses gracefully.
                return nil
            case .reserved:
                self.entries[msgid] = nil
                return nil
            case .waiting(let continuation):
                self.entries[msgid] = nil
                return continuation
            case .stream:
                preconditionFailure("msgid \(msgid) is a stream; unary cancel is invalid")
        }
    }

    /// Abandons a reservation before suspension (envelope encode failure or a
    /// failed write). Returns a parked outcome if one raced in; `nil` means
    /// the caller reports its own error. Never sees `.waiting` — the caller
    /// has not suspended yet.
    mutating func abandon(msgid: UInt32) -> Outcome? {
        switch self.entries[msgid] {
            case nil:
                return .failure(.cancelled)
            case .reserved:
                self.entries[msgid] = nil
                return nil
            case .completed(let outcome):
                self.entries[msgid] = nil
                return outcome
            case .waiting:
                preconditionFailure("abandon(msgid:) while a continuation is registered")
            case .stream:
                preconditionFailure("abandon(msgid:) on a stream entry")
        }
    }

    // MARK: - Stream lifecycle

    /// Transitions a reserved msgid into a live stream once its opening request
    /// is on the wire. Returns a parked terminal outcome if one raced in before
    /// the caller installed the control (a terminal for a stream whose open
    /// request was written but whose control was not yet installed); the caller
    /// hands that outcome straight to the control. `nil` means the stream is now
    /// live in the table. Never sees `.waiting` (a stream never registers a
    /// unary continuation).
    mutating func installStream(
        msgid: UInt32,
        control: any ClientStreamControl
    ) -> Outcome? {
        switch self.entries[msgid] {
            case nil:
                // The connection closed and drained the reservation; the terminal
                // must be delivered as the close failure. Treat a missing entry the
                // same as a parked close failure would be handled by the caller.
                if case .closed(let reason) = self.phase {
                    return .failure(reason)
                }
                return .failure(.cancelled)
            case .reserved:
                self.entries[msgid] = .stream(control)
                return nil
            case .completed(let outcome):
                // A terminal parked before the control was installed: retire the
                // entry and hand the outcome to the caller for the control.
                self.entries[msgid] = nil
                return outcome
            case .waiting:
                preconditionFailure(
                    "installStream(msgid:) while a unary continuation is registered")
            case .stream:
                preconditionFailure("installStream(msgid:) on an already-streaming msgid")
        }
    }

    /// The live stream control for `msgid`, for routing a stream-lifecycle frame
    /// (kinds 2-5). Returns nil for unknown/retired msgids or unary entries —
    /// the connection then drops-and-counts the frame (unknown msgid) or treats
    /// it per the unary-msgid violation policy.
    func streamControl(msgid: UInt32) -> (any ClientStreamControl)? {
        guard case .stream(let control) = self.entries[msgid] else { return nil }
        return control
    }

    /// Whether `msgid` names a live entry that is NOT a stream (unary reserved /
    /// waiting / completed). Used by the inbound loop to distinguish a stream
    /// frame that hit a live unary msgid (a server protocol violation) from one
    /// for an unknown/retired msgid (a drop-and-count).
    func isLiveUnary(msgid: UInt32) -> Bool {
        switch self.entries[msgid] {
            case .reserved, .waiting, .completed: return true
            case .stream, nil: return false
        }
    }

    /// Retires a stream on a client-initiated CANCEL (kind 6): removes and
    /// returns the control so the connection resolves its surfaces `.cancelled`
    /// and drops the server's later code-7 terminal. Returns nil if the entry is
    /// already gone (terminal/death won the race), so the CANCEL is a no-op.
    mutating func retireStreamForCancel(msgid: UInt32) -> (any ClientStreamControl)? {
        guard case .stream(let control) = self.entries[msgid] else { return nil }
        self.entries[msgid] = nil
        return control
    }

    // MARK: - Writer slot

    /// `run()` installs the outbound writer; parked writer waiters are
    /// returned for resumption with `.success(writer)` outside the lock.
    mutating func installWriter(_ writer: Writer) -> [WriterContinuation] {
        guard case .starting = self.phase else {
            // Already closed (close() raced run()): waiters were drained by
            // close; nothing to do.
            return []
        }
        self.phase = .running(writer)
        let waiters = Array(self.writerWaiters.values)
        self.writerWaiters.removeAll()
        return waiters
    }

    mutating func allocateWriterWaiterID() -> UInt64 {
        self.nextWriterWaiterID &+= 1
        return self.nextWriterWaiterID
    }

    /// Registers a writer waiter. Non-nil means resolve immediately (writer
    /// ready, connection closed, or cancellation raced registration).
    mutating func registerWriterWaiter(
        id: UInt64,
        continuation: WriterContinuation
    ) -> Result<Writer, MMCallError>? {
        switch self.phase {
            case .running(let writer):
                return .success(writer)
            case .closed(let reason):
                return .failure(reason)
            case .starting:
                if self.cancelledWriterWaiters.remove(id) != nil {
                    return .failure(.cancelled)
                }
                self.writerWaiters[id] = continuation
                return nil
        }
    }

    /// Cancellation path for a writer waiter (synchronous).
    mutating func cancelWriterWaiter(id: UInt64) -> WriterContinuation? {
        if let continuation = self.writerWaiters.removeValue(forKey: id) {
            return continuation
        }
        if case .starting = self.phase {
            self.cancelledWriterWaiters.insert(id)
        }
        return nil
    }

    // MARK: - Teardown

    /// Closes the table: every suspended caller and writer waiter is returned
    /// for resumption with `reason`, and every live stream's control is returned
    /// so the connection can fail its terminal (and inbound sequence and parked
    /// sender). Reservations whose callers have not suspended yet are parked as
    /// failures for their `register` to claim. Idempotent — the first reason
    /// wins, a second close returns nothing.
    mutating func close(
        reason: MMCallError
    ) -> (
        calls: [Continuation],
        writerWaiters: [WriterContinuation],
        streams: [any ClientStreamControl]
    ) {
        if case .closed = self.phase {
            return ([], [], [])
        }
        self.phase = .closed(reason)
        var calls: [Continuation] = []
        var streams: [any ClientStreamControl] = []
        for (msgid, entry) in self.entries {
            switch entry {
                case .reserved:
                    self.entries[msgid] = .completed(.failure(reason))
                case .waiting(let continuation):
                    self.entries[msgid] = nil
                    calls.append(continuation)
                case .completed:
                    break
                case .stream(let control):
                    self.entries[msgid] = nil
                    streams.append(control)
            }
        }
        let waiters = Array(self.writerWaiters.values)
        self.writerWaiters.removeAll()
        self.cancelledWriterWaiters.removeAll()
        return (calls, waiters, streams)
    }
}

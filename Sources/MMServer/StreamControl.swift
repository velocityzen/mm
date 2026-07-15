import MMWire
import NIOCore

/// The type-erased control surface of one live stream, held by the
/// ``StreamTable`` so it can route wire frames (items, credits, STOP, END,
/// CANCEL, terminal) without knowing the stream's `Element` types.
///
/// Concrete conformers wrap the request-stream source and/or the response
/// sink and the handler task. The table decides *whether* a frame is legal
/// (direction declared, seq in order, credit available) under its own lock and
/// then calls exactly one of these methods **outside** the lock to apply the
/// effect — yield an element, resume a parked sender, cancel the task. None of
/// these methods suspend on a lock the table holds.
protocol StreamControl: Sendable {
    /// Whether this stream declares an inbound (request) direction. Fixed at
    /// registration.
    var hasRequestStream: Bool { get }
    /// Whether this stream declares an outbound (response) direction. Fixed at
    /// registration.
    var hasResponseStream: Bool { get }

    /// The request-stream source has credit for one more item (server is the
    /// receiver). Consulted by the table before ``deliver(_:)`` so a credit
    /// overrun becomes a violation, not a silent buffer growth. False for
    /// streams with no request direction.
    ///
    /// This is a pure credit check — it does **not** fold in termination. The
    /// table consults ``requestSourceTerminated()`` first so an item racing the
    /// server-side end of the request direction (handler returned / stopped
    /// consuming) is a tolerated late-drop, never misread as an overrun.
    func requestHasCredit() -> Bool

    /// Whether the request source has already terminated (the handler returned,
    /// stopped consuming, or the stream is otherwise winding down). An item
    /// arriving after this is a tolerated late-drop, not a violation — the same
    /// in-flight-race tolerance as an item after the client's own END. True for
    /// streams with no request direction (there is nothing left to feed).
    func requestSourceTerminated() -> Bool

    /// Deliver one already-credit-checked request item. Returns `.failure` when
    /// the element fails to decode (a stream violation the table turns into a
    /// code-6 terminal). Never called for streams with no request direction
    /// (the table rejects those items as violations first).
    func deliver(_ item: ByteBuffer) -> Result<Void, MMWireError>

    /// Client END on the request direction: finish the handler's element
    /// sequence gracefully.
    func clientEndRequest()

    /// Client credit grant (kind 2) for the response direction: release credit
    /// to the parked response sender. No-op for streams with no response
    /// direction.
    func grantResponse(_ credits: UInt32)

    /// Client STOP (kind 5) for the response direction: the response sink's
    /// `send` starts reporting `.peerStopped`. No-op for streams with no
    /// response direction.
    func clientStopResponse()

    /// Terminal / CANCEL / connection death: finish the inbound sequence and
    /// resolve the outbound sink as ended, so the handler unwinds. Idempotent.
    func endStreams()

    /// Cancel the handler task cooperatively (client CANCEL / connection death).
    func cancelHandler()

    /// Install the handler-task cancel hook. Called once by the connection right
    /// after it launches the handler, before any frame can route a CANCEL here.
    func attachCancel(_ cancel: @escaping @Sendable () -> Void)
}

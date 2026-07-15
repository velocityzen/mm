import Logging
import MMWire
import NIOConcurrencyHelpers
import NIOCore

/// The initial per-direction credit window, a spec constant (matter-in-motion
/// streaming plan): 8 items. Each side may send 8 items before the first
/// credit grant. Correctness never depends on the value — it only bounds the
/// pre-grant burst — but it must match the server's constant so the outbound
/// gate does not over- or under-send before the first grant.
enum StreamCredit {
    /// Items each direction may send before the first credit grant, and the
    /// batch size the inbound consumer grants back as it drains.
    static let initialWindow: UInt32 = 8
}

/// The inbound response-element producer's buffer bounds. Fixed, not
/// configurable: it is a smoothing window, and the real limit is the credit
/// window (the consumer stops granting when it lags, so the server parks). The
/// high watermark is the initial credit window so the buffer can hold a full
/// unprompted burst without the producer parking mid-window.
enum StreamBackpressure {
    static let lowWatermark = 1
    static let highWatermark = Int(StreamCredit.initialWindow)
}

/// The placeholder element type for a stream direction that does not exist — a
/// server-streaming call has no request element, a client-streaming call has no
/// response element. It never appears on the wire (the state gates every
/// send/deliver on `hasRequestStream`/`hasResponseStream`), so its `Codable`
/// conformance is a formality that keeps `ClientStreamState`'s two element
/// generics uniformly `Codable & Sendable`.
public struct NoStreamElement: Codable, Sendable {
    public init() {}
}

/// The result of one ``OutboundStreamHandle/send(_:)`` on a client request
/// stream. All four cases are graceful — none is an error: they encode the four
/// ways a send can wind down.
///
/// - ``sent``: the element was accepted for delivery (stamped, credit consumed;
///   the `send` may have suspended first at zero credit). Keep sending.
/// - ``peerStopped``: the server sent STOP for this direction (kind 5, code 0):
///   "I have all the request items I need, stop sending — the call continues to
///   its terminal." Advisory and graceful; the element just passed was **not**
///   sent. Every subsequent `send` also returns `.peerStopped`. Wrap up and
///   await the terminal.
/// - ``callEnded``: the call is over from underneath the sender — the terminal
///   already arrived, or ``OutboundStreamHandle/finish()`` was already called
///   (a send after END). The element was **not** sent; nothing more will be.
/// - ``connectionClosed``: the connection died while the element was being sent
///   (or before it could be). The element was **not** sent.
///
/// This is a client-side control value, never encoded on the wire.
public enum StreamSendOutcome: Sendable, Hashable {
    case sent
    case peerStopped
    case callEnded
    case connectionClosed
}

/// The type-erased control surface of one live client stream, held by the
/// ``CallTable`` so the inbound loop can route wire frames (items, credits,
/// STOP, terminal, cancel, death) without knowing the stream's `Element` types.
///
/// The table decides *whether* a frame is legal (direction declared, seq
/// strictly increasing) under the connection's lock, then calls exactly one of
/// these methods **outside** the lock to apply the effect — yield an element,
/// resume a parked sender, resolve the terminal. None of these methods suspends
/// on the lock the table holds. Every continuation the concrete conformer holds
/// resumes exactly once (audited in ``ClientStreamState``).
protocol ClientStreamControl: AnyObject, Sendable {
    /// Whether this stream declares an inbound (response) direction. Fixed at
    /// open. An inbound item on a stream with no response direction is a
    /// server protocol violation (connection-fatal), decided by the table.
    var hasResponseStream: Bool { get }
    /// Whether this stream declares an outbound (request) direction. Fixed at
    /// open.
    var hasRequestStream: Bool { get }

    /// Validates one inbound item's seq strictly (u32 from 0) against this
    /// stream's declared response direction, advancing the expected seq on a
    /// legal item. A stream with no response direction, or a seq gap, is a
    /// **server protocol violation** — the connection fails (kind matches the
    /// established undecodable-envelope discipline). Late items after the stream
    /// ended drop-and-count.
    func validateInboundItem(seq: UInt32) -> InboundItemValidation

    /// Deliver one inbound response item (already seq-validated). Returns
    /// `.stopProducing` when the producer buffer hit its high watermark, so the
    /// inbound loop parks before reading further frames (backpressure to the
    /// socket). A decode failure drops the element with a warning and a counter
    /// — never a violation (element decoding is per-consumer, like a unary
    /// result).
    func deliverInboundItem(_ item: ByteBuffer) -> InboundDeliveryOutcome

    /// The inbound producer parked at its high watermark: suspend the caller
    /// (the inbound loop) until the consumer drains. Returns immediately if
    /// demand is already available or the stream terminated.
    func awaitInboundDemand() async

    /// The server ended its response direction gracefully (kind 4 END). Finish
    /// the inbound element sequence after buffered items drain. No-op when there
    /// is no response direction or the stream already ended.
    func serverEndInbound()

    /// A credit grant (kind 2) for the outbound (request) direction: add
    /// `credits` and resume a sender parked at zero credit. No-op with no
    /// request direction.
    func grantOutbound(_ credits: UInt32)

    /// The server STOP (kind 5) for the outbound direction: subsequent
    /// ``OutboundStreamHandle/send(_:)`` calls report `.peerStopped`. Also
    /// releases any parked sender so it observes the stop. No-op with no request
    /// direction.
    func serverStopOutbound()

    /// The call's terminal (kind 0) arrived. Resolve the terminal with the raw
    /// slots, finish the inbound sequence (buffered items drain first), and
    /// release any parked sender as `.callEnded`. Idempotent — the first
    /// resolution wins.
    func resolveTerminal(_ slots: ResponseSlots)

    /// Connection death / teardown: resolve the terminal with `reason`, finish
    /// the inbound sequence, and release any parked sender as
    /// `.connectionClosed`. Idempotent.
    func failTerminal(_ reason: MMCallError)

    /// Local CANCEL / cancelled-consuming-task: resolve every surface as
    /// `.cancelled` and finish the sequence. The connection separately sends a
    /// kind-6 CANCEL frame and drops the server's code-7 terminal. Idempotent.
    func cancelLocally()
}

/// The verdict of seq/direction validation for one inbound item.
enum InboundItemValidation {
    /// Legal item — proceed to `deliverInboundItem`.
    case deliver
    /// A tolerated late item (arrived after the inbound sequence ended): drop
    /// and count, never a violation.
    case drop
    /// A server protocol violation (item on an undeclared response direction, or
    /// a seq gap): fail the connection.
    case violation
}

/// The outcome of an inbound item delivery, mirroring the producer's yield
/// result but naming only the cases the inbound loop acts on.
enum InboundDeliveryOutcome {
    /// The element was buffered; keep reading frames.
    case produceMore
    /// The buffer hit the high watermark; the loop must
    /// ``ClientStreamControl/awaitInboundDemand()`` before reading further.
    case stopProducing
    /// The element was dropped (consumer gone, or decode failure). Keep reading.
    case dropped
}

/// A credit grant the inbound consumer wants written to the wire (kind 2), and
/// the terminal outcome, are surfaced to the connection through these closures
/// so ``ClientStreamState`` never imports the actor or the writer directly.
struct ClientStreamSinks: Sendable {
    /// Writes a credit-grant frame (kind 2) for this msgid. Called from the
    /// consumer's `next()` as it drains, watermark-batched. Best-effort: a
    /// write failure means the connection is dying and the terminal will
    /// resolve it — the grant is dropped silently.
    var grantCredit: @Sendable (_ credits: UInt32) async -> Void
    /// Writes one outbound request item (kind 3) with the stamped seq. Returns
    /// whether the write reached the transport (false on connection death).
    var sendItem: @Sendable (_ seq: UInt32, _ item: ByteBuffer) async -> Bool
    /// Writes the outbound END (kind 4) exactly once.
    var sendEnd: @Sendable () async -> Void
    /// Writes a STOP (kind 5, code 0) for the inbound direction (client asks the
    /// server to finish its response stream).
    var sendStop: @Sendable () async -> Void
    /// Writes a CANCEL (kind 6) for the whole call.
    var sendCancel: @Sendable () async -> Void
}

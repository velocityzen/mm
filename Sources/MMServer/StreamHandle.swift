import Logging
import MMSchema
import MMWire
import NIOConcurrencyHelpers
import NIOCore

/// The wire-facing seams the connection hands a stream handler at open: how to
/// write one response item, one lifecycle frame (credit/STOP), the whole
/// terminal, and how to fail the call. All route through the connection's
/// single ``ConnectionWriter`` funnel, so stream frames never interleave.
///
/// Bundled so ``Route``'s erased stream handler stays a single closure. The
/// closures capture the msgid and the writer; `sendTerminal`/`fail` also carry
/// the retire-and-suppress bookkeeping in the connection.
struct StreamWireSeams: Sendable {
    /// Writes one response item frame `[3, msgid, seq, item]`. Returns whether
    /// it landed on the wire (false ⇒ connection gone).
    let sendItem: @Sendable (_ seq: UInt32, _ item: ByteBuffer) async -> Bool
    /// Writes one lifecycle frame for this stream (a credit grant or a STOP).
    /// Returns whether it landed.
    let sendFrame: @Sendable (MMEnvelope) async -> Bool
}

/// The result of constructing one stream at open: the ``StreamControl`` the
/// connection registers in its ``StreamTable``, and the `run` body it launches
/// as a child of the connection's task group. `run` returns the terminal the
/// runtime must send (nil-error graceful, or the handler's `MMError`); the
/// connection wraps that into the `[0, msgid, error, result]` frame, retiring
/// the msgid.
struct StreamStartup: Sendable {
    let control: any StreamControl
    /// Runs the handler body and any owned pumps (the request-stream grant
    /// pump), then returns the terminal outcome. Structured: everything it
    /// spawns is a child of the connection's task group via the caller.
    let run: @Sendable () async -> StreamTerminal
}

/// The terminal a stream handler produced: either a graceful response value
/// (already encoded) or a wire `MMError`. The connection turns it into the
/// terminal envelope.
enum StreamTerminal: Sendable {
    case success(ByteBuffer)
    case failure(MMError)
}

/// The erased stream handler stored on a ``Route``: given the raw params slice,
/// the connection context, the wire seams, and the metrics, it builds the typed
/// source/sink, and returns a ``StreamStartup``. Returning `nil` means the
/// params failed to decode as `Request` — the connection answers with a
/// malformed-params terminal (no stream is registered).
typealias ErasedStreamHandler =
    @Sendable (
        _ params: ByteBuffer,
        _ context: MMContext,
        _ msgid: UInt32,
        _ seams: StreamWireSeams,
        _ metrics: MMStreamMetrics
    ) -> StreamStartup?

/// One concrete stream's control surface: wraps the optional request-stream
/// source and optional response sink and the handler task's cancellation.
///
/// The connection's ``StreamTable`` routes wire frames to these methods after
/// deciding legality under its lock (see ``StreamControl``). Effects run outside
/// that lock.
final class ConcreteStreamControl<
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable
>: StreamControl {
    let hasRequestStream: Bool
    let hasResponseStream: Bool
    private let requestSource: MMRequestStreamSource<RequestElement>?
    private let responseSink: MMResponseSinkState?
    /// The handler-task cancel state. The connection registers the entry in the
    /// ``StreamTable`` *before* the child task installs the hook (via
    /// ``attachCancel(_:)``), so a CANCEL / violation / drain can route to this
    /// control while `hook` is still nil. To avoid losing that cancel, a nil-hook
    /// ``cancelHandler()`` latches `pending = true`; ``attachCancel(_:)`` fires
    /// the newly-installed hook immediately if a cancel was already latched.
    private struct CancelState {
        var hook: (@Sendable () -> Void)?
        var pending = false
    }
    private let cancelBox = NIOLockedValueBox(CancelState())

    init(
        requestSource: MMRequestStreamSource<RequestElement>?,
        responseSink: MMResponseSinkState?
    ) {
        self.hasRequestStream = requestSource != nil
        self.hasResponseStream = responseSink != nil
        self.requestSource = requestSource
        self.responseSink = responseSink
    }

    /// Installs the handler-task cancel hook. Called once by the child task
    /// after it is added. A CANCEL that raced ahead (entry registered before the
    /// hook was installed) latched `pending`; if so, fire the hook immediately so
    /// the cancellation is not lost.
    func attachCancel(_ cancel: @escaping @Sendable () -> Void) {
        let fireNow = self.cancelBox.withLockedValue { state -> Bool in
            state.hook = cancel
            return state.pending
        }
        if fireNow { cancel() }
    }

    func requestHasCredit() -> Bool {
        self.requestSource?.hasCreditForItem() ?? false
    }

    func requestSourceTerminated() -> Bool {
        // No request source ⇒ nothing to feed ⇒ effectively terminated. (The
        // table already rejects items on an undeclared request direction before
        // reaching here, so this branch is defensive.)
        self.requestSource?.isTerminated() ?? true
    }

    func deliver(_ item: ByteBuffer) -> Result<Void, MMWireError> {
        guard let requestSource else { return .success(()) }
        return requestSource.deliver(item)
    }

    func clientEndRequest() {
        self.requestSource?.finishFromEnd()
    }

    func grantResponse(_ credits: UInt32) {
        self.responseSink?.grant(credits)
    }

    func clientStopResponse() {
        self.responseSink?.peerStop()
    }

    func endStreams() {
        self.requestSource?.finishFromTerminal()
        self.responseSink?.end()
    }

    func cancelHandler() {
        // If the hook is not installed yet (a CANCEL raced the child task's
        // attachCancel), latch it so attachCancel fires it on arrival — the
        // cancellation is never silently dropped.
        let cancel = self.cancelBox.withLockedValue { state -> (@Sendable () -> Void)? in
            guard let hook = state.hook else {
                state.pending = true
                return nil
            }
            return hook
        }
        cancel?()
    }
}

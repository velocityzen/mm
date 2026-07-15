import MMWire

/// The result of one ``MMResponseSink/send(_:)`` on a server response stream.
///
/// A handler pushing response elements learns from this value whether to keep
/// going. All three cases are *graceful* — none is an error: they encode the
/// three ways the send loop can wind down.
///
/// - ``sent``: the element was accepted for delivery (buffered toward the
///   client under the credit window; the call `send` may have suspended first
///   at zero credit). Keep sending.
/// - ``peerStopped``: the client sent STOP for this direction (kind 5, code 0)
///   — "I have seen enough response items, finish up". Advisory: the element
///   just passed was **not** delivered (once STOP is observed the sink drops
///   the element and reports `.peerStopped`), and the handler should wrap up and
///   return its terminal. In-flight items sent *before* the STOP are still
///   delivered; only the element concurrent with the stopping send is dropped.
///   Every subsequent `send` also returns `.peerStopped`.
/// - ``callEnded``: the call is over from underneath the handler — the client
///   CANCELled (kind 6), the connection died, or the runtime already sent the
///   terminal. The element was **not** delivered; nothing more will be. The
///   handler should return promptly (its return value is discarded once the
///   terminal is already out).
///
/// This is a server-side control value, never encoded on the wire.
public enum StreamSendOutcome: Sendable, Hashable {
    case sent
    case peerStopped
    case callEnded
}

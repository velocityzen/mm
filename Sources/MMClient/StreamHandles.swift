import MMWire
import NIOCore

/// The client's handle to the inbound (server → client) direction of a
/// streaming call: a single-iteration `AsyncSequence` of response `Element`s,
/// plus graceful ``stop()`` / abnormal ``cancel()`` control and an awaitable
/// ``result()`` terminal.
///
/// For a **server-streaming** call (`ServerStreamMethod`) this is the whole
/// handle, with `OutboundElement == Never`. A **bidirectional** call vends the
/// same type as ``BidirectionalStreamHandle/inbound``, generalized over the
/// request direction's element type — one implementation, both shapes.
///
/// ## Consumption drives credit
///
/// Iterating the sequence is what grants credit back to the server: the initial
/// window (8) arrives unprompted, and each further window the consumer drains
/// emits a credit grant (watermark-batched). A consumer that stops draining
/// stops granting — the server parks at zero credit and memory stays bounded by
/// the window. **Iterate from a task that does not also await other traffic on
/// this connection** (the same head-of-line caveat as any backpressured stream).
///
/// ## Termination (client view of the matrix)
///
/// - Server END + nil-error terminal → the sequence finishes, ``result()`` is
///   `.success(Response)`.
/// - Terminal with error → the sequence finishes, ``result()`` is
///   `.failure(mapped)` (code 7 → `.cancelled`, code 6 → `.streamViolation`,
///   others per `MMCallError.from(error:)`).
/// - ``stop()`` sends STOP (graceful, advisory); the call still runs to its
///   terminal, items in flight still arrive.
/// - ``cancel()`` (or cancelling the consuming task) sends CANCEL; every surface
///   resolves `.cancelled` locally and the server's code-7 terminal is dropped.
/// - Connection death → the sequence finishes and ``result()`` resolves
///   `.transport` / `.connectionClosed`, exactly like a unary call.
///
/// Single iterator (the underlying producer permits one). ``result()`` may be
/// awaited after the sequence ends or concurrently, any number of times; it
/// resolves exactly once.
public struct InboundStreamHandle<
    Element: Codable & Sendable,
    OutboundElement: Codable & Sendable,
    Response: Codable & Sendable
>: AsyncSequence, Sendable {
    typealias State = ClientStreamState<Element, OutboundElement, Response>
    let state: State

    public struct AsyncIterator: AsyncIteratorProtocol {
        let state: State
        var base: State.Producer.AsyncIterator

        /// The next response element, or `nil` once the server ended the stream
        /// (END or terminal) and the buffer is drained, or once the consuming
        /// task is cancelled. Non-throwing: elements that failed to decode were
        /// dropped on the producing side (warn + counter). Draining an element
        /// may emit a credit grant to the server.
        ///
        /// Cancelling the consuming task ends the element sequence (the producer
        /// observes it and stops granting credit). To abandon the **whole call**
        /// — send CANCEL (kind 6) and resolve every surface `.cancelled` — call
        /// ``InboundStreamHandle/cancel()`` explicitly, e.g. in the consuming
        /// task's own cancellation handler; a bare task cancellation is a local
        /// stop of *reading*, per the same discipline as a unary call (no wire
        /// frame is sent from a synchronous cancellation path).
        public mutating func next() async -> Element? {
            let element = await self.base.next()
            if element != nil, let credits = self.state.creditToGrantAfterConsume() {
                await self.state.grantConsumed(credits)
            }
            return element
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(state: self.state, base: self.state.makeInboundIterator())
    }

    /// The call's terminal `Result<Response, MMCallError>`. Awaitable after the
    /// sequence ends or concurrently with iteration; resolves exactly once
    /// (shared with the outbound half, when the call has one).
    public func result() async -> Result<Response, MMCallError> {
        await self.state.result()
    }

    /// Sends STOP (kind 5, graceful): asks the server to finish its response
    /// stream. Advisory — items already in flight still arrive and the call
    /// still runs to its terminal. Idempotent.
    public func stop() async {
        await self.state.stop()
    }

    /// Sends CANCEL (kind 6): abandons the whole call. Every surface resolves
    /// `.cancelled` locally; the server may still have executed. Idempotent.
    public func cancel() async {
        await self.state.cancel()
    }

    /// Test-only: whether the inbound loop is currently parked on this stream's
    /// consumer demand (the backpressure park). Lets a test pin the park
    /// deterministically rather than racing the loop.
    var _isInboundParked: Bool { self.state.isInboundParked }
}

/// The client's handle to the outbound (client → server) direction of a
/// streaming call: credit-gated ``send(_:)`` of request `Element`s, a one-shot
/// ``finish()`` (END), and an awaitable ``result()`` terminal.
///
/// For a **client-streaming** call (`ClientStreamMethod`) this is the whole
/// handle, with `InboundElement == Never`. A **bidirectional** call vends the
/// same type as ``BidirectionalStreamHandle/outbound``, generalized over the
/// response direction's element type — one implementation, both shapes.
///
/// ## Flow control
///
/// The initial window (8) may be sent before any grant; past that, ``send(_:)``
/// suspends at zero credit until the server grants more (kind 2). ``send(_:)``
/// reports the graceful outcomes (``StreamSendOutcome``): `.sent`,
/// `.peerStopped` (server STOP), `.callEnded` (terminal arrived, or END already
/// sent), `.connectionClosed`.
///
/// ``finish()`` sends END exactly once; later sends return `.callEnded`. The
/// call still terminates with exactly one terminal, awaited via ``result()``.
public struct OutboundStreamHandle<
    Element: Codable & Sendable,
    InboundElement: Codable & Sendable,
    Response: Codable & Sendable
>: Sendable {
    typealias State = ClientStreamState<InboundElement, Element, Response>
    let state: State

    /// Sends one request element, credit-gated (suspends at zero credit until a
    /// grant). See ``StreamSendOutcome`` for the four graceful outcomes.
    public func send(_ element: Element) async -> StreamSendOutcome {
        await self.state.send(element)
    }

    /// Sends END (kind 4): finishes the client's request direction gracefully.
    /// Exactly once — later ``send(_:)`` calls return `.callEnded` and a second
    /// `finish()` is a no-op. The call continues to its terminal.
    public func finish() async {
        await self.state.finish()
    }

    /// The call's terminal `Result<Response, MMCallError>`. Resolves exactly
    /// once (shared with the inbound half, when the call has one).
    public func result() async -> Result<Response, MMCallError> {
        await self.state.result()
    }

    /// Sends CANCEL (kind 6): abandons the whole call. Idempotent.
    public func cancel() async {
        await self.state.cancel()
    }

    /// Test-only: whether a `send(_:)` is currently parked at zero credit. Lets
    /// a test pin the credit-gate park deterministically rather than racing it.
    var _isSenderParked: Bool { self.state.isSenderParked }
}

/// The client's handle to a **bidirectional** call (`BidirectionalStreamMethod`): an
/// ``inbound`` response-element sequence and an ``outbound`` request-element
/// writer over one call, independently usable from different tasks. Pure
/// composition — each half *is* the standalone handle for its direction,
/// generalized over the other direction's element type, both wrapping the one
/// shared stream state. The two halves share the one terminal (`result()` on
/// either resolves to the same value).
///
/// Typical shape: one task drains ``inbound`` (granting credit as it consumes),
/// another drives ``outbound`` sends and calls
/// ``OutboundStreamHandle/finish()`` when done. Either half's `cancel()`
/// cancels the whole call.
public struct BidirectionalStreamHandle<
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable,
    Response: Codable & Sendable
>: Sendable {
    typealias State = ClientStreamState<ResponseElement, RequestElement, Response>

    /// The inbound (server → client) response-element sequence plus stop/cancel
    /// and the shared terminal.
    public let inbound: InboundStreamHandle<ResponseElement, RequestElement, Response>
    /// The outbound (client → server) request-element writer plus finish/cancel
    /// and the shared terminal.
    public let outbound: OutboundStreamHandle<RequestElement, ResponseElement, Response>

    init(state: State) {
        self.inbound = InboundStreamHandle(state: state)
        self.outbound = OutboundStreamHandle(state: state)
    }
}

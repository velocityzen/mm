import MMWire

/// Connect- and lifecycle-level failures of ``MMClientConnection``.
///
/// One typed error enum for the connection layer, per the house convention;
/// per-call failures use ``MMCallError`` instead. `Equatable` so tests assert
/// exact `Result` values.
public enum MMClientError: Error, Equatable, Sendable {
    /// The server's first frame was not a decodable hello (bad magic,
    /// truncated, or otherwise malformed). The connection is closed.
    case badHello
    /// Version negotiation (min-wins) produced a version this client cannot
    /// speak. v1 is the first protocol version, so this fires exactly when the
    /// server advertises version 0.
    case versionUnsupported(serverVersion: UInt8)
    /// The transport failed: connect refused, socket error, mid-stream frame
    /// error. Coarse by design — infrastructure failures are for logs, not
    /// `switch`.
    case transport(description: String)
    /// The server violated the protocol (a frame that does not decode as an
    /// envelope). The connection is closed.
    case protocolViolation(description: String)
    /// `run()` was called while a previous `run()` on the same connection was
    /// already consuming the inbound stream.
    case alreadyRunning
}

/// Per-call failures of `call(_:on:_:)` and its streaming
/// overloads.
///
/// Protocol error codes 1...5 (`MMErrorCode`) map to the dedicated cases
/// below; code 6 (streamViolation) maps to ``streamViolation(_:)`` preserving
/// the object, code 7 (cancelled) maps to ``cancelled``; any other code — the
/// application range >= 64 or a future protocol code this client predates —
/// arrives as ``remote(_:)`` with the full `MMError` preserved. Never
/// switch exhaustively on wire codes: the mapping goes through `MMErrorCode`,
/// whose `unknown` case is the catch-all.
public enum MMCallError: Error, Equatable, Sendable {
    /// The server denied access (`MMErrorCode.permissionDenied`).
    case denied
    /// The server has no route for the method (`MMErrorCode.unknownMethod`).
    case unknownMethod
    /// The server could not decode the params as the method's request type
    /// (`MMErrorCode.malformedParams`).
    case malformedParams
    /// Either this client's ``MMClientConfiguration/maxInFlightCalls`` cap was
    /// hit (the request was never sent) or the server rejected the request
    /// over its own per-connection cap (`MMErrorCode.tooManyInFlight`).
    case tooManyInFlight
    /// The handler failed server-side in a way that is not the caller's fault
    /// (`MMErrorCode.internalError`).
    case remoteInternal
    /// An `MMError` with a code this client has no dedicated case for —
    /// application errors (>= 64) and unknown future protocol codes. The object
    /// (code, message, raw payload) is preserved verbatim.
    case remote(MMError)
    /// The server ended the call with a stream-contract violation
    /// (`MMErrorCode.streamViolation`, code 6): an item on an undeclared
    /// stream, a seq gap, a credit overrun, or an item that failed to decode.
    /// The object (message, raw payload) is preserved verbatim for diagnostics.
    /// Distinct from ``MMClientError/protocolViolation(description:)`` — that is a *client*
    /// verdict that fails the whole connection; this is a *terminal* the server
    /// sent for one call, and the connection lives on.
    case streamViolation(MMError)
    /// The request/payload failed to encode. Nothing was sent.
    case encode(MMWireError)
    /// The response arrived but its result slot failed to decode as the
    /// method's response type. Only this call fails; the connection lives on.
    case decode(MMWireError)
    /// The transport failed while this call was outstanding.
    case transport(description: String)
    /// The connection closed (locally or by the server) before a response
    /// arrived, or the call was started on an already-closed connection.
    case connectionClosed
    /// The awaiting task was cancelled, or the server acknowledged a client
    /// CANCEL with a code-7 terminal (`MMErrorCode.cancelled`). Local
    /// abandonment: the msgid is retired and late frames are dropped, but **the
    /// request may still have executed server-side** — CANCEL is not a remote
    /// rollback.
    case cancelled
}

extension MMClientError: CustomStringConvertible {
    /// Log-ready one-liner; the associated detail is included verbatim.
    public var description: String {
        switch self {
            case .badHello:
                return "server hello was malformed"
            case .versionUnsupported(let serverVersion):
                return "server protocol version \(serverVersion) is unsupported"
            case .transport(let description):
                return "transport failure: \(description)"
            case .protocolViolation(let description):
                return "protocol violation: \(description)"
            case .alreadyRunning:
                return "run() called while the inbound loop is already running"
        }
    }
}

extension MMCallError: CustomStringConvertible {
    /// Log-ready one-liner; nested `MMError` values render through
    /// ``MMError/description``.
    public var description: String {
        switch self {
            case .denied:
                return "permission denied"
            case .unknownMethod:
                return "unknown method"
            case .malformedParams:
                return "malformed params"
            case .tooManyInFlight:
                return "too many calls in flight"
            case .remoteInternal:
                return "internal server error"
            case .remote(let error):
                return "remote error (\(error))"
            case .streamViolation(let error):
                return "stream violation (\(error))"
            case .encode(let error):
                return "request encode failed: \(error)"
            case .decode(let error):
                return "response decode failed: \(error)"
            case .transport(let description):
                return "transport failure: \(description)"
            case .connectionClosed:
                return "connection closed"
            case .cancelled:
                return "cancelled"
        }
    }
}

extension MMCallError {
    /// Maps a wire `MMError` to the typed call error. Total over
    /// `MMErrorCode`, whose `unknown` case is the open-world catch-all — this
    /// is the sanctioned way to branch on wire codes without an exhaustive
    /// switch over raw integers.
    static func from(error: MMError) -> MMCallError {
        switch MMErrorCode(code: error.code) {
            case .unknownMethod: return .unknownMethod
            case .permissionDenied: return .denied
            case .malformedParams: return .malformedParams
            case .tooManyInFlight: return .tooManyInFlight
            case .internalError: return .remoteInternal
            case .streamViolation:
                // Code 6: a stream-contract violation the server turned into this
                // call's terminal. Surface it typed, preserving the object; the
                // connection is unaffected (unlike a *client*-side protocol
                // violation, which fails the whole connection).
                return .streamViolation(error)
            case .cancelled:
                // Code 7: the server acknowledged a client CANCEL. Locally this is
                // the same outcome as a task-cancelled call — the msgid is retired
                // and the request may still have executed server-side.
                return .cancelled
            case .unknown: return .remote(error)
        }
    }
}

/// The connection's lifecycle state. Exactly one transition ever happens:
/// `connected` → `closed`. Reconnection is out of scope for v1 — a closed
/// connection stays closed and retry policy belongs to the application.
public enum ClientState: Sendable, Equatable {
    /// The hello exchange completed and the connection is usable.
    case connected
    /// The connection is gone. `reason` is `nil` for a clean close (EOF or a
    /// local `close()`/cancellation) and carries the lifecycle error
    /// otherwise.
    case closed(reason: MMClientError?)
}

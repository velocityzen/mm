#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#endif
import MMWire
import NIOCore
import NIOPosix

/// Whether connecting again can help after a connection ended or failed to
/// open.
///
/// The library computes the hint once, for every close, and never acts on
/// it: there is no automatic reconnect. It reaches the application through
/// ``MMClientError/retryHint`` (a failed connect, or a connection that died
/// with an error) and through ``ClientState/closed(reason:retry:)`` (every
/// close, clean ones included), so a retry policy needs no string matching.
public enum MMRetryHint: Sendable, Hashable {
    /// Connect again at once. The peer went away from an established
    /// connection: it exited, drained, crashed, or this client's idle
    /// timeout reaped the connection. A socket-activated daemon starts again
    /// on the next connect.
    case now
    /// Connect again after a pause, backing off while it keeps failing.
    /// Nothing listens yet, the socket is not there yet, or the server
    /// closed before its hello: a daemon starting, restarting or draining.
    case later
    /// Do not connect again until something changes. The same attempt fails
    /// the same way (permission denied, a bad hello, an unsupported version,
    /// a protocol violation, an address that can never work), or the
    /// application closed the connection itself.
    case never
}

/// What failed in the transport, beside the log string of
/// ``MMClientError/transport(cause:description:)``.
///
/// The cause is classified from the typed error NIO reports (its `errno`
/// where it has one), never parsed from text. Each cause has one
/// ``retryHint``.
public enum MMTransportCause: Sendable, Hashable {
    /// The connect was refused (`ECONNREFUSED`): a socket file or address
    /// exists, but nothing listens on it. The daemon is down, starting, or
    /// draining.
    case refused
    /// The socket path does not exist (`ENOENT`, or `ENOTDIR` for a missing
    /// directory on the way): a wrong path, a tunnel not up, or a runtime
    /// directory already removed.
    case socketMissing
    /// The connect was denied (`EACCES`, `EPERM`): the socket's mode or its
    /// directory's does not admit this user.
    case permissionDenied
    /// The address can never be connected to: a Unix socket path longer than
    /// the platform allows, or an address the platform does not support.
    case invalidAddress
    /// The connect timed out (`ETIMEDOUT`, or the connect timeout).
    case timedOut
    /// The connection was accepted, but closed or failed before the server's
    /// hello arrived, including the configured hello timeout.
    case closedBeforeHello
    /// The established connection failed: a reset, a broken pipe, or a
    /// frame cut off by the close.
    case lost
    /// The server sent a frame longer than this client's
    /// ``MMClientConfiguration/maxFrameLength``. It sends the same frame
    /// again unless one of the two changes.
    case oversizedFrame
    /// Any other failure, with its `errno` when the error carried one.
    case other(errorNumber: Int32?)

    /// Whether connecting again can help after this failure.
    public var retryHint: MMRetryHint {
        switch self {
            case .lost:
                return .now
            case .refused, .socketMissing, .timedOut, .closedBeforeHello, .other:
                return .later
            case .permissionDenied, .invalidAddress, .oversizedFrame:
                return .never
        }
    }
}

extension MMClientError {
    /// Whether connecting again can help after this failure: the transport
    /// cause's hint, and ``MMRetryHint/never`` for a bad hello, an
    /// unsupported version and a protocol violation, which a new connection
    /// to the same server meets again.
    public var retryHint: MMRetryHint {
        switch self {
            case .transport(let cause, _):
                return cause.retryHint
            case .badHello, .versionUnsupported, .protocolViolation:
                return .never
        }
    }
}

extension MMTransportCause {
    /// Classifies a failed connect from the error the bootstrap threw.
    ///
    /// A TCP connect tries each resolved address and reports every failure
    /// in one `NIOConnectionError`; the first failure that classifies as
    /// something other than ``other(errorNumber:)`` names the cause.
    static func connectFailure(_ error: any Error) -> MMTransportCause {
        switch error {
            case let error as IOError:
                return Self.connectFailure(errorNumber: error.errnoCode)
            case let error as NIOConnectionError:
                return Self.firstKnown(error.connectionErrors.map(\.error))
            case let error as SocketAddressError:
                switch error {
                    case .unixDomainSocketPathTooLong, .unsupported, .failedToParseIPString:
                        return .invalidAddress
                    default:
                        // An unknown host: a lookup that may succeed later.
                        return .other(errorNumber: nil)
                }
            case let error as ChannelError:
                guard case .connectTimeout = error else { return .other(errorNumber: nil) }
                return .timedOut
            default:
                return .other(errorNumber: nil)
        }
    }

    /// Classifies a connect that failed with `errorNumber`.
    static func connectFailure(errorNumber: Int32) -> MMTransportCause {
        switch errorNumber {
            case ECONNREFUSED:
                return .refused
            case ENOENT, ENOTDIR:
                return .socketMissing
            case EACCES, EPERM:
                return .permissionDenied
            case ETIMEDOUT:
                return .timedOut
            default:
                return .other(errorNumber: errorNumber)
        }
    }

    /// The cause of the first of `errors` that classifies as something other
    /// than ``other(errorNumber:)``; else the first one's, else
    /// `other(errorNumber: nil)` when there are none (a failed lookup).
    static func firstKnown(_ errors: [any Error]) -> MMTransportCause {
        let causes = errors.map(Self.connectFailure)
        let known = causes.first { cause in
            if case .other = cause { return false }
            return true
        }
        return known ?? causes.first ?? .other(errorNumber: nil)
    }

    /// Classifies an error that ended an established connection's inbound
    /// loop: an oversized frame, or the connection lost.
    static func connectionFailure(_ error: any Error) -> MMTransportCause {
        if case .frameTooLarge = error as? MMWireError {
            return .oversizedFrame
        }
        return .lost
    }
}

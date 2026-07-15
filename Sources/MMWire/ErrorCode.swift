/// Well-known protocol-level RPC error codes carried in `MMErrorObject.code`.
///
/// Code table (streaming amendment): 1 unknownMethod, 2 permissionDenied,
/// 3 malformedParams, 4 tooManyInFlight, 5 internalError, 6 streamViolation,
/// 7 cancelled.
///
/// This is a wire-decoded enum: construction never fails — codes outside the
/// known set map to `.unknown(code:)`, per the wire-evolution contract. Codes
/// 1...63 are reserved for the protocol; applications should use codes >= 64.
public enum MMErrorCode: Sendable, Hashable {
    /// The request named a method the router has no route for.
    case unknownMethod
    /// The peer's identity does not grant the access class the method requires
    /// on the target entity (or on one of its ancestors, for traversal).
    case permissionDenied
    /// The params payload failed to decode as the method's request type.
    case malformedParams
    /// The connection exceeded its in-flight request cap.
    case tooManyInFlight
    /// The handler failed in a way that is not the caller's fault.
    case internalError
    /// The peer broke the stream contract: an item on an undeclared stream, an
    /// item after its own END, a seq gap, or a credit overrun.
    case streamViolation
    /// Terminal acknowledging a client CANCEL: the call was aborted.
    case cancelled
    /// A code outside the well-known set. Never switch exhaustively without this.
    case unknown(code: Int)

    public init(code: Int) {
        switch code {
            case 1: self = .unknownMethod
            case 2: self = .permissionDenied
            case 3: self = .malformedParams
            case 4: self = .tooManyInFlight
            case 5: self = .internalError
            case 6: self = .streamViolation
            case 7: self = .cancelled
            default: self = .unknown(code: code)
        }
    }

    public var code: Int {
        switch self {
            case .unknownMethod: return 1
            case .permissionDenied: return 2
            case .malformedParams: return 3
            case .tooManyInFlight: return 4
            case .internalError: return 5
            case .streamViolation: return 6
            case .cancelled: return 7
            case .unknown(let code): return code
        }
    }
}

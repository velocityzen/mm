import MMSchema
import MMWire
import NIOCore

/// The refusal of a value that breaks a constraint its contract declares,
/// when `check` runs before sending: in debug builds of the module that
/// declares the call (see ``MMConstraintCheck/beforeSending``). Nil when the
/// check does not run there, or finds nothing.
@inlinable
func refusalBeforeSending<Value>(
    _ check: MMConstraintCheck<Value>?,
    _ value: Value
) -> MMCallError? {
    guard let check, check.beforeSending, let violation = check.violation(of: value) else {
        return nil
    }
    return .invalidRequest(path: violation.path, problem: violation.problem)
}

/// A request's params, or its refusal: refused before sending when it breaks
/// a declared constraint and `check` runs here, else encoded through the
/// generated code when its type has some.
@inlinable
func encodedRequest<Request: Codable & Sendable>(
    _ request: Request,
    checking check: MMConstraintCheck<Request>?
) -> Result<ByteBuffer, MMCallError> {
    if let refusal = refusalBeforeSending(check, request) {
        return .failure(refusal)
    }
    return MMPackEncoder().encodeCheckingForGeneratedCode(request).mapError(MMCallError.encode)
}

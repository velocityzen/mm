import MMSchema
import MMWire
import NIOCore

/// Why ingress refused a request's params or one request-stream item.
enum IngressRejection: Error, Sendable, Hashable {
    /// The bytes did not decode as the declared type.
    case undecodable(MMWireError)
    /// The value decoded and broke a constraint its contract declares.
    case constraintViolation(SchemaValueError)

    /// The path and rule the peer's error names: a violation's own, or the
    /// first place an undecodable `payload` breaks `schema`. Nil when there
    /// is none to name: no schema, or a walk that finds nothing wrong.
    func failure(
        of payload: ByteBuffer,
        against schema: TypeSchema?,
        resolver: TypeResolver
    ) -> SchemaValueError? {
        switch self {
            case .constraintViolation(let violation):
                violation
            case .undecodable:
                schema.flatMap {
                    MMPackDecoder().firstProblem(in: payload, against: $0, resolver: resolver)
                }
        }
    }
}

/// `decode` and then `check`: a value that decodes and breaks a declared
/// constraint is refused at ingress like one that does not decode, before
/// any handler sees it. Without a check, only the decode runs.
func checkedDecoding<Value>(
    _ decode: @escaping @Sendable (ByteBuffer) -> Result<Value, MMWireError>,
    _ check: MMConstraintCheck<Value>?
) -> @Sendable (ByteBuffer) -> Result<Value, IngressRejection> {
    guard let check else {
        return { payload in decode(payload).mapError(IngressRejection.undecodable) }
    }
    return { payload in
        decode(payload).mapError(IngressRejection.undecodable).flatMap { value in
            if let violation = check.violation(of: value) {
                return .failure(.constraintViolation(violation))
            }
            return .success(value)
        }
    }
}

extension Router {
    /// The code-3 error for params refused at ingress: with the failing path
    /// and rule when ingress can name them (`malformed params: limit: is 0,
    /// less than the minimum 1`), else the constant message.
    static func malformedParams(_ failure: SchemaValueError?) -> MMError {
        guard let failure else { return Self.error(.malformedParams) }
        return MMError(
            code: MMErrorCode.malformedParams.code,
            message: "malformed params: \(failure)"
        )
    }

    /// The code-6 terminal for request item `seq` refused at ingress: with
    /// the item's path and rule when ingress can name them (`stream
    /// violation: [3].text: has length 0, less than the minimum length 1`),
    /// else the constant message.
    static func refusedItem(seq: UInt32, _ failure: SchemaValueError?) -> MMError {
        guard let failure else { return Self.error(.streamViolation) }
        let path = MMConstraintPath.item(seq, path: failure.path)
        return MMError(
            code: MMErrorCode.streamViolation.code,
            message: "stream violation: \(SchemaValueError(path: path, problem: failure.problem))"
        )
    }
}

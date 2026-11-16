import MMSchema
import NIOCore

extension MMError {
    /// The application code every declared error travels under: the first
    /// one past the protocol's reserved 1–63. The payload, not the code,
    /// tells the declared errors apart.
    public static let declaredErrorCode = 64

    /// A declared error as the wire error: code 64, the case name as the
    /// message, and the union value `{0: "<case>", 1: <fields>}` as the
    /// payload. Fails only when the error's own coding fails.
    public static func declaring(_ error: some MMDeclaredError) -> Result<MMError, MMWireError> {
        MMPackEncoder().encode(error).map { payload in
            MMError(code: Self.declaredErrorCode, message: error.caseName, payload: payload)
        }
    }

    /// The declared error this wire error carries, when it has code 64 and a
    /// payload that decodes as `Failure`. A case `Failure` does not know
    /// decodes to its `unknown` case; any other code, a missing payload or one
    /// that does not decode gives nil.
    public func declared<Failure: MMDeclaredError>(
        as type: Failure.Type,
        maxDepth: Int = 128
    ) -> Failure? {
        guard self.code == Self.declaredErrorCode, let payload = self.payload else { return nil }
        return try? MMPackDecoder(maxDepth: maxDepth).decode(Failure.self, from: payload).get()
    }
}

/// The errors a contract declares: what a call can fail with, as part of the
/// wire contract.
///
/// ```swift
/// Schema("journal") {
///     Errors {
///         Case("readOnly", exitCode: 10, description: "The journal is archived")
///     }
///     Error("Full", exitCode: 11) { Field("capacity", .int) }
///     Type("Conflict") { Field("existing", .string) }
///     Call("append") {
///         Access { .write }
///         Errors {
///             Case(.reference("Full"))
///             Case("conflict", .reference("Conflict"), exitCode: 12)
///             Case("tooLong", exitCode: 13) { Field("limit", .int) }
///         }
///     }
/// }
/// ```
///
/// - A top-level `Errors { ... }` declares the namespace's errors: every call
///   in the block can return them.
/// - An `Errors { ... }` part inside a `Call` adds the call's own errors. A
///   call's full error set is the namespace's errors followed by its own; a
///   call error may not reuse a namespace error's name.
/// - `Error("Full", exitCode:) { ... }` declares a named error the way
///   `Type` declares a named type, and `Case(.reference("Full"))` lists it
///   in an `Errors` block as the case `full`, with the error's exit code and
///   description. (A bare `.reference("Full")` line would chain onto the line
///   above it — Swift reads a leading dot as a member access.)
/// - `Case("conflict", .reference("Conflict"), exitCode:)` carries a named
///   `Type` (or named error) as the case's payload.
///
/// On the wire every declared error is an `MMError` with code 64 whose
/// payload is the union value `{0: "<case>", 1: <the case's fields>}`, key 1
/// left out for a case without fields — so the case name is the error's
/// identity. Each method's signature serves its flattened set as a union
/// (``MethodSignature/errors``). Exit codes are presentation, like the CLI
/// overlay: the generated CLI exits with them, and they never reach the
/// wire.
public struct ErrorCaseDeclaration: Sendable, Hashable {
    enum Payload: Sendable, Hashable {
        /// A case without fields.
        case none
        /// A case carrying its own fields, keyed from 0.
        case fields([Field])
        /// A case carrying a named `Type` or named error of the same block.
        case type(String)
        /// `Case(.reference("Full"))`: the named error itself, with its
        /// derived case name and its exit code.
        case namedError(String)
    }

    let name: String
    let exitCode: Int
    let description: String?
    let payload: Payload
}

/// The exit codes a declared error may take: clear of 0 (success), 1 (an
/// undeclared remote error), the sysexits range 64–78 and the shell's 126 and
/// up.
public let declaredErrorExitCodes: ClosedRange<Int> = 2...63

/// Lists a named error, declared with `Error("Full", exitCode:)` in the same
/// block: `Case(.reference("Full"))`. The case takes the error's name with
/// its leading capitals lowered (`Full` → `full`, `URLTooLong` →
/// `urlTooLong`), and its exit code and description.
public func Case(_ namedError: TypeSchema) -> ErrorCaseDeclaration {
    guard case .reference(let name) = namedError, !name.contains(".") else {
        preconditionFailure(
            "Case(\(namedError)) — a named error is listed by its name: Case(.reference(\"Name\"))"
        )
    }
    return ErrorCaseDeclaration(
        name: errorCaseName(forNamedError: validTypeName(name)),
        exitCode: 0,
        description: nil,
        payload: .namedError(name)
    )
}

/// Declares an error case without fields: `Case("readOnly", exitCode: 10)`.
public func Case(
    _ name: String,
    exitCode: Int,
    description: String? = nil
) -> ErrorCaseDeclaration {
    ErrorCaseDeclaration(
        name: validErrorCaseName(name),
        exitCode: validExitCode(exitCode, caseName: name),
        description: description,
        payload: .none
    )
}

/// Declares an error case carrying fields:
/// `Case("tooLong", exitCode: 13) { Field("limit", .int) }`.
public func Case(
    _ name: String,
    exitCode: Int,
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> ErrorCaseDeclaration {
    ErrorCaseDeclaration(
        name: validErrorCaseName(name),
        exitCode: validExitCode(exitCode, caseName: name),
        description: description,
        payload: .fields(fields())
    )
}

/// Declares an error case whose payload is a named type of the same block:
/// `Case("conflict", .reference("Conflict"), exitCode: 12)`. The type must
/// be a `Type` or a named `Error`; the case carries its fields.
public func Case(
    _ name: String,
    _ payload: TypeSchema,
    exitCode: Int,
    description: String? = nil
) -> ErrorCaseDeclaration {
    guard case .reference(let typeName) = payload, !typeName.contains(".") else {
        preconditionFailure(
            "error case \"\(name)\" carries \(payload) — an error case carries a Type or Error of its own block: .reference(\"Name\")"
        )
    }
    return ErrorCaseDeclaration(
        name: validErrorCaseName(name),
        exitCode: validExitCode(exitCode, caseName: name),
        description: description,
        payload: .type(typeName)
    )
}

@resultBuilder
public enum ErrorsBuilder: MMListBuilding {
    public typealias Element = ErrorCaseDeclaration

    public static func buildExpression(
        _ errorCase: ErrorCaseDeclaration
    ) -> [ErrorCaseDeclaration] {
        [errorCase]
    }
}

/// An `Errors { ... }` block: the namespace's errors at the top level of a
/// ``Schema(_:description:_:)``, or a call's own errors inside a
/// ``Call(_:description:_:)``.
public struct ErrorsDeclaration: Sendable, Hashable {
    let cases: [ErrorCaseDeclaration]
}

/// Declares errors: the namespace's at the top level of a schema, a call's
/// own inside a `Call`. See ``ErrorCaseDeclaration``.
public func Errors(@ErrorsBuilder _ cases: () -> [ErrorCaseDeclaration]) -> ErrorsDeclaration {
    let caseList = cases()
    precondition(!caseList.isEmpty, "Errors declares no cases")
    return ErrorsDeclaration(cases: caseList)
}

/// A named error, produced by ``Error(_:exitCode:description:_:)``: a named
/// structure that `Errors` blocks list with `Case(.reference("Name"))` and
/// error cases may carry. It stays out of the type table — each method's signature
/// carries its errors' fields inline.
public struct NamedErrorDeclaration: Sendable, Hashable {
    let name: String
    let exitCode: Int
    let description: String?
    let fields: [Field]
}

/// Declares a named error with fields:
/// `Error("Full", exitCode: 11) { Field("capacity", .int) }`. `#schema`
/// generates it as a struct conforming to `Swift.Error`;
/// `Case(.reference("Full"))` lists it in an `Errors` block.
///
/// Importing MMSchema makes a bare `Error.self` ambiguous between this
/// function and Swift's protocol; write `(any Error).self` instead.
public func Error(
    _ name: String,
    exitCode: Int,
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> NamedErrorDeclaration {
    NamedErrorDeclaration(
        name: validTypeName(name),
        exitCode: validExitCode(exitCode, caseName: name),
        description: description,
        fields: fields()
    )
}

/// Declares a named error without fields: `Error("ReadOnly", exitCode: 10)`.
public func Error(
    _ name: String,
    exitCode: Int,
    description: String? = nil
) -> NamedErrorDeclaration {
    Error(name, exitCode: exitCode, description: description) {}
}

/// The case a named error becomes in an `Errors` block: its leading capitals
/// lowered, keeping the last one when it starts the next word —
/// `Full` → `full`, `URLTooLong` → `urlTooLong`, `IO` → `io`. `#schema`
/// derives the same name (the property suite checks the two agree).
package func errorCaseName(forNamedError name: String) -> String {
    let characters = Array(name)
    var capitals = 0
    while capitals < characters.count, characters[capitals].isUppercase {
        capitals += 1
    }
    let lowered =
        capitals > 1 && capitals < characters.count && characters[capitals].isLowercase
        ? capitals - 1 : capitals
    return String(characters[..<lowered]).lowercased() + String(characters[lowered...])
}

private func validErrorCaseName(_ name: String) -> String {
    precondition(!name.isEmpty, "error case names cannot be empty")
    precondition(
        name != "unknown",
        "\"unknown\" is reserved — generated error enums decode unrecognized cases to it"
    )
    return name
}

private func validExitCode(_ exitCode: Int, caseName: String) -> Int {
    precondition(
        declaredErrorExitCodes.contains(exitCode),
        "error \"\(caseName)\": exit code \(exitCode) is outside \(declaredErrorExitCodes)"
    )
    return exitCode
}

/// One declared error resolved against its block: the union case its
/// signature serves and the exit code the CLI uses.
struct ResolvedErrorCase {
    let unionCase: TypeSchema.UnionCase
    let exitCode: Int
}

/// What an `Errors` block's cases resolve against: the block's named errors
/// and structure types, by unqualified name.
struct ErrorResolutionScope {
    let namespace: String
    let namedErrors: [String: NamedErrorDeclaration]
    let structures: [String: [Field]]
    /// Every named type of the block, for the field references inside the
    /// cases.
    let localTypes: Set<String>

    /// Resolves cases in declaration order. `context` names the block in
    /// failure messages.
    func resolve(_ cases: [ErrorCaseDeclaration], context: String) -> [ResolvedErrorCase] {
        let resolved = cases.map { self.resolve($0, context: context) }
        if let duplicate = firstDuplicate(resolved.map(\.unionCase.name)) {
            preconditionFailure("\(context) declares error \"\(duplicate)\" twice")
        }
        return resolved
    }

    private func resolve(_ errorCase: ErrorCaseDeclaration, context: String) -> ResolvedErrorCase {
        switch errorCase.payload {
            case .none:
                return self.resolved(errorCase, fields: [])
            case .fields(let fields):
                return self.resolved(errorCase, fields: fields)
            case .type(let typeName):
                guard let fields = self.namedErrors[typeName]?.fields ?? self.structures[typeName]
                else {
                    preconditionFailure(
                        "\(context): error \"\(errorCase.name)\" carries \"\(typeName)\", which is no Type or Error declared in \"\(self.namespace)\""
                    )
                }
                return self.resolved(errorCase, fields: fields)
            case .namedError(let errorName):
                guard let named = self.namedErrors[errorName] else {
                    preconditionFailure(
                        "\(context): Case(.reference(\"\(errorName)\")) names no Error declared in \"\(self.namespace)\""
                    )
                }
                precondition(
                    errorCase.name != "unknown",
                    "\(context): Error(\"\(errorName)\") becomes the case \"unknown\", which is reserved"
                )
                return ResolvedErrorCase(
                    unionCase: TypeSchema.UnionCase(
                        name: errorCase.name,
                        fields: self.qualified(named.fields),
                        description: named.description
                    ),
                    exitCode: named.exitCode
                )
        }
    }

    private func resolved(_ errorCase: ErrorCaseDeclaration, fields: [Field]) -> ResolvedErrorCase {
        ResolvedErrorCase(
            unionCase: TypeSchema.UnionCase(
                name: errorCase.name,
                fields: self.qualified(fields),
                description: errorCase.description
            ),
            exitCode: errorCase.exitCode
        )
    }

    private func qualified(_ fields: [Field]) -> [TypeSchema.Field] {
        guard
            case .structure(let qualified) = qualifyReferences(
                in: .structure(fields: assignKeys(fields)),
                namespace: self.namespace,
                localTypes: self.localTypes
            )
        else { return [] }
        return qualified
    }
}

/// A call's full error set: the namespace's errors, then its own. A call
/// error that reuses a namespace error's name, or two errors sharing an exit
/// code, are programmer errors. `nil` when the set is empty.
func flattenedErrors(
    namespace namespaceErrors: [ResolvedErrorCase],
    own ownErrors: [ResolvedErrorCase],
    call: String
) -> TypeSchema? {
    let namespaceNames = Set(namespaceErrors.map(\.unionCase.name))
    for own in ownErrors where namespaceNames.contains(own.unionCase.name) {
        preconditionFailure(
            "Call(\"\(call)\"): error \"\(own.unionCase.name)\" is also a namespace error — a call's errors add to the namespace's"
        )
    }
    let all = namespaceErrors + ownErrors
    var owners: [Int: String] = [:]
    for error in all {
        if let owner = owners.updateValue(error.unionCase.name, forKey: error.exitCode) {
            preconditionFailure(
                "Call(\"\(call)\"): errors \"\(owner)\" and \"\(error.unionCase.name)\" share exit code \(error.exitCode)"
            )
        }
    }
    return all.isEmpty ? nil : .union(cases: all.map(\.unionCase))
}

import ArgumentParser
import Foundation
import MMClient
import MMSchema

/// A call's declared error as the generated CLI reports it. `#schema`'s CLI
/// extension conforms each generated error type, with the exit codes the
/// contract pins (`Case("full", exitCode: 40)`).
public protocol MMCLIDeclaredError: MMDeclaredError {
    /// The exit code the contract pins for this value's case, in 2–63; 1 for
    /// a case this build does not know, like any other remote error.
    var exitCode: Int32 { get }
}

/// A call failure a generated command can report: `MMCallError` for a call
/// without declared errors, `MMDeclaredCallError` for one with them. The
/// stream drivers and ``MMCLIFailure/unwrap(_:method:entity:)`` are generic
/// over it.
public protocol MMCLIReportableFailure: MMCallFailure {
    /// The process exit code.
    var exitCode: ExitCode { get }
    /// The one-line stderr diagnosis.
    func message(method: String, entity: String) -> String
}

extension MMCallError: MMCLIReportableFailure {
    /// ``MMCLIFailure/code(for:)``.
    public var exitCode: ExitCode {
        MMCLIFailure.code(for: self)
    }

    /// The line ``MMCLIFailure`` writes for it.
    public func message(method: String, entity: String) -> String {
        MMCLIFailure.message(for: self, method: method, entity: entity)
    }
}

extension MMDeclaredCallError: MMCLIReportableFailure where Declared: MMCLIDeclaredError {
    /// The declared case's pinned exit code, or the protocol failure's.
    public var exitCode: ExitCode {
        switch self {
            case .declared(let declared):
                return ExitCode(declared.exitCode)
            case .undeclared(let error):
                return error.exitCode
        }
    }

    /// For a declared error: the case name, its contract description and
    /// its fields as compact JSON — `full: The journal is at capacity
    /// {"capacity":100}`. For anything else, the protocol failure's line.
    public func message(method: String, entity: String) -> String {
        switch self {
            case .declared(let declared):
                return MMCLIFailure.message(for: declared)
            case .undeclared(let error):
                return error.message(method: method, entity: entity)
        }
    }
}

extension MMCLIFailure {
    /// The one-line stderr diagnosis of a declared error: its case name, the
    /// case's description from the contract, and its fields as compact JSON
    /// with sorted keys. A case without fields, or one this build does not
    /// know, prints its name alone.
    public static func message(for declared: some MMDeclaredError) -> String {
        let caseName = declared.caseName
        var line = caseName
        if case .union(let cases) = type(of: declared).declaredErrors,
            let description = cases.first(where: { $0.name == caseName })?.description
        {
            line += ": \(description)"
        }
        if let fields = Self.fieldsJSON(of: declared) {
            line += " \(fields)"
        }
        return line
    }

    /// The `fields` slot of a declared error's union form, as compact JSON;
    /// nil when the case has none.
    private static func fieldsJSON(of declared: some MMDeclaredError) -> String? {
        guard let union = try? JSONEncoder().encode(declared),
            let object = try? JSONSerialization.jsonObject(with: union) as? [String: Any],
            let fields = object["fields"],
            let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension MMCLIError {
    /// An input command's failed call with declared errors, reported like a
    /// generated command's: a declared error with its pinned exit code, any
    /// other failure as ``call(_:method:entity:)``.
    public static func declaredCall<Declared: MMCLIDeclaredError>(
        _ failure: MMDeclaredCallError<Declared>,
        method: String,
        entity: String
    ) -> MMCLIError {
        switch failure {
            case .declared(let declared):
                return .declared(declared)
            case .undeclared(let error):
                return .call(error, method: method, entity: entity)
        }
    }
}

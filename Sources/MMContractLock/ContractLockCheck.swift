import Foundation
import MMClient
import MMSchema

extension ContractLock {
    /// Checks `contracts` against the lock file at `lockFile`, a path
    /// relative to the directory of the file that calls it (`filePath`), or
    /// an absolute one. See ``check(lockFileAt:)`` for what each outcome
    /// does to the file:
    ///
    /// ```swift
    /// @Test func journalKeepsItsContract() {
    ///     let check = ContractLock.check([journalContract], lockFile: "Locks/journal.json")
    ///     #expect(check.passed, "\(check)")
    /// }
    /// ```
    ///
    /// The lock is read from the source tree, so run the check where tests
    /// see it: on macOS or Linux, not on a device or an emulator. Keep the
    /// lock out of the test target's sources, or exclude it, since the
    /// package manager warns about a file a target does not handle.
    public static func check(
        _ contracts: [SchemaDeclaration],
        sharedTypes: [TypeNamespaceDeclaration] = [],
        lockFile: String,
        relativeTo filePath: StaticString = #filePath
    ) -> ContractLockCheck {
        let directory = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        return ContractLock(contracts, sharedTypes: sharedTypes).check(
            lockFileAt: URL(fileURLWithPath: lockFile, relativeTo: directory).standardizedFileURL
                .path
        )
    }

    /// Checks this contract against the lock file at `path`:
    ///
    /// - No file: the check writes this contract as the lock and fails, so
    ///   a lock that was never committed cannot pass.
    /// - The locked contract: the check passes and leaves the file.
    /// - A compatible change (``difference(to:)``): the check passes and
    ///   writes this contract as the lock, so the next change is judged
    ///   against what peers may now be built with. Commit the lock with the
    ///   change.
    /// - A breaking change: the check fails and leaves the file. To accept
    ///   the break, delete the lock and run the check again.
    /// - A file that is not a lock, or one damaged since it was written:
    ///   the check fails and leaves the file.
    public func check(lockFileAt path: String) -> ContractLockCheck {
        ContractLockCheck(lockFile: path, outcome: self.outcome(lockFileAt: path))
    }

    private func outcome(lockFileAt path: String) -> ContractLockCheck.Outcome {
        let text = self.text
        let found: String?
        switch LockFile.read(path) {
            case .success(let read): found = read
            case .failure(let error): return .failed(error)
        }
        guard let found else { return Self.written(text, to: path, then: .created) }
        guard found != text else { return .unchanged }
        let locked: ContractLock
        switch ContractLock.parse(found) {
            case .success(let parsed): locked = parsed
            case .failure(let error): return .failed(error)
        }
        // The same contract written another way: the lock still holds it.
        if locked == self || locked.text == text { return .unchanged }
        let difference = locked.difference(to: self)
        guard !difference.isBreaking else { return .breaking(difference) }
        return Self.written(text, to: path, then: .compatible(difference))
    }

    /// `outcome` once `text` is written to `path`, or why it was not.
    private static func written(
        _ text: String,
        to path: String,
        then outcome: ContractLockCheck.Outcome
    ) -> ContractLockCheck.Outcome {
        switch LockFile.write(text, to: path) {
            case .success: outcome
            case .failure(let error): .failed(error)
        }
    }
}

/// What checking a contract against its lock found.
public struct ContractLockCheck: Sendable, Hashable, CustomStringConvertible {
    public enum Outcome: Sendable, Hashable {
        /// The contract is the locked one.
        case unchanged
        /// The contract changed compatibly, and the lock now records it.
        case compatible(SchemaDifference)
        /// The contract breaks a peer built against the lock, which the
        /// check left as it was.
        case breaking(SchemaDifference)
        /// There was no lock, and the check wrote one from the contract.
        case created
        /// The lock could not be read or written.
        case failed(ContractLockError)
    }

    /// The lock file's path.
    public let lockFile: String
    public let outcome: Outcome

    public init(lockFile: String, outcome: Outcome) {
        self.lockFile = lockFile
        self.outcome = outcome
    }

    /// Whether the check passes: the contract is the locked one, or a
    /// compatible change of it.
    public var passed: Bool {
        switch self.outcome {
            case .unchanged, .compatible: true
            case .breaking, .created, .failed: false
        }
    }

    /// Why the change breaks, one line each: a method or a type the lock
    /// has and the contract lacks, then each break the judgment found.
    /// Empty unless the outcome is ``Outcome/breaking(_:)``.
    public var breaks: [String] {
        guard case .breaking(let difference) = self.outcome else { return [] }
        return difference.missingMethods.map { "\($0.name): no longer in the contract" }
            + difference.missingTypes.map { "\($0.name): no longer in the contract" }
            + difference.breakingReasons
    }

    public var description: String {
        switch self.outcome {
            case .unchanged:
                return "\(self.lockFile): the contract is the locked one"
            case .compatible(let difference):
                let changed = difference.isEmpty ? "" : " (\(difference))"
                return
                    "\(self.lockFile): the contract changed compatibly\(changed), and the lock now records it; commit the lock with the change"
            case .breaking:
                return
                    (["\(self.lockFile): the contract breaks a peer built against the lock:"]
                    + self.breaks.map { "  \($0)" }
                    + ["To accept the break, delete the lock and run the check again."])
                    .joined(separator: "\n")
            case .created:
                return
                    "\(self.lockFile): there was no lock, so the check wrote one from the contract; commit it and run the check again"
            case .failed(let error):
                return "\(self.lockFile): \(error)"
        }
    }
}

extension LockFile {
    /// The text at `path`, or nil when there is no file.
    static func read(_ path: String) -> Result<String?, ContractLockError> {
        guard FileManager.default.fileExists(atPath: path) else { return .success(nil) }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .failure(.unreadable(path: path, reason: error.localizedDescription))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.malformed("the file is not UTF-8 text"))
        }
        return .success(text)
    }

    /// Writes `text` to `path` in one step, making the directories it
    /// needs.
    static func write(_ text: String, to path: String) -> Result<Void, ContractLockError> {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url, options: .atomic)
            return .success(())
        } catch {
            return .failure(.unwritable(path: path, reason: error.localizedDescription))
        }
    }
}

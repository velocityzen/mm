# ``MMContractLock``

A committed record of a wire contract, and a test helper that fails on a breaking change to it.

## Overview

A contract changes without a version bump, so nothing stops a change that breaks a peer built against the last release: an unpinned field inserted mid-struct renumbers the fields after it, and a renamed call is a removed one. A contract lock records the contract as a JSON file committed with the code, and a test holds the current contract to it with the rule verification uses (``ContractLock/difference(to:)``):

```swift
import MMContractLock
import Testing

@Test func journalKeepsItsContract() {
    let check = ContractLock.check([journalContract], lockFile: "Locks/journal.json")
    #expect(check.passed, "\(check)")
}
```

The path is relative to the test file. Add the product to the test target, and exclude the lock directory, since the package manager warns about a file a target does not handle:

```swift
.testTarget(
    name: "JournalAPITests",
    dependencies: ["JournalAPI", .product(name: "MMContractLock", package: "mm")],
    exclude: ["Locks"]
)
```

The lock holds what a server serving the contract serves: every method, and the named types the methods reach (pass `sharedTypes:` for a `#schemaTypes` namespace they use), without descriptions or deprecations. Each check does this to the file (``ContractLockCheck/Outcome``):

- No lock: the check writes one from the contract and fails. Commit it.
- The locked contract: the check passes and leaves the file.
- A compatible change, such as a new call or an optional field: the check passes and writes the current contract to the lock. Commit the lock with the change, so the next change is judged against what peers may now be built with.
- A breaking change: the check fails, lists each break (``ContractLockCheck/breaks``), and leaves the file.
- A file that is not a lock, or a lock edited by hand, which no longer matches its fingerprint: the check fails and leaves the file.

To accept a break on purpose, delete the lock and run the check again. It writes the new contract, and the lock's diff shows the break in review.

The check reads and writes the source tree, so run it on macOS or Linux, not on a device or an emulator. This module uses Foundation for its JSON and its files, which is why it is a product of its own, kept out of the runtime libraries.

## Topics

### Locking a contract

- ``ContractLock``
- ``ContractLock/init(_:sharedTypes:)``
- ``ContractLock/init(methods:types:)``
- ``ContractLock/difference(to:)``

### The file form

- ``ContractLock/text``
- ``ContractLock/parse(_:)``
- ``ContractLockError``

### Checking a lock file

- ``ContractLock/check(_:sharedTypes:lockFile:relativeTo:)``
- ``ContractLock/check(lockFileAt:)``
- ``ContractLockCheck``

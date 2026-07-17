import ArgumentParser
import Foundation
import Logging
import MMClient
import MMSchema
import MMServer
import NIOCore
import ServiceLifecycle
import Testing

@testable import MMCLI

/// Boots a server serving exactly the `Ledger` namespace (the CLI fixture in
/// GeneratedCommandTests.swift) — the composition a completeness claim can be
/// folded for. `ledgerMode` shapes the denial fixtures: `0o300` (`-wx`) keeps
/// calls authorized while denying the `read` that scoped discovery needs.
private func withLedgerServer<T: Sendable>(
    ledgerMode: UInt16 = 0o700,
    _ body: @escaping @Sendable (MMCLIOptions) async throws -> T
) async throws -> T {
    let directory = NSTemporaryDirectory() + "mm-sc-" + UUID().uuidString.prefix(8)
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/s"

    let uid = getuid()
    let gid = getgid()
    let acls: [EntityName: EntityACL] = [
        cliTestEntity("ledger"): EntityACL(owner: uid, group: gid, mode: ledgerMode),
        cliTestEntity("rpc"): EntityACL(owner: uid, group: gid, mode: 0o700),
        cliTestEntity("entity"): EntityACL(owner: uid, group: gid, mode: 0o700),
    ]
    var logger = Logger(label: "mm.servercontract.server")
    logger.logLevel = .warning
    let (bound, boundContinuation) = AsyncStream<SocketAddress>.makeStream()
    let service = MMService(
        configuration: MMServerConfiguration(endpoint: .unix(path: path)),
        namespaces: [Ledger.self],
        aclProvider: InMemoryACLProvider(acls),
        logger: logger,
        onBind: { address in
            boundContinuation.yield(address)
            boundContinuation.finish()
        }
    ) {
        Handle(Ledger.append) { _, _ in
            .success(Ledger.AppendResponse(total: 1))
        }
        Handle(Ledger.compact) { _, _ in
            .success(Ledger.CompactResponse())
        }
        Handle(Ledger.importAll) { _, _ in
            .success(Ledger.ImportAllResponse(lines: []))
        }
    }
    var groupLogger = Logger(label: "mm.servercontract.group")
    groupLogger.logLevel = .error
    let group = ServiceGroup(
        configuration: .init(services: [.init(service: service)], logger: groupLogger)
    )
    return try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
            try await withCLIDeadline(seconds: 60) { try await group.run() }
        }
        _ = try await withCLIDeadline { await bound.first(where: { _ in true }) }
        let options = try MMCLIOptions.parse(["--socket", path])
        let result: T
        do {
            result = try await withCLIDeadline(seconds: 30) { try await body(options) }
        } catch {
            await group.triggerGracefulShutdown()
            try? await tasks.waitForAll()
            throw error
        }
        await group.triggerGracefulShutdown()
        try await tasks.waitForAll()
        return result
    }
}

/// A contract the ledger server does not serve — one phantom method.
private let driftedContract = Schema("ledger") {
    Call("phantom") {
        Access { .read }
    }
}

private func appendOnce(_ client: MMClientConnection) async throws -> Ledger.AppendResponse {
    try MMCLIFailure.unwrap(
        await client.call(
            Ledger.append, on: cliTestEntity("ledger"),
            Ledger.AppendRequest(
                line: "x", kind: .credit, meta: nil, count: nil, force: false, tag: nil)),
        method: "ledger.append", entity: "ledger")
}

@Suite("Server contract claims and automatic verification")
struct ServerContractTests {
    @Test("the folded completeness claim equals the live hello fingerprint")
    func expectedFingerprintMatchesHello() async throws {
        let claim = MMCLIServerContract.complete([Ledger.contract])
        let served = try await withLedgerServer { options in
            try await MMCLIRunner.invoke(options) { client in
                client.helloInfo.serverFingerprint
            }
        }
        #expect(served == claim.expectedFingerprint)
        #expect(claim.fingerprintHex == "0x" + String(served, radix: 16))
    }

    @Test("a matching claim proves the composition — no diff, even for a drifted contract")
    func matchingClaimSkipsDiff() async throws {
        let claim = MMCLIServerContract.complete([Ledger.contract])
        let response = try await withLedgerServer { options in
            try await MMCLIRunner.invoke(options, verifying: driftedContract, claim: claim) {
                client in try await appendOnce(client)
            }
        }
        #expect(response.total == 1)
    }

    @Test("automatic verification passes for the served contract")
    func autoVerifyInSync() async throws {
        let response = try await withLedgerServer { options in
            try await MMCLIRunner.invoke(options, verifying: Ledger.contract) { client in
                try await appendOnce(client)
            }
        }
        #expect(response.total == 1)
    }

    @Test("automatic verification refuses a drifted contract before dispatch")
    func autoVerifyDrift() async throws {
        try await withLedgerServer { options in
            await #expect(throws: ExitCode(76)) {
                _ = try await MMCLIRunner.invoke(options, verifying: driftedContract) { client in
                    try await appendOnce(client)
                }
            }
        }
    }

    @Test("--no-verify skips the diff for one invocation")
    func noVerifySkips() async throws {
        let response = try await withLedgerServer { options in
            let skipping = try MMCLIOptions.parse([
                "--socket", options.socket ?? "", "--no-verify",
            ])
            return try await MMCLIRunner.invoke(skipping, verifying: driftedContract) { client in
                try await appendOnce(client)
            }
        }
        #expect(response.total == 1)
    }

    @Test("denied discovery skips verification without blocking the authorized call")
    func deniedDiscoverySkips() async throws {
        // -wx: append (write, with execute traversal) is authorized; the
        // read that scoped discovery needs is not.
        let response = try await withLedgerServer(ledgerMode: 0o300) { options in
            try await MMCLIRunner.invoke(options, verifying: Ledger.contract) { client in
                try await appendOnce(client)
            }
        }
        #expect(response.total == 1)
    }

    @Test("a mismatched claim falls back to the scoped diff and proceeds when in sync")
    func mismatchedClaimFallsBack() async throws {
        let stale = MMCLIServerContract.complete([Ledger.contract, driftedContract])
        let response = try await withLedgerServer { options in
            try await MMCLIRunner.invoke(options, verifying: Ledger.contract, claim: stale) {
                client in try await appendOnce(client)
            }
        }
        #expect(response.total == 1)
    }

    @Test("client-level verifyContracts reports the slice verdicts")
    func verifyContractsAPI() async throws {
        let (inSync, drifted) = try await withLedgerServer { options in
            try await MMCLIRunner.invoke(options) { client in
                let clean = try MMCLIFailure.unwrap(
                    await client.verifyContracts([Ledger.contract]),
                    method: "rpc.schema", entity: "ledger")
                let dirty = try MMCLIFailure.unwrap(
                    await client.verifyContracts([driftedContract]),
                    method: "rpc.schema", entity: "ledger")
                return (clean.count, dirty.count)
            }
        }
        #expect(inSync == 0)
        #expect(drifted == 1)
    }
}

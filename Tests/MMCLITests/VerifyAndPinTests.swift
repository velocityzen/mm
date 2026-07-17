import ArgumentParser
import MMClient
import MMSchema
import Testing

@testable import MMCLI

/// The compiled-contract twin of the test server's `echo.run` route
/// (CLITestServer.swift) — what a CLI built against that server would verify.
private let echoContract = Schema("echo") {
    Call("run") {
        Access { .write }
        Request {
            Field("value", .int)
            Field("note", .optional(.string))
        }
        Response {
            Field("value", .int)
            Field("note", .optional(.string))
        }
    }
}

@Suite("Fingerprint pin and contract verify")
struct VerifyAndPinTests {
    @Test("a wrong --expect-fingerprint refuses before dispatch (EX_PROTOCOL)")
    func wrongPinRefuses() async throws {
        try await withCLIServer { options in
            let pinned = try MMCLIOptions.parse([
                "--socket", options.socket ?? "",
                "--expect-fingerprint", "0xdeadbeefdeadbeef",
            ])
            await #expect(throws: ExitCode(76)) {
                _ = try await MMCLIRunner.invoke(pinned) { _ in true }
            }
        }
    }

    @Test("the matching pin proceeds")
    func matchingPinProceeds() async throws {
        try await withCLIServer { options in
            let fingerprint = try await MMCLIRunner.invoke(options) { client in
                client.helloInfo.serverFingerprint
            }
            let pinned = try MMCLIOptions.parse([
                "--socket", options.socket ?? "",
                "--expect-fingerprint", "0x" + String(fingerprint, radix: 16),
            ])
            let proceeded = try await MMCLIRunner.invoke(pinned) { _ in true }
            #expect(proceeded)
        }
    }

    @Test("verify reports in sync for a matching contract")
    func verifyInSync() async throws {
        try await withCLIServer { options in
            try await MMCLIVerify.run(contract: echoContract, options: options)
        }
    }

    @Test("verify exits 1 on drift")
    func verifyDrift() async throws {
        let drifted = Schema("echo") {
            Call("run") {
                // Access class changed, and a method the server never heard of.
                Access { .read }
                Request {
                    Field("value", .int)
                    Field("note", .optional(.string))
                }
                Response {
                    Field("value", .int)
                    Field("note", .optional(.string))
                }
            }
            Call("purge") {
                Access { .write }
            }
        }
        try await withCLIServer { options in
            await #expect(throws: ExitCode(1)) {
                try await MMCLIVerify.run(contract: drifted, options: options)
            }
        }
    }
}

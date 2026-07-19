import ArgumentParser
import MMClient
import MMSchema
import MMTestSupport
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

@Suite("Contract verify")
struct VerifyAndPinTests {
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

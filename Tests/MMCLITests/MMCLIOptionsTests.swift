import ArgumentParser
import MMTestSupport
import MMWire
import NIOCore
import Testing

@testable import MMCLI

@Suite("MMCLIOptions: parsing and validation")
struct MMCLIOptionsTests {
    @Test("a bound default endpoint fills in for omitted flags; explicit flags win")
    func boundDefaultEndpoint() throws {
        // A task-local binding, not a process-global: no other test can
        // observe it, no serialization needed.
        try MMCLIDefaults.$current.withValue(
            MMCLIDefaults(endpoint: .unix(path: "/tmp/mm-default.sock"))
        ) {
            let defaulted = try MMCLIOptions.parse([])
            #expect(defaulted.endpoint == .unix(path: "/tmp/mm-default.sock"))
            let explicit = try MMCLIOptions.parse(["--socket", "/tmp/mm-explicit.sock"])
            #expect(explicit.endpoint == .unix(path: "/tmp/mm-explicit.sock"))
            let tcp = try MMCLIOptions.parse(["--tcp", "localhost:9000"])
            #expect(tcp.endpoint == .tcp(host: "localhost", port: 9000))
        }
    }

    @Test("--socket maps to a unix endpoint")
    func socketEndpoint() throws {
        let options = try MMCLIOptions.parse(["--socket", "/tmp/x.sock"])
        #expect(options.endpoint == .unix(path: "/tmp/x.sock"))
    }

    @Test("--tcp maps to a tcp endpoint, split on the last colon")
    func tcpEndpoint() throws {
        let options = try MMCLIOptions.parse(["--tcp", "localhost:8080"])
        #expect(options.endpoint == .tcp(host: "localhost", port: 8080))
    }

    @Test("neither --socket nor --tcp fails validation")
    func missingEndpoint() {
        #expect(throws: (any Error).self) {
            try MMCLIOptions.parse([])
        }
    }

    @Test("--socket and --tcp together fail validation")
    func bothEndpoints() {
        #expect(throws: (any Error).self) {
            try MMCLIOptions.parse(["--socket", "/tmp/x.sock", "--tcp", "localhost:8080"])
        }
    }

    @Test(
        "malformed --tcp values fail validation",
        arguments: ["no-colon", ":8080", "host:", "host:0", "host:99999", "host:port"]
    )
    func badTCP(address: String) {
        #expect(throws: (any Error).self) {
            try MMCLIOptions.parse(["--tcp", address])
        }
    }

    @Test("empty --socket path fails validation")
    func emptySocket() {
        #expect(throws: (any Error).self) {
            try MMCLIOptions.parse(["--socket", ""])
        }
    }

    @Test("the CLI never sets a fingerprint expectation — verification is automatic")
    func fingerprintNeverExpected() throws {
        let options = try MMCLIOptions.parse(["--socket", "/tmp/x.sock"])
        #expect(options.clientConfiguration.schema == nil)
    }

    @Test("timeouts map to TimeAmount, defaults stay put")
    func timeouts() throws {
        let options = try MMCLIOptions.parse([
            "--socket", "/tmp/x.sock", "--connect-timeout", "1.5", "--hello-timeout", "2",
        ])
        let configuration = options.clientConfiguration
        #expect(configuration.connectTimeout == .nanoseconds(1_500_000_000))
        #expect(configuration.helloTimeout == .seconds(2))

        let defaulted = try MMCLIOptions.parse(["--socket", "/tmp/x.sock"])
        #expect(defaulted.clientConfiguration.connectTimeout == nil)
        #expect(defaulted.clientConfiguration.helloTimeout == .seconds(10))
    }

    @Test(
        "non-positive and non-finite timeouts fail validation",
        arguments: ["0", "-1", "nan", "inf", "1e300"]
    )
    func badTimeouts(seconds: String) {
        #expect(throws: (any Error).self) {
            try MMCLIOptions.parse(["--socket", "/tmp/x.sock", "--connect-timeout", seconds])
        }
    }

    @Test("output format defaults to json and parses every named form")
    func outputFormat() throws {
        #expect(try MMCLIOptions.parse(["--socket", "/tmp/x.sock"]).output == .json)
        #expect(
            try MMCLIOptions.parse(["--socket", "/tmp/x.sock", "--output", "json-pretty"])
                .output == .jsonPretty
        )
        #expect(
            try MMCLIOptions.parse(["--socket", "/tmp/x.sock", "--output", "raw"]).output == .raw
        )
        #expect(throws: (any Error).self) {
            try MMCLIOptions.parse(["--socket", "/tmp/x.sock", "--output", "yaml"])
        }
    }
}

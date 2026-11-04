import Foundation  // Tests only: a Pipe to read the reporter's bytes back.
import MMTestSupport
import ProgramStatus
import Synchronization
import Testing

@testable import MMServer

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#endif

/// The reports a server sends, in order.
private final class ReportLog: Sendable {
    private let storage = Mutex<[StatusReport]>([])

    var reports: [StatusReport] { self.storage.withLock { $0 } }

    var part: ServerPart {
        ServerPart(
            kind: .programStatus(
                ServerProgramStatus(send: { report in self.storage.withLock { $0.append(report) } })
            )
        )
    }
}

private func statusService(endpoints: [MMEndpoint], _ log: ReportLog) -> ServerRuntime {
    ServerRuntime {
        Configuration(endpoints: endpoints)
        ACLProvider(InMemoryACLProvider([:]))
        Log(label: "test.status", level: .error)
        log.part
    }
}

@Suite("Program status: the server's lifecycle on the terminal")
struct ServerProgramStatusTests {
    @Test("a run reports listening on every endpoint, draining, then stopped")
    func lifecycle() async throws {
        let log = ReportLog()
        try await withTempSocketPath(prefix: "mm-status-") { path in
            let service = statusService(
                endpoints: [.unix(path: path), .tcp(host: "127.0.0.1", port: 0)],
                log
            )
            let addresses = try await withListeningServer(service) { addresses in
                // Acquire reported before the body runs; nothing else yet.
                #expect(log.reports.count == 1)
                return addresses
            }
            // The ephemeral port is reported as the one bound.
            let port = try #require(addresses[1].port)
            #expect(
                log.reports == [
                    .idle("Listening on \(path), 127.0.0.1:\(port)"),
                    .working("Draining connections"),
                    .idle("Stopped"),
                ]
            )
        }
    }

    @Test("a bind that fails reports why, and nothing after")
    func bindFailure() async throws {
        let log = ReportLog()
        try await withTempSocketPath(prefix: "mm-status-") { path in
            // A regular file at the path: never a socket, so the bind fails.
            let descriptor = open(path, O_CREAT | O_WRONLY, 0o600)
            try #require(descriptor >= 0)
            close(descriptor)
            let service = statusService(endpoints: [.unix(path: path)], log)
            let result = try await withDeadline(seconds: 30) {
                let withServer = service.start()
                return await withServer { _ in .success(()) }
            }
            guard case .failure(.socketPathOccupied(path)) = result else {
                Issue.record("expected socketPathOccupied, got \(result)")
                return
            }
            #expect(log.reports == [.error("Something that is not a socket is at \(path)")])
        }
    }

    @Test("each failure reads as one line naming its cause")
    func failureMessages() {
        #expect(
            ServerProgramStatus.failed(.socketPathInUse(path: "/run/a.sock"))
                == .error("Another server is listening on /run/a.sock")
        )
        #expect(
            ServerProgramStatus.failed(.invalidSocketPath(path: ""))
                == .error("Invalid socket path ")
        )
        #expect(
            ServerProgramStatus.failed(.io(description: "accept failed")) == .error("accept failed")
        )
    }

    @Test("a message with a control character is collapsed onto one line")
    func singleLine() {
        let sent = Mutex<[StatusReport]>([])
        let status = ServerProgramStatus(send: { report in sent.withLock { $0.append(report) } })
        status.report(.error("bind failed:\n\taddress in use"))
        #expect(sent.withLock { $0 } == [.error("bind failed: address in use")])
    }

    @Test("the parameter form writes OSC 7501 sequences through the given reporter")
    func reporterBytes() async throws {
        let pipe = Pipe()
        let reporter = ProgramStatusReporter(
            app: "journald",
            destination: .fileHandle(pipe.fileHandleForWriting)
        )
        try await withTempSocketPath(prefix: "mm-status-") { path in
            let result = try await withDeadline(seconds: 30) {
                let service = MMService(
                    configuration: MMServerConfiguration(endpoint: .unix(path: path)),
                    aclProvider: InMemoryACLProvider([:]),
                    programStatus: reporter
                ) {}
                return await service { _ in .success(()) }
            }
            if case .failure(let error) = result {
                Issue.record("the server failed: \(error)")
            }
            try pipe.fileHandleForWriting.close()
            let written = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            let listening = try StatusEncoder.encode(.idle("Listening on \(path)", app: "journald"))
                .get()
            let stopped = try StatusEncoder.encode(.idle("Stopped", app: "journald")).get()
            #expect(written.hasPrefix(listening))
            #expect(written.hasSuffix(stopped))
        }
    }

    // Exit tests run their body in a child process; Swift Testing has them
    // on macOS, Linux and Windows only.
    #if os(macOS) || os(Linux) || os(Windows)
    @Test("an app outside the protocol's charset is programmer error")
    func invalidApp() async throws {
        await #expect(processExitsWith: .failure) {
            _ = ProgramStatusReporting(app: "has space")
        }
    }

    @Test("declaring ProgramStatusReporting twice is programmer error")
    func duplicate() async throws {
        await #expect(processExitsWith: .failure) {
            _ = MMService {
                Configuration(endpoint: .unix(path: "/tmp/status-twice.sock"))
                ACLProvider(InMemoryACLProvider([:]))
                ProgramStatusReporting(app: "one")
                ProgramStatusReporting(app: "two")
            }
        }
    }
    #endif
}

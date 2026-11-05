import ArgumentParser
import Logging
import MMClient
import MMSchema
import MMServer
import MMTestSupport
import Testing

@testable import MMCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Parts that ARE an optional named type: `lookup` may find no note, and
/// `annotate` may carry none.
enum Notes: MethodNamespace {
    #schema("notes") {
        CLI(.enabled)
        Type("Note") {
            Field("text", .string)
        }
        Call("lookup") {
            Access { .read }
            Request {
                Field("id", .string, cli: .argument)
            }
            Response(.optional(.reference("Note")))
        }
        Call("annotate") {
            Access { .write }
            Request(.optional(.reference("Note")))
            Response {
                Field("annotated", .bool)
            }
        }
    }
}

/// Boots a server for `Notes`: `lookup` finds only the note "known", and
/// `annotate` says whether it was sent one.
private func withNotesServer<T: Sendable>(
    _ body: @escaping @Sendable (MMCLIOptions) async throws -> T
) async throws -> T {
    try await withTempSocketPath(prefix: "mm-notes-") { path in
        let acls: [EntityName: EntityACL] = [
            cliTestEntity("notes"): EntityACL(owner: getuid(), group: getgid(), mode: 0o700),
            cliTestEntity("server"): EntityACL(owner: getuid(), group: getgid(), mode: 0o700),
        ]
        var logger = Logger(label: "mm.optionalpayload.server")
        logger.logLevel = .warning
        let service = ServerRuntime(
            configuration: MMServerConfiguration(endpoint: .unix(path: path)),
            namespaces: [Notes.self],
            aclProvider: InMemoryACLProvider(acls),
            logger: logger
        ) {
            Handle(Notes.lookup) { request, _ in
                .success(request.id == "known" ? Notes.Note(text: "found") : nil)
            }
            Handle(Notes.annotate) { request, _ in
                .success(Notes.AnnotateResponse(annotated: request != nil))
            }
        }
        return try await withListeningServer(service) { _ in
            let options = try MMCLIOptions.parse(["--socket", path])
            return try await withDeadline(seconds: 30) { try await body(options) }
        }
    }
}

@Suite("Parts that are an optional named type")
struct OptionalPayloadTests {
    @Test("the descriptors carry the optional type; no struct stands in for it")
    func descriptors() {
        let lookup: Method<Notes.LookupRequest, Notes.Note?> = Notes.lookup
        let annotate: Method<Notes.Note?, Notes.AnnotateResponse> = Notes.annotate
        #expect(lookup.name == "notes.lookup")
        #expect(annotate.name == "notes.annotate")
    }

    @Test("the contract declares the optional reference and verifies clean")
    func contract() throws {
        let breaks = try Notes.contract.verify(against: Notes.self).get()
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
        let lookup = try Notes.lookup.signature().get()
        #expect(lookup.response == .optional(.reference("notes.Note")))
        let annotate = try Notes.annotate.signature().get()
        #expect(annotate.request == .optional(.reference("notes.Note")))
    }

    @Test("nil and a value both cross the wire, each way")
    func wire() async throws {
        let entity = cliTestEntity("notes")
        let results = try await withNotesServer { options in
            try await MMCLIRunner.invoke(options, verifying: Notes.contract) { client in
                func unwrap<Value>(_ result: Result<Value, MMCallError>) throws -> Value {
                    try MMCLIFailure.unwrap(result, method: "notes", entity: "notes")
                }
                let found = try unwrap(
                    await client.call(Notes.lookup, on: entity, Notes.LookupRequest(id: "known")))
                let missing = try unwrap(
                    await client.call(Notes.lookup, on: entity, Notes.LookupRequest(id: "gone")))
                let sent = try unwrap(
                    await client.call(Notes.annotate, on: entity, Notes.Note(text: "hi")))
                let unsent = try unwrap(await client.call(Notes.annotate, on: entity, nil))
                return (found, missing, sent.annotated, unsent.annotated)
            }
        }
        #expect(results.0 == Notes.Note(text: "found"))
        #expect(results.1 == nil)
        #expect(results.2 == true)
        #expect(results.3 == false)
    }

    @Test("an optional request is an optional --request: leaving it out sends nil")
    func optionalRequestOption() throws {
        let base = ["--socket", "/tmp/notes.sock"]
        let bare = try Notes.AnnotateCommand.parse(base)
        #expect(bare.requestJSON == nil)
        let filled = try Notes.AnnotateCommand.parse(base + ["--request", #"{"text":"hi"}"#])
        #expect(filled.requestJSON == #"{"text":"hi"}"#)
        #expect(
            try MMCLIJSON.decode(Notes.Note.self, from: filled.requestJSON, option: "request")
                == Notes.Note(text: "hi"))
    }

    @Test("an optional response renders as what it holds; nil renders as null")
    func output() throws {
        try MMCLIDefaults.$current.withValue(
            MMCLIDefaults(formatters: [Format(Notes.Note.self) { "note: \($0.text)" }])
        ) {
            let found: Notes.Note? = Notes.Note(text: "found")
            let missing: Notes.Note? = nil
            let foundText = try MMCLIOutput.render(found, format: .text)
            let foundJSON = try MMCLIOutput.render(found, format: .json)
            let missingText = try MMCLIOutput.render(missing, format: .text)
            let missingJSON = try MMCLIOutput.render(missing, format: .json)
            #expect(foundText == "note: found")
            #expect(foundJSON == #"{"text":"found"}"#)
            #expect(missingText == "null")
            #expect(missingJSON == "null")
        }
    }
}

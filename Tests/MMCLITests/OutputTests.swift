import ArgumentParser
import MMSchema
import MMTestSupport
import Synchronization
import Testing

@testable import MMCLI

/// A trivially observable subcommand for the synthesized-root seam.
private struct ProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "probe")
    static let ran = Mutex(false)

    func run() {
        Self.ran.withLock { $0 = true }
    }
}

/// Shaped like a macro-generated struct: Int-raw CodingKeys whose
/// `stringValue`s are the case names, so JSONEncoder prints named keys.
private struct Fixture: Encodable {
    var count: Int
    var line: String

    enum CodingKeys: Int, CodingKey {
        case count = 0
        case line = 1
    }
}

@Suite("MMCLIOutput: rendering")
struct OutputTests {
    @Test("json renders compact, sorted, named keys")
    func compactJSON() throws {
        let rendered = try MMCLIOutput.render(
            Fixture(count: 2, line: "hi"), format: .json)
        #expect(rendered == #"{"count":2,"line":"hi"}"#)
    }

    @Test("json-pretty renders multi-line with named keys")
    func prettyJSON() throws {
        let rendered = try MMCLIOutput.render(
            Fixture(count: 2, line: "hi"), format: .jsonPretty)
        #expect(rendered.contains("\n"))
        #expect(rendered.contains(#""count" : 2"#))
        #expect(rendered.contains(#""line" : "hi""#))
    }

    @Test("raw currently renders identically to json")
    func rawMatchesJSON() throws {
        let fixture = Fixture(count: 5, line: "x")
        let raw = try MMCLIOutput.render(fixture, format: .raw)
        let json = try MMCLIOutput.render(fixture, format: .json)
        #expect(raw == json)
    }

    /// A second type, to prove Format entries key by type — not tool-wide.
    private struct OtherFixture: Encodable {
        var ok: Bool

        enum CodingKeys: Int, CodingKey {
            case ok = 0
        }
    }

    /// A type carrying its own text form — the registry-free way.
    private struct SelfDescribing: Encodable, CustomStringConvertible {
        var count: Int
        var description: String { "\(self.count) items" }

        enum CodingKeys: Int, CodingKey {
            case count = 0
        }
    }

    @Test("the synthesized root parses and dispatches through a bound Configuration")
    func synthesizedRoot() async {
        await dispatchSynthesizedRoot(
            CommandConfiguration(commandName: "tool", subcommands: [ProbeCommand.self]),
            arguments: ["probe"]
        )
        #expect(ProbeCommand.ran.withLock { $0 })
        // Outside the dispatch nothing remains bound.
        #expect(MMCLIRoot.boundConfiguration == nil)
    }

    @Test("the sugar root-shape parts assemble a configuration, merging onto Configuration(...)")
    func sugarRootShape() {
        // Sugar alone.
        let (_, sugarOnly) = assembleParts([
            Name("tool"),
            Abstract("Does things."),
            Version("1.2.3"),
            Commands([ProbeCommand.self]),
        ])
        #expect(sugarOnly?.commandName == "tool")
        #expect(sugarOnly?.abstract == "Does things.")
        #expect(sugarOnly?.version == "1.2.3")
        #expect(sugarOnly?.subcommands.count == 1)
        // Sugar merging onto a Configuration base carrying what the sugar
        // doesn't cover.
        var base = CommandConfiguration(subcommands: [ProbeCommand.self])
        base.defaultSubcommand = ProbeCommand.self
        let (_, merged) = assembleParts([
            Configuration(base),
            Name("tool"),
        ])
        #expect(merged?.commandName == "tool")
        #expect(merged?.defaultSubcommand == ProbeCommand.self)
        // No root-shape parts: no synthesized configuration.
        let (_, none) = assembleParts([Output(.text)])
        #expect(none == nil)
    }

    @Test("the MMCLI block assembles the declarations and binds them around the body")
    func declarativeEntryPoint() async throws {
        try await MMCLI {
            Contract(.complete([Schema("tool") { Call("ping") { Access { .read } } }]))
            Endpoint(.unix(path: "/tmp/mmcli-dsl.sock"))
            Output(.text)
            Format(Fixture.self) { "\($0.count)|\($0.line)" }
        } run: {
            let bound = MMCLIDefaults.current
            #expect(bound.endpoint == .unix(path: "/tmp/mmcli-dsl.sock"))
            #expect(bound.output == .text)
            #expect(bound.serverContract?.contracts.first?.namespace == "tool")
            let rendered = try MMCLIOutput.render(
                Fixture(count: 4, line: "ok"), format: .text)
            #expect(rendered == "4|ok")
        }
        // Scoped, never installed: outside the block nothing remains bound.
        #expect(MMCLIDefaults.current.endpoint == nil)
    }

    @Test("text honors CustomStringConvertible when no Format entry is bound; the entry wins")
    func textCustomStringConvertible() throws {
        // No binding at all: the conformance is enough.
        let bare = try MMCLIOutput.render(SelfDescribing(count: 3), format: .text)
        #expect(bare == "3 items")
        // An explicit Format entry outranks the conformance.
        try MMCLIDefaults.$current.withValue(
            MMCLIDefaults(formatters: [
                Format(SelfDescribing.self) { "count=\($0.count)" }
            ])
        ) {
            let bound = try MMCLIOutput.render(SelfDescribing(count: 3), format: .text)
            #expect(bound == "count=3")
        }
        // json never consults the conformance.
        let machine = try MMCLIOutput.render(SelfDescribing(count: 3), format: .json)
        #expect(machine == #"{"count":3}"#)
    }

    @Test("text renders registered types through their Format entry; unregistered fall back to JSON")
    func textFormat() throws {
        try MMCLIDefaults.$current.withValue(
            MMCLIDefaults(formatters: [
                // The inference overload: the closure's parameter annotation
                // pins the type — no metatype spelling.
                Format { (fixture: Fixture) in "\(fixture.count)\t\(fixture.line)" }
            ])
        ) {
            let registered = try MMCLIOutput.render(
                Fixture(count: 2, line: "hi"), format: .text)
            #expect(registered == "2\thi")
            // Per-type, not tool-wide: an unregistered type stays JSON.
            let unregistered = try MMCLIOutput.render(
                OtherFixture(ok: true), format: .text)
            #expect(unregistered == #"{"ok":true}"#)
            // Machine formats always bypass the formatter.
            let machine = try MMCLIOutput.render(
                Fixture(count: 2, line: "hi"), format: .json)
            #expect(machine == #"{"count":2,"line":"hi"}"#)
        }
        // No binding at all: text degrades to compact JSON.
        let unbound = try MMCLIOutput.render(Fixture(count: 2, line: "hi"), format: .text)
        #expect(unbound == #"{"count":2,"line":"hi"}"#)
    }
}

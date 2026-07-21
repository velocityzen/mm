import ArgumentParser
import MMCLI
import MMSchema
import MMTestSupport
import Testing

/// A fixture contract exercising every CLI-generation path: command rename +
/// aliases, omission, positional/flag/short/renamed/omitted fields, a typed
/// enum option, a JSON option for a named-type field, and automatic
/// kebab-casing of a camelCase call name.
enum Ledger: MethodNamespace {
    #schema("ledger", cli: .enabled) {
        Enum("Kind", description: "Which side of the ledger") {
            Case("credit")
            Case("debit")
        }
        Type("Meta", description: "Attribution for one entry") {
            Field("note", .string)
        }
        Call("append", description: "Appends one entry") {
            CLI(.command("add", aliases: ["append"]))
            Access { .write }
            Request {
                Field("line", .string, description: "The entry text", cli: .argument)
                Field("kind", "Kind", description: "Credit or debit")
                Field("meta", .optional(.reference("Meta")))
                Field("count", .optional(.int), cli: .omitted)
                Field("force", .bool, cli: .flag)
                Field("tag", .optional(.string), cli: .option("label", short: "l"))
            }
            Response { Field("total", .int) }
        }
        Call("compact") {
            CLI(.omitted)
            Access { .write }
        }
        Call("importAll", description: "Reads everything back") {
            Access { .read }
            Response { Field("lines", .array(.string)) }
        }
    }
}

@Suite("Generated CLI commands")
struct GeneratedCommandTests {
    @Test("the namespace group carries the schema prefix, non-omitted calls, and verify")
    func groupConfiguration() {
        let configuration = Ledger.Command.configuration
        #expect(configuration.commandName == "ledger")
        let names = configuration.subcommands.map { $0.configuration.commandName }
        #expect(names == ["add", "import-all", "verify"])
    }

    @Test("every group gets the contract-drift verify subcommand")
    func verifySubcommand() {
        #expect(Ledger.VerifyCommand.configuration.commandName == "verify")
    }

    @Test("CLI(.command) renames and aliases the subcommand")
    func renameAndAliases() {
        let configuration = Ledger.AppendCommand.configuration
        #expect(configuration.commandName == "add")
        #expect(configuration.aliases == ["append"])
        #expect(configuration.abstract == "Appends one entry")
    }

    @Test("a camelCase call name kebab-cases by default")
    func kebabCasedDefault() {
        #expect(Ledger.ImportAllCommand.configuration.commandName == "import-all")
    }

    @Test("the entity argument is optional: omitted parses as nil (server-side inference)")
    func entityOmitted() throws {
        let command = try Ledger.ImportAllCommand.parse(["--socket", "/tmp/ledger.sock"])
        #expect(command.entity == nil)
        // Spelled, it still binds as the first positional.
        let spelled = try Ledger.ImportAllCommand.parse([
            "--socket", "/tmp/ledger.sock", "ledger.main",
        ])
        #expect(spelled.entity == "ledger.main")
    }

    @Test("the full surface parses: entity, positional, enum, flag, short rename")
    func fullParse() throws {
        let command = try Ledger.AppendCommand.parse([
            "--socket", "/tmp/ledger.sock",
            "ledger.main", "hello world",
            "--kind", "credit",
            "--force",
            "-l", "urgent",
        ])
        #expect(command.entity == "ledger.main")
        #expect(command.line == "hello world")
        #expect(command.kind == .credit)
        #expect(command.force == true)
        #expect(command.tag == "urgent")
        #expect(command.meta == nil)
        #expect(command.connection.output == .json)
    }

    @Test("the renamed option answers to its long form")
    func renamedLongForm() throws {
        let command = try Ledger.AppendCommand.parse([
            "--socket", "/tmp/ledger.sock", "ledger.main", "x", "--kind", "debit",
            "--label", "later",
        ])
        #expect(command.tag == "later")
    }

    @Test("the enum option refuses the generated unknown fallback")
    func unknownEnumValueRefused() {
        #expect(throws: (any Error).self) {
            _ = try Ledger.AppendCommand.parse([
                "--socket", "/tmp/ledger.sock", "ledger.main", "x", "--kind", "unknown",
            ])
        }
    }

    @Test("help lists enum values without unknown and carries field descriptions")
    func helpContent() {
        let help = Ledger.AppendCommand.helpMessage()
        #expect(help.contains("credit"))
        #expect(help.contains("debit"))
        #expect(!help.contains("unknown"))
        #expect(help.contains("The entry text"))
        #expect(help.contains("--label"))
        // The omitted field surfaces nowhere.
        #expect(!help.contains("count"))
    }

    @Test("a JSON option is a plain string at parse time")
    func jsonOptionParses() throws {
        let command = try Ledger.AppendCommand.parse([
            "--socket", "/tmp/ledger.sock", "ledger.main", "x", "--kind", "credit",
            "--meta", #"{"note":"from tests"}"#,
        ])
        #expect(command.meta == #"{"note":"from tests"}"#)
    }

    @Test("MMCLIJSON decodes generated types with named keys")
    func jsonDecoding() throws {
        let meta = try MMCLIJSON.decodeRequired(
            Ledger.Meta.self, from: #"{"note":"hi"}"#, option: "meta")
        #expect(meta == Ledger.Meta(note: "hi"))
        #expect(try MMCLIJSON.decode(Ledger.Meta.self, from: nil, option: "meta") == nil)
        #expect(throws: (any Error).self) {
            _ = try MMCLIJSON.decodeRequired(Ledger.Meta.self, from: "{nope", option: "meta")
        }
    }

    @Test("the contract still verifies — the overlay never touches the wire")
    func overlayIsWireInert() throws {
        let breaks = try Ledger.contract.verify(against: Ledger.self).get()
        #expect(breaks.isEmpty)
        // Signatures carry no trace of the CLI overlay: fingerprints of the
        // annotated contract and a stripped re-declaration must match.
        let stripped = Schema("ledger") {
            Enum("Kind", description: "Which side of the ledger") {
                Case("credit")
                Case("debit")
            }
            Type("Meta", description: "Attribution for one entry") {
                Field("note", .string)
            }
            Call("append", description: "Appends one entry") {
                Access { .write }
                Request {
                    Field("line", .string, description: "The entry text")
                    Field("kind", "Kind", description: "Credit or debit")
                    Field("meta", .optional(.reference("Meta")))
                    Field("count", .optional(.int))
                    Field("force", .bool)
                    Field("tag", .optional(.string))
                }
                Response { Field("total", .int) }
            }
            Call("compact") {
                Access { .write }
            }
            Call("importAll", description: "Reads everything back") {
                Access { .read }
                Response { Field("lines", .array(.string)) }
            }
        }
        #expect(Ledger.contract.fingerprint() == stripped.fingerprint())
    }
}

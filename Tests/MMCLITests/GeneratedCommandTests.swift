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
    #schema("ledger", description: "Double-entry ledger operations.") {
        CLI(.enabled)
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
                Field("origin", .optional(.string), cli: .option(short: .auto))
                Field("tint", .optional(.string), cli: .option("color", short: .auto))
                Field("format", .optional(.string), default: "json")
                Field("when", .optional(.timestamp), default: .now)
                Field("exclude", .array(.string))
                Field("only", .optional(.array(.string)))
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
        // The namespace root call: the method IS the namespace — wire name
        // "ledger", descriptor `Ledger.root`, and the group's default
        // subcommand (`tool ledger` alone runs it).
        Call("@", description: "Summarizes the ledger") {
            Access { .read }
            Response { Field("entries", .int) }
        }
    }
}

/// A description-less namespace: the group abstract falls back to the
/// template and `namespaceDescription` stays the protocol default.
enum Petty: MethodNamespace {
    #schema("petty") {
        CLI(.enabled)
        Call("poke") {
            Access { .read }
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
        #expect(names == ["add", "import-all", "root", "verify"])
    }

    @Test("the schema description becomes the group abstract and the namespace doc")
    func namespaceDescription() {
        #expect(Ledger.Command.configuration.abstract == "Double-entry ledger operations.")
        #expect(Ledger.namespaceDescription == "Double-entry ledger operations.")
        #expect(Ledger.contract.description == "Double-entry ledger operations.")
        // Without one: the template abstract, nil everywhere else.
        #expect(Petty.Command.configuration.abstract == "Commands for the petty namespace.")
        #expect(Petty.namespaceDescription == nil)
        #expect(Petty.contract.description == nil)
    }

    @Test("Call(\"@\") is the namespace root: wire name, descriptor, default subcommand")
    func rootCall() throws {
        // The method IS the namespace.
        #expect(Ledger.root.name == "ledger")
        // The contract re-emission carries the same wire name (macro
        // fidelity: the runtime DSL folds "@" identically).
        #expect(Ledger.contract.signatures.map(\.name).contains("ledger"))
        let breaks = try Ledger.contract.verify(against: Ledger.self).get()
        #expect(breaks == [])
        // The generated command exists and is the group's default: the
        // group name alone dispatches to it.
        #expect(Ledger.Command.configuration.defaultSubcommand == Ledger.RootCommand.self)
        let command = try Ledger.RootCommand.parse(["--socket", "/tmp/ledger.sock"])
        #expect(command.entity == nil)
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

    @Test("a required positional binds before the omittable entity")
    func requiredPositionalBeforeEntity() throws {
        // One bare value is the required field, never the entity — the
        // layout is `<line> [<entity>]`.
        let command = try Ledger.AppendCommand.parse([
            "--socket", "/tmp/ledger.sock", "just a line", "--kind", "credit",
        ])
        #expect(command.line == "just a line")
        #expect(command.entity == nil)
    }

    @Test("array fields are repeatable options defaulting to empty, never required")
    func arrayOptions() throws {
        let base = ["--socket", "/tmp/ledger.sock", "x", "--kind", "credit"]
        let bare = try Ledger.AppendCommand.parse(base)
        #expect(bare.exclude == [])
        #expect(bare.only == [])
        let filled = try Ledger.AppendCommand.parse(
            base + ["--exclude", "a", "--exclude", "b", "--only", "c"])
        #expect(filled.exclude == ["a", "b"])
        #expect(filled.only == ["c"])
    }

    @Test("the full surface parses: entity, positional, enum, flag, short rename")
    func fullParse() throws {
        let command = try Ledger.AppendCommand.parse([
            "--socket", "/tmp/ledger.sock",
            "hello world", "ledger.main",
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

    @Test("Field default: bare flag means the default, a value overrides, absent is nil")
    func defaultAsFlag() throws {
        let base = ["--socket", "/tmp/ledger.sock", "x", "ledger.main", "--kind", "credit"]
        #expect(try Ledger.AppendCommand.parse(base).format == nil)
        #expect(try Ledger.AppendCommand.parse(base + ["--format"]).format == "json")
        #expect(try Ledger.AppendCommand.parse(base + ["--format", "yaml"]).format == "yaml")
        // Help renders the hybrid shape: optional value, flag-default note.
        let help = Ledger.AppendCommand.helpMessage()
        #expect(help.contains("--format [<format>]"))
        #expect(help.contains("default as flag: json"))
    }

    @Test("default: .now on a timestamp field means the moment of invocation")
    func nowDefault() throws {
        let base = ["--socket", "/tmp/ledger.sock", "x", "ledger.main", "--kind", "credit"]
        #expect(try Ledger.AppendCommand.parse(base).when == nil)
        let explicit = try Ledger.AppendCommand.parse(base + ["--when", "2026-01-01T00:00:00Z"])
        #expect(explicit.when == MMTimestamp("2026-01-01T00:00:00Z"))
        let stamped = try #require(try Ledger.AppendCommand.parse(base + ["--when"]).when)
        // The bare flag reads the clock at parse: offset zero, a sane year.
        #expect(stamped.offsetMinutes == 0)
        #expect(stamped.dateTime.date.year >= 2026)
    }

    @Test("short: .auto derives the short from the long name, renamed or not")
    func derivedShorts() throws {
        let command = try Ledger.AppendCommand.parse([
            "--socket", "/tmp/ledger.sock", "x", "ledger.main", "--kind", "credit",
            "-o", "today", "-c", "blue",
        ])
        #expect(command.origin == "today")
        #expect(command.tint == "blue")
        // The long forms still answer.
        let spelled = try Ledger.AppendCommand.parse([
            "--socket", "/tmp/ledger.sock", "x", "ledger.main", "--kind", "credit",
            "--origin", "today", "--color", "blue",
        ])
        #expect(spelled.origin == "today")
        #expect(spelled.tint == "blue")
    }

    @Test("the renamed option answers to its long form")
    func renamedLongForm() throws {
        let command = try Ledger.AppendCommand.parse([
            "--socket", "/tmp/ledger.sock", "x", "ledger.main", "--kind", "debit",
            "--label", "later",
        ])
        #expect(command.tag == "later")
    }

    @Test("the enum option refuses the generated unknown fallback")
    func unknownEnumValueRefused() {
        #expect(throws: (any Error).self) {
            _ = try Ledger.AppendCommand.parse([
                "--socket", "/tmp/ledger.sock", "x", "ledger.main", "--kind", "unknown",
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
            "--socket", "/tmp/ledger.sock", "x", "ledger.main", "--kind", "credit",
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
                    Field("origin", .optional(.string))
                    Field("tint", .optional(.string))
                    Field("format", .optional(.string), default: "json")
                    Field("when", .optional(.timestamp), default: .now)
                    Field("exclude", .array(.string))
                    Field("only", .optional(.array(.string)))
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
            Call("@", description: "Summarizes the ledger") {
                Access { .read }
                Response { Field("entries", .int) }
            }
        }
        #expect(Ledger.contract.fingerprint() == stripped.fingerprint())
    }
}

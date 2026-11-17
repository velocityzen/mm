import ArgumentParser
import MMCLI
import MMSchema
import Testing

/// A fixture contract with wire defaults and deprecations on the command
/// line: a defaulted scalar, enum and duration option, a duration whose
/// default is a flag default, a deprecated option, call and enum case.
enum Catalogue: MethodNamespace {
    #schema("catalogue") {
        CLI(.enabled)
        Enum("Shelf") {
            Case("top")
            Case("attic", deprecated: "use top")
        }
        Call("list", description: "Lists the catalogue", deprecated: "use search") {
            Access { .read }
            Request {
                Field("limit", .int, default: 20)
                Field("shelf", "Shelf", default: "top")
                Field("wait", .duration, constraints: .range(.seconds(1)...), default: "PT30S")
                Field("delay", .optional(.duration), default: "PT1M")
                Field(
                    "legacy",
                    .optional(.string),
                    description: "Old filter",
                    deprecated: "ignored"
                )
            }
            Response { Field("count", .int) }
        }
    }
}

@Suite("Generated commands: wire defaults and deprecations")
struct SchemaEvolutionCommandTests {
    @Test("an option for a field with a wire default takes the default when absent")
    func defaults() throws {
        let bare = try Catalogue.ListCommand.parse(["--socket", "/tmp/catalogue.sock"])
        #expect(bare.limit == 20)
        #expect(bare.shelf == .top)
        let given = try Catalogue.ListCommand.parse([
            "--socket", "/tmp/catalogue.sock", "--limit", "5", "--shelf", "attic",
        ])
        #expect(given.limit == 5)
        #expect(given.shelf == .attic)
    }

    @Test(
        "a duration option takes its wire default when absent, and a bare optional one its flag default"
    )
    func durationDefaults() throws {
        let socket = ["--socket", "/tmp/catalogue.sock"]
        let bare = try Catalogue.ListCommand.parse(socket)
        #expect(bare.wait == MMDuration(.seconds(30)))
        #expect(bare.delay == nil)
        #expect(
            try Catalogue.ListCommand.parse(socket + ["--delay"]).delay == MMDuration(.seconds(60))
        )
        let given = try Catalogue.ListCommand.parse(
            socket + ["--wait", "PT5S", "--delay", "PT0.25S"]
        )
        #expect(given.wait == MMDuration(.seconds(5)))
        #expect(given.delay == MMDuration(.milliseconds(250)))
        #expect(throws: (any Error).self) {
            try Catalogue.ListCommand.parse(socket + ["--wait", "5s"])
        }
    }

    @Test("help marks the deprecated call and option")
    func help() {
        #expect(
            Catalogue.ListCommand.configuration.abstract
                == "Lists the catalogue (deprecated: use search)"
        )
        let help = Catalogue.ListCommand.helpMessage()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("Old filter (deprecated: ignored)"))
    }

    @Test("a deprecated enum case still parses, and the conformance names it")
    func deprecatedEnumCase() {
        #expect(Catalogue.Shelf.deprecatedValues == ["attic": "use top"])
        #expect(Catalogue.Shelf(argument: "attic") == .attic)
        #expect(Catalogue.Shelf(argument: "cellar") == nil)
    }
}

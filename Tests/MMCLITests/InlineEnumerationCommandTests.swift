import ArgumentParser
import MMCLI
import MMSchema
import Testing

/// Inline enumerations on the fields a command takes: a call's own request
/// fields, and the fields of the declared type that is a call's request. Their
/// enums are nested in those types, so the commands name them through the
/// types.
enum Paint: MethodNamespace {
    #schema("paint") {
        CLI(.enabled)
        Type("Job") {
            Field(
                "finish",
                .enumeration(cases: [.init(name: "matte"), .init(name: "gloss")]),
                default: "matte"
            )
        }
        Call("mix") {
            Access { .write }
            Request {
                Field("base", .enumeration(cases: [.init(name: "oil"), .init(name: "water")]))
                Field(
                    "coats",
                    .array(.enumeration(cases: [.init(name: "primer"), .init(name: "clear")]))
                )
                Field(
                    "shade",
                    .optional(
                        .enumeration(cases: [
                            .init(name: "light"), .init(name: "dark", deprecation: "too dark"),
                        ])
                    )
                )
            }
        }
        Call("apply") {
            Access { .write }
            Request(.reference("Job"))
        }
    }
}

@Suite("Generated CLI commands take inline enumerations as typed options")
struct InlineEnumerationCommandTests {
    let base = ["--socket", "/tmp/paint.sock"]

    @Test("a request's inline enumerations parse as their declared values")
    func requestFields() throws {
        let command = try Paint.MixCommand.parse(
            base + ["--base", "oil", "--coats", "primer", "--coats", "clear", "--shade", "light"]
        )
        #expect(command.base == .oil)
        #expect(command.coats == [.primer, .clear])
        #expect(command.shade == .light)
        let bare = try Paint.MixCommand.parse(base + ["--base", "water"])
        #expect(bare.coats.isEmpty)
        #expect(bare.shade == nil)
        // A value the contract does not declare is refused, never `unknown`.
        #expect(throws: (any Error).self) {
            try Paint.MixCommand.parse(base + ["--base", "acrylic"])
        }
    }

    @Test("a declared type's inline enumeration takes its wire default when left out")
    func declaredTypeField() throws {
        #expect(try Paint.ApplyCommand.parse(base).finish == .matte)
        #expect(try Paint.ApplyCommand.parse(base + ["--finish", "gloss"]).finish == .gloss)
    }

    @Test("help lists the declared values, and a deprecated one warns")
    func help() {
        #expect(Paint.MixRequest.Base.allValueStrings == ["oil", "water"])
        #expect(Paint.MixRequest.Shade.deprecatedValues == ["dark": "too dark"])
        #expect(Paint.Job.Finish.deprecatedValues.isEmpty)
        let help = Paint.MixCommand.helpMessage()
        #expect(help.contains("oil"))
        #expect(help.contains("water"))
    }

    @Test("the contract keeps the inline enumerations and verifies")
    func contract() throws {
        #expect(try Paint.contract.verify(against: Paint.self).get().isEmpty)
    }
}

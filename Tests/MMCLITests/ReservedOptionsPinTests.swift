import ArgumentParser
import MMCLI
import MMSchemaMacros
import MMTestSupport
import Testing

/// Pins the two restatements of the shared option surface to each other and
/// to reality, so adding an option to `MMCLIOptions` without updating the
/// macro's reserved list (or vice versa) fails here instead of surfacing as a
/// runtime `--option` collision in a generated command.
@Suite("Reserved option names stay in lockstep")
struct ReservedOptionsPinTests {
    @Test("the macro's reserved list is MMCLIOptions's surface plus help/version")
    func macroListMatchesOptions() {
        #expect(
            SchemaContractMacro.reservedLongOptionNames
                == MMCLIOptions.declaredLongOptionNames.union(["help", "version"]))
    }

    @Test("declaredLongOptionNames matches the actual parsed surface")
    func declaredListMatchesReality() {
        let help = MMCLIOptions.helpMessage()
        for name in MMCLIOptions.declaredLongOptionNames {
            #expect(help.contains("--\(name)"), "option --\(name) missing from help")
        }
        // And nothing undeclared: every long option in the help text is in
        // the declared list.
        let pattern = #/--([a-z][a-z-]*)/#
        let advertised = Set(help.matches(of: pattern).map { String($0.output.1) })
        // help/version belong to swift-argument-parser, not to this surface.
        #expect(
            advertised.subtracting(["help", "version"])
                == MMCLIOptions.declaredLongOptionNames)
    }
}

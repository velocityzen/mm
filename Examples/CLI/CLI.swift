import ArgumentParser
import MMCLI
import MMExampleAPI

/// The generated command-line face of the example daemon: every subcommand
/// under `journal` was emitted by `#schema(cli: .enabled)` in
/// JournalAPI.swift — names, help text, and argument shapes all come from the
/// one contract declaration (with `journal.append` renamed to `journal add`
/// by its `CLI(.command("add"))` overlay).
///
/// ```sh
/// swift run mm-example-daemon                                  # terminal 1
/// swift run mm-example-cli journal add journal.notes "hello" \
///     --socket /tmp/mm-example.sock                            # terminal 2
/// swift run mm-example-cli journal read journal.notes --socket /tmp/mm-example.sock
/// ```
///
/// `journal.notes` is the target **entity** — the noun of the call, and every
/// command's leading positional. It comes from the daemon's ACL tree
/// (Daemon.swift: `Entity("journal") { Entity("notes"); Entity("system") }`),
/// NOT from the schema: the schema declares the verbs and payload shapes, the
/// entity tree is runtime state — syscall table versus file paths. That is
/// why `journal add journal.system "x"` is denied (root-owned entity) while
/// the identical verb on `journal.notes` succeeds, with zero schema
/// difference between the two. The two `journal`s in `journal add
/// journal.notes` are unrelated spellings: the command group is the method
/// namespace; the entity path shares that prefix only by convention.
struct MMExampleCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mm-example-cli",
        abstract: "Talks to mm-example-daemon over its Unix socket.",
        subcommands: [
            Journal.Command.self,
            // Schema-driven generics from MMCLI: what the server serves, and
            // any method by wire name.
            MMCLIDiscover.self,
            MMCLIRawCall.self,
        ]
    )
}

/// The entry point: the build-time defaults bound around the root command's
/// own `main()`. `@main` lives on a plain struct — not the command — so
/// ArgumentParser's parse/dispatch/exit choreography runs unchanged inside
/// the binding; there is no boilerplate to hide. The defaults are a
/// task-local, never installed: the example daemon serves exactly the
/// journal contract (every invocation verifies the whole composition for
/// free from the hello fingerprint; a grown daemon falls back to a scoped
/// discovery diff automatically), and the daemon's well-known socket fills
/// in when `--socket`/`--tcp` are omitted.
@main
struct Main {
    static func main() async {
        await withCLI(
            MMCLIDefaults(
                serverContract: .complete([journalContract]),
                endpoint: .unix(path: "/tmp/mm-example.sock")
            )
        ) {
            await MMExampleCLI.main()
        }
    }
}

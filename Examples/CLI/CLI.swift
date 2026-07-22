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
/// swift run mm-example-daemon                       # terminal 1
/// swift run mm-example-cli journal add journal.notes "hello"   # terminal 2
/// swift run mm-example-cli journal read journal.notes --output text
/// ```
///
/// The whole tool is one declaration — the CLI twin of the daemon's
/// `MMService { ... }`. `MMCLI` synthesizes and runs the root command from
/// `Configuration(...)` (parse, async dispatch, help, and exit codes all
/// through ArgumentParser); the other declarations bind as a task-local for
/// the invocation: the contract claim verifies the whole composition for
/// free from the hello fingerprint (a grown daemon falls back to a scoped
/// discovery diff automatically), `Endpoint` makes `--socket`/`--tcp`
/// optional, and the `Format` entries give `--output text` per-command
/// rendering keyed by the generated types (json formats always bypass them,
/// so scripts stay stable).
///
/// `journal.notes` is the target **entity** — the noun of the call, and every
/// command's leading positional. It comes from the daemon's ACL tree
/// (Daemon.swift: `Entity("journal") { Entity("notes"); Entity("system") }`),
/// NOT from the schema: the schema declares the verbs and payload shapes, the
/// entity tree is runtime state — syscall table versus file paths. That is
/// why `journal add journal.system "x"` is denied (root-owned entity) while
/// the identical verb on `journal.notes` succeeds, with zero schema
/// difference between the two.
@main
struct MMExampleCLI {
    static func main() async {
        await MMCLI {
            Name("mm-example-cli")
            Abstract("Talks to mm-example-daemon over its Unix socket.")
            Commands([
                Journal.Command.self,
                // Schema-driven generics from MMCLI: what the server serves,
                // and any method by wire name.
                MMCLIDiscover.self,
                MMCLIRawCall.self,
            ])
            Contract(.complete([journalContract]))
            Endpoint(.unix(path: "/tmp/mm-example.sock"))
            // Both spellings: explicit metatype, or the type inferred from
            // the closure parameter.
            Format(ChangeEvent.self) { "\($0.count)\t\($0.line)" }
            Format { (response: Journal.ReadResponse) in
                response.lines.joined(separator: "\n")
            }
        }
    }
}

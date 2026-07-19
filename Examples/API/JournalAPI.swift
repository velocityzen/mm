import ArgumentParser
import MMCLI
import MMSchema

/// The example's shared wire contract — written exactly once.
///
/// This module depends on `MMSchema` only: the dependency direction the
/// library is built around, so client-only processes never link the server.
///
/// ## The declaration IS the source of truth
///
/// `#schema` expands the declarative contract at compile time into everything
/// it implies — there is no second copy to keep in sync:
///
/// - one struct per request/response/stream element (integer `CodingKeys`,
///   `Codable & Hashable & Sendable`, public memberwise inits) — nested in
///   `Journal`, re-exported below as top-level aliases;
/// - the typed descriptors (`Journal.append`, `.read`, `.follow`, `.import`)
///   that make `client.call(...)` and `Handle(...)` compile-time typed;
/// - the namespace list (`Journal.all`) the router cross-checks at startup;
/// - the runtime declaration (`Journal.contract`), re-emitted from the same
///   source, so the daemon's boot-time `contract.verify(against:)` is a
///   macro-fidelity check rather than a drift check.
///
/// Conventions still apply underneath: field keys are declaration-order (pin
/// with `Field(3, "note", .string)` when evolving; new fields must be optional
/// per the wire-evolution contract), the `Request` part is optional (an empty
/// payload when omitted — the target entity rides the open envelope, never
/// the payload), and stream elements are plain values.
/// Named types (`Enum`/`Type`) are part of the contract too: `Priority` is a
/// string-valued wire enum (the generated Swift enum gains an `unknown` case
/// for unrecognized values), `LineMeta` a named struct other fields reference.
/// Every `description:` below is served by `server.schema` — discovery is
/// self-documenting — while staying out of the fingerprint and all
/// compatibility checks: doc edits are never schema drift.
public enum Journal: MethodNamespace {
    #schema("journal", cli: .enabled) {
        Enum("Priority", description: "How urgent a line is") {
            Case("normal")
            Case("urgent", description: "Surfaces immediately to followers")
        }
        Type("LineMeta", description: "Attribution carried with a line") {
            Field("author", .string, description: "Who wrote the line")
            Field("priority", "Priority")
        }
        Type("ChangeEvent", description: "One appended line, as delivered to followers") {
            Field("entity", .string)
            Field("line", .string)
            Field("count", .int)
        }
        Call("append", description: "Appends one line to a journal") {
            // The wire method stays journal.append; the CLI says `journal add`.
            CLI(.command("add", aliases: ["append"]))
            Access { .write }
            Request {
                Field("line", .string, description: "The line text", cli: .argument)
                Field(
                    "meta", .optional(.reference("LineMeta")),
                    description: "Optional attribution")
            }
            Response {
                Field("count", .int, description: "Lines now in the journal")
            }
        }
        Call("read", description: "Returns every line in the journal") {
            Access { .read }
            Response {
                Field("lines", .array(.string))
            }
        }
        // Server → client stream: a follower receives a ChangeEvent for every
        // append to the journal (from any connection) until it STOPs; the
        // terminal summarizes what was delivered. Server push is an ordinary
        // method with a response stream — correlated, authorized at open,
        // fingerprinted, discoverable.
        Call("follow", description: "Streams every change to a journal until STOP") {
            Access { .read }
            // The stream elements ARE the named ChangeEvent type above — a
            // part can reference a type instead of declaring inline fields.
            ResponseStream(.reference("ChangeEvent"))
            Response("FollowSummary", description: "What was delivered before STOP") {
                Field("delivered", .int)
            }
        }
        // Client → server stream: the client streams lines and finishes; the
        // terminal reports how many landed and the journal's new total.
        Call("import", description: "Bulk-appends a stream of lines") {
            Access { .write }
            RequestStream("ImportLine", description: "One line to append") {
                Field("line", .string)
            }
            Response("ImportSummary") {
                Field("imported", .int)
                Field("total", .int)
            }
        }
    }
}

// The generated types live inside `Journal`; re-export them so handler and
// client code reads naturally.
public typealias Priority = Journal.Priority
public typealias LineMeta = Journal.LineMeta
public typealias AppendRequest = Journal.AppendRequest
public typealias AppendResponse = Journal.AppendResponse
public typealias ReadRequest = Journal.ReadRequest
public typealias ReadResponse = Journal.ReadResponse
public typealias FollowRequest = Journal.FollowRequest
public typealias ChangeEvent = Journal.ChangeEvent
public typealias FollowSummary = Journal.FollowSummary
public typealias ImportRequest = Journal.ImportRequest
public typealias ImportLine = Journal.ImportLine
public typealias ImportSummary = Journal.ImportSummary

/// The runtime declaration the macro re-emitted — both sides hold themselves
/// to it: the daemon verifies at boot, the client verifies and diffs it
/// against discovery.
public let journalContract: SchemaDeclaration = Journal.contract

import ArgumentParser
import MMClient
import MMSchema

/// The raw-call escape hatch: calls **any unary method by wire name**, with
/// no generated command required. The flow is entirely schema-driven —
/// discover the server's schema, find the method's signature, validate and
/// encode `--params` JSON against the request shape
/// (``MMCLIDynamicRequest``), and decode the response against the response
/// shape (``MMCLIDynamicResponse``) — so the CLI can drive servers whose
/// contract this build has never seen.
///
/// Streaming methods are refused (their element pumps need a generated
/// command); unknown or unreachable methods exit 64 with a pointer to
/// `discover`.
public struct MMCLIRawCall: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "call",
        abstract: "Calls any method by wire name (schema-driven)."
    )

    @OptionGroup public var connection: MMCLIOptions

    @Argument(help: "Wire method name (dotted, e.g. journal.append)")
    public var method: String

    @Argument(help: "Target entity (dotted path)")
    public var entity: String

    @Option(help: ArgumentHelp("Request payload as a JSON object.", valueName: "json"))
    public var params: String = "{}"

    public init() {}

    public func run() async throws {
        // Locals only inside the call closure: it is @Sendable, and
        // referencing a property would capture non-Sendable self.
        let methodName = method
        let entityArgument = entity
        let target = try MMCLIFailure.entity(entityArgument)
        let json: MMCLIDynamicTree
        do {
            json = try MMCLIDynamicTree.parse(jsonText: params)
        } catch let error as ValidationError {
            throw ValidationError("--params is not valid JSON: \(error.message)")
        }
        let format = connection.output
        let tree = try await MMCLIRunner.invoke(connection) { client in
            // Root-scoped discovery: the method may target any entity, and
            // the response is filtered to what this peer can reach anyway.
            let schema = try MMCLIFailure.unwrap(
                await client.discoverSchema(scope: .root),
                method: "rpc.schema",
                entity: ""
            )
            guard let signature = schema.methods.first(where: { $0.name == methodName }) else {
                MMCLIOutput.note("unknown or unreachable method \(methodName); try discover")
                throw ExitCode(64)
            }
            guard signature.requestStream == nil, signature.responseStream == nil else {
                MMCLIOutput.note("streaming methods need a generated CLI command")
                throw ExitCode(64)
            }
            let request = try MMCLIDynamicRequest(
                schema: signature.request, definitions: schema.types, json: json)
            // The client-side access mode is descriptive metadata only (the
            // server authorizes from its own registration), so .read is fine
            // for a descriptor assembled from a name.
            let response = try MMCLIFailure.unwrap(
                await MMCLIDynamicResponse.$schema.withValue((signature.response, schema.types)) {
                    await client.call(
                        Method<MMCLIDynamicRequest, MMCLIDynamicResponse>(
                            name: methodName, access: .read),
                        on: target,
                        request
                    )
                },
                method: methodName,
                entity: entityArgument
            )
            return response.tree
        }
        MMCLIOutput.emitText(MMCLIDynamicJSONText(tree, pretty: format == .jsonPretty))
    }
}

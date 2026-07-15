/// The declarative contract as the compile-time source of truth.
///
/// Expanded inside a namespace enum, `#schema` generates everything the
/// declaration implies — so the wire contract is written exactly once:
///
/// ```swift
/// public enum Journal: MethodNamespace {
///     #schema("journal") {
///         Call("append") {
///             Access { .write }
///             Request { Field("line", .string) }
///             Response { Field("count", .int) }
///         }
///         Call("follow") {
///             Access { .read }
///             ResponseStream("ChangeEvent") {
///                 Field("entity", .string)
///                 Field("line", .string)
///                 Field("count", .int)
///             }
///             Response("FollowSummary") { Field("delivered", .int) }
///         }
///     }
/// }
/// ```
///
/// Generated members:
/// - One struct per request, response, and stream element — integer
///   `CodingKeys` assigned exactly like the runtime DSL (request payloads are
///   plain values with fields keyed from 0; the target entity rides the open
///   envelope), `Codable &
///   Hashable & Sendable`, public memberwise inits. Names default to
///   `<Call>Request` / `<Call>Response` / `<Call>RequestItem` /
///   `<Call>ResponseItem`; override with a leading string literal
///   (`Response("FollowSummary") { ... }`).
/// - The typed descriptor per call (`Method`, `ServerStreamMethod`,
///   `ClientStreamMethod`, or `BidirectionalStreamMethod`, chosen by which stream parts
///   are declared), named after the call (`Journal.append`).
/// - `static var all: [AnyMethod]` — declare the `MethodNamespace` conformance
///   on the enum yourself (a freestanding macro cannot add it).
/// - `static let contract: SchemaDeclaration` — the runtime declaration,
///   re-emitted verbatim, so `contract.verify(against: Self.self)` doubles as
///   a macro-fidelity check.
///
/// The macro consumes the DSL's **static subset**: literal names and keys, no
/// runtime conditionals, and no `payload:`/`.bytes` shapes (those need
/// hand-written types with the runtime DSL). Expansion happens at member
/// scope; `#schema` cannot be used at file scope.
@freestanding(declaration, names: arbitrary)
public macro schema(
    _ namespace: String,
    @SchemaDeclarationBuilder _ content: () -> [SchemaEntry]
) = #externalMacro(module: "MMSchemaMacros", type: "SchemaContractMacro")

/// The types-only counterpart of `#schema`: a shared, namespace-less home for
/// named types several schemas reference.
///
/// ```swift
/// public enum CommonTypes: TypeNamespace {
///     #schemaTypes("common") {
///         Enum("Priority", description: "How urgent") {
///             Case("low")
///             Case("high", description: "Wakes the pager")
///         }
///         Type("LineMeta") {
///             Field("author", .string)
///             Field("priority", "Priority")
///         }
///     }
/// }
/// ```
///
/// Generated members:
/// - One Swift type per declaration — `Enum` becomes a `String`-raw enum with
///   a generated `unknown` case (unrecognized wire values decode to it; the
///   house wire-enum rule), `Type` becomes a struct like `#schema`'s — both
///   `SchemaDescribable` as `.reference("<namespace>.<Name>")`, which is how
///   other schemas' fields carry the reference
///   (`Field("meta", CommonTypes.LineMeta.self)`).
/// - `static var types: [TypeDefinition]` — the definitions, served by
///   discovery; declare the ``TypeNamespace`` conformance on the enum
///   yourself.
/// - `static var probedTypes` — decoder-behavior probes per definition.
/// - `static let contract: TypeNamespaceDeclaration` — the runtime
///   declaration, re-emitted verbatim, so `contract.verify(against: Self.self)`
///   doubles as a macro-fidelity check.
@freestanding(declaration, names: arbitrary)
public macro schemaTypes(
    _ namespace: String,
    @SchemaTypesBuilder _ content: () -> [TypeDeclaration]
) = #externalMacro(module: "MMSchemaMacros", type: "SchemaTypesMacro")

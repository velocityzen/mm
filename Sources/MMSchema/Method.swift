/// A typed method descriptor: the schema-as-Swift-values core of the protocol.
///
/// A `Method` pairs a wire name (`journal.append`) with the ``AccessMode`` its
/// verb requires on the target entity, and carries the request/response types
/// as generic parameters. Handlers (Phase 3) and typed client calls (Phase 4)
/// both hang off these values, so a method's contract lives in exactly one
/// place.
public struct Method<Request: Codable & Sendable, Response: Codable & Sendable>: Sendable {
    /// The wire method name, dotted like an entity path (`journal.append`).
    public let name: String
    /// The rwx class this verb needs on its target entity.
    public let access: AccessMode
    /// Documentation overlaid onto ``signature()`` and served by discovery.
    public let documentation: MethodDocumentation

    public init(name: String, access: AccessMode, documentation: MethodDocumentation = .init()) {
        self.name = name
        self.access = access
        self.documentation = documentation
    }

    /// Probes `Request` and `Response` and assembles the wire-facing signature.
    public func signature() -> Result<MethodSignature, SchemaError> {
        TypeSchema.of(Request.self).flatMap { request in
            TypeSchema.of(Response.self).map { response in
                documentation.applied(
                    to: MethodSignature(
                        name: name,
                        access: access,
                        request: request,
                        response: response
                    )
                )
            }
        }
    }

    /// The decoder-behavior signature (``TypeSchema/probed(_:)`` on both
    /// types, no documentation overlay) — what `verify(against:)` compares.
    func probedSignature() -> Result<MethodSignature, SchemaError> {
        TypeSchema.probed(Request.self).flatMap { request in
            TypeSchema.probed(Response.self).map { response in
                MethodSignature(
                    name: name,
                    access: access,
                    request: request,
                    response: response
                )
            }
        }
    }
}

/// The optional documentation a descriptor carries for its method and its four
/// payload parts. Served by discovery via the ``MethodSignature`` doc slots;
/// never part of the fingerprint or of compatibility comparisons.
public struct MethodDocumentation: Sendable, Hashable {
    public var description: String?
    public var request: String?
    public var response: String?
    public var requestStream: String?
    public var responseStream: String?

    public init(
        description: String? = nil,
        request: String? = nil,
        response: String? = nil,
        requestStream: String? = nil,
        responseStream: String? = nil
    ) {
        self.description = description
        self.request = request
        self.response = response
        self.requestStream = requestStream
        self.responseStream = responseStream
    }

    /// Overlays the doc slots onto a probed signature.
    func applied(to signature: MethodSignature) -> MethodSignature {
        var documented = signature
        documented.description = self.description
        documented.requestDescription = self.request
        documented.responseDescription = self.response
        documented.requestStreamDescription = self.requestStream
        documented.responseStreamDescription = self.responseStream
        return documented
    }
}

/// The wire-facing description of one method, served by `server.schema` and
/// hashed into the schema fingerprint.
///
/// Keys are grouped by what they describe: the method itself in the single
/// digits (0–2), everything about the request direction in the 10s, and
/// everything about the response direction in the 20s — and every slot is
/// immediately followed by its own doc slot (method 0–1 then 2, request 10
/// then 11, request stream 12 then 13, and likewise in the 20s). The stream
/// slots are optional per the four-part method model (a method may declare
/// any combination of the four parts); every optional slot encodes nothing on
/// the wire when absent (synthesized `encodeIfPresent`) and unknown keys are
/// skipped on decode — the standard wire-evolution contract.
public struct MethodSignature: Sendable, Hashable, Codable {
    public var name: String
    public var access: AccessMode
    /// Human-readable documentation of the method, served by discovery. The
    /// five doc slots (keys 2, 11, 13, 21, 23) are never part of the
    /// fingerprint or of compatibility comparisons.
    public var description: String?
    public var request: TypeSchema
    /// Documentation of the request payload.
    public var requestDescription: String?
    /// Element shape the client may stream after opening the call; `nil` when
    /// the method declares no request stream.
    public var requestStream: TypeSchema?
    /// Documentation of the request-stream elements.
    public var requestStreamDescription: String?
    public var response: TypeSchema
    /// Documentation of the response payload.
    public var responseDescription: String?
    /// Element shape the server may stream before the terminal response; `nil`
    /// when the method declares no response stream.
    public var responseStream: TypeSchema?
    /// Documentation of the response-stream elements.
    public var responseStreamDescription: String?

    public init(
        name: String,
        access: AccessMode,
        request: TypeSchema,
        response: TypeSchema,
        requestStream: TypeSchema? = nil,
        responseStream: TypeSchema? = nil,
        description: String? = nil,
        requestDescription: String? = nil,
        responseDescription: String? = nil,
        requestStreamDescription: String? = nil,
        responseStreamDescription: String? = nil
    ) {
        self.name = name
        self.access = access
        self.request = request
        self.response = response
        self.requestStream = requestStream
        self.responseStream = responseStream
        self.description = description
        self.requestDescription = requestDescription
        self.responseDescription = responseDescription
        self.requestStreamDescription = requestStreamDescription
        self.responseStreamDescription = responseStreamDescription
    }

    enum CodingKeys: Int, CodingKey {
        case name = 0
        case access = 1
        case description = 2
        case request = 10
        case requestDescription = 11
        case requestStream = 12
        case requestStreamDescription = 13
        case response = 20
        case responseDescription = 21
        case responseStream = 22
        case responseStreamDescription = 23
    }
}

extension MethodSignature {
    /// The same signature with every description removed — the form the
    /// fingerprint hashes and `verify`/`SchemaDifference` compare, so doc
    /// edits never register as schema drift.
    public var strippingDescriptions: MethodSignature {
        MethodSignature(
            name: self.name,
            access: self.access,
            request: self.request.strippingDescriptions,
            response: self.response.strippingDescriptions,
            requestStream: self.requestStream?.strippingDescriptions,
            responseStream: self.responseStream?.strippingDescriptions
        )
    }
}

/// A type-erased method descriptor, for namespace listings and router startup
/// cross-checks where the generic request/response types are not needed.
public struct AnyMethod: Sendable {
    public let name: String
    public let access: AccessMode
    private let _signature: @Sendable () -> Result<MethodSignature, SchemaError>
    private let _probedSignature: @Sendable () -> Result<MethodSignature, SchemaError>

    public init<Request, Response>(_ method: Method<Request, Response>) {
        self.name = method.name
        self.access = method.access
        self._signature = { method.signature() }
        self._probedSignature = { method.probedSignature() }
    }

    /// Internal erasure point shared by the stream-descriptor overloads (in
    /// StreamMethod.swift); the signature thunks carry the full four-part
    /// ``MethodSignature``, so no extra stored properties are needed.
    init(
        name: String,
        access: AccessMode,
        signature: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
        probedSignature: @escaping @Sendable () -> Result<MethodSignature, SchemaError>
    ) {
        self.name = name
        self.access = access
        self._signature = signature
        self._probedSignature = probedSignature
    }

    /// The erased method's signature; probing runs lazily on first call and is
    /// memoized per type by the probe cache.
    public func signature() -> Result<MethodSignature, SchemaError> {
        _signature()
    }

    /// The decoder-behavior signature (see ``TypeSchema/probed(_:)``) —
    /// what `verify(against:)` compares, so a self-described type cannot
    /// vouch for itself.
    func probedSignature() -> Result<MethodSignature, SchemaError> {
        _probedSignature()
    }
}

/// A sealed group of method descriptors. The router cross-checks its
/// registered routes against each namespace's `all` at startup, so an unbound
/// descriptor fails at daemon boot rather than at first call.
///
/// Refines ``TypeNamespace``: a namespace that declares named types (via
/// `Type`/`Enum` in a `#schema` block) also carries their ``TypeDefinition``
/// table; namespaces without named types inherit the empty default.
public protocol MethodNamespace: TypeNamespace {
    /// Every method in the namespace, type-erased.
    static var all: [AnyMethod] { get }
    /// Human-readable namespace documentation, doc-only: a router serves it
    /// in discovery's `namespaces` list (never fingerprinted). Defaults to
    /// nil; `#schema(description:)` emits it, hand-written namespaces
    /// override it.
    static var namespaceDescription: String? { get }
}

extension MethodNamespace {
    public static var namespaceDescription: String? { nil }
}

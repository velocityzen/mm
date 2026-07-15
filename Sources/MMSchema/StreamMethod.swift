/// Typed descriptors for streaming methods — the schema-as-Swift-values core
/// of the v1 streaming amendment.
///
/// The method model is four independent parts: every method declares its
/// ``AccessMode`` plus any of request, request stream, response, and response
/// stream. `Method<Request, Response>` remains the unary (no-stream) descriptor; the
/// three types here cover the stream combinations:
///
/// - ``ServerStreamMethod``: the server streams `Element` values before its
///   terminal `Response` (server push is this — correlated, authorized at open,
///   flow-controlled, fingerprinted, discoverable).
/// - ``ClientStreamMethod``: the client streams `Element` values after opening
///   with `Request`; the server answers with one terminal `Response`.
/// - ``BidirectionalStreamMethod``: both directions at once.
///
/// Like `Method`, each pairs a wire name with the access class its verb
/// requires on the target entity, carries its types as generics, and erases to
/// ``AnyMethod`` for namespace listings. Stream elements are plain `Codable`
/// values; authorization happens once, at call open, on the open envelope's
/// target entity.
public struct ServerStreamMethod<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>: Sendable {
    /// The wire method name, dotted like an entity path (`journal.watch`).
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

    /// Probes `Request`, `Element`, and `Response` and assembles the wire-facing
    /// signature, with `Element` in the response-stream slot.
    public func signature() -> Result<MethodSignature, SchemaError> {
        assemble(schemaOf: { TypeSchema.of($0) }).map { documentation.applied(to: $0) }
    }

    /// The decoder-behavior signature (``TypeSchema/probed(_:)``, no
    /// documentation overlay) — what `verify(against:)` compares.
    func probedSignature() -> Result<MethodSignature, SchemaError> {
        assemble(schemaOf: { TypeSchema.probed($0) })
    }

    private func assemble(
        schemaOf: (any (Decodable & Sendable).Type) -> Result<TypeSchema, SchemaError>
    ) -> Result<MethodSignature, SchemaError> {
        schemaOf(Request.self).flatMap { request in
            schemaOf(Element.self).flatMap { element in
                schemaOf(Response.self).map { response in
                    MethodSignature(
                        name: name,
                        access: access,
                        request: request,
                        response: response,
                        responseStream: element
                    )
                }
            }
        }
    }
}

/// A method whose client streams `Element` values after opening with `Request`;
/// the server answers with one terminal `Response`. See ``ServerStreamMethod`` for
/// the model.
public struct ClientStreamMethod<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>: Sendable {
    /// The wire method name, dotted like an entity path (`journal.import`).
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

    /// Probes `Request`, `Element`, and `Response` and assembles the wire-facing
    /// signature, with `Element` in the request-stream slot.
    public func signature() -> Result<MethodSignature, SchemaError> {
        assemble(schemaOf: { TypeSchema.of($0) }).map { documentation.applied(to: $0) }
    }

    /// The decoder-behavior signature (``TypeSchema/probed(_:)``, no
    /// documentation overlay) — what `verify(against:)` compares.
    func probedSignature() -> Result<MethodSignature, SchemaError> {
        assemble(schemaOf: { TypeSchema.probed($0) })
    }

    private func assemble(
        schemaOf: (any (Decodable & Sendable).Type) -> Result<TypeSchema, SchemaError>
    ) -> Result<MethodSignature, SchemaError> {
        schemaOf(Request.self).flatMap { request in
            schemaOf(Element.self).flatMap { element in
                schemaOf(Response.self).map { response in
                    MethodSignature(
                        name: name,
                        access: access,
                        request: request,
                        response: response,
                        requestStream: element
                    )
                }
            }
        }
    }
}

/// A method streaming in both directions: the client streams `RequestElement`
/// values, the server streams `ResponseElement` values, and the call still
/// terminates with exactly one `Response`. See ``ServerStreamMethod`` for the
/// model. Four generic parameters are wide; application-side type aliases
/// tame it.
public struct BidirectionalStreamMethod<
    Request: Codable & Sendable,
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable,
    Response: Codable & Sendable
>: Sendable {
    /// The wire method name, dotted like an entity path (`journal.sync`).
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

    /// Probes all four types and assembles the wire-facing signature with both
    /// stream slots filled.
    public func signature() -> Result<MethodSignature, SchemaError> {
        assemble(schemaOf: { TypeSchema.of($0) }).map { documentation.applied(to: $0) }
    }

    /// The decoder-behavior signature (``TypeSchema/probed(_:)``, no
    /// documentation overlay) — what `verify(against:)` compares.
    func probedSignature() -> Result<MethodSignature, SchemaError> {
        assemble(schemaOf: { TypeSchema.probed($0) })
    }

    private func assemble(
        schemaOf: (any (Decodable & Sendable).Type) -> Result<TypeSchema, SchemaError>
    ) -> Result<MethodSignature, SchemaError> {
        schemaOf(Request.self).flatMap { request in
            schemaOf(RequestElement.self).flatMap { requestElement in
                schemaOf(ResponseElement.self).flatMap { responseElement in
                    schemaOf(Response.self).map { response in
                        MethodSignature(
                            name: name,
                            access: access,
                            request: request,
                            response: response,
                            requestStream: requestElement,
                            responseStream: responseElement
                        )
                    }
                }
            }
        }
    }
}

extension AnyMethod {
    public init<Request, Element, Response>(
        _ method: ServerStreamMethod<Request, Element, Response>
    ) {
        self.init(
            name: method.name,
            access: method.access,
            signature: { method.signature() },
            probedSignature: { method.probedSignature() }
        )
    }

    public init<Request, Element, Response>(
        _ method: ClientStreamMethod<Request, Element, Response>
    ) {
        self.init(
            name: method.name,
            access: method.access,
            signature: { method.signature() },
            probedSignature: { method.probedSignature() }
        )
    }

    public init<Request, RequestElement, ResponseElement, Response>(
        _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>
    ) {
        self.init(
            name: method.name,
            access: method.access,
            signature: { method.signature() },
            probedSignature: { method.probedSignature() }
        )
    }
}

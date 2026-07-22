# ``MMSchema``

The contract layer: method descriptors, wire type schemas, the declarative schema DSL and `#schema` macro, filesystem-style ACLs, peer identity, and the schema fingerprint.

## Overview

MMSchema is pure values — no NIO import, no IO — so client-only processes can depend on it (plus MMClient) without pulling in server machinery.

A wire contract is a set of **method descriptors**: ``Method`` for unary calls, and ``ServerStreamMethod``, ``ClientStreamMethod``, and ``BidirectionalStreamMethod`` for the three streaming shapes of the four-part method model (opening request, optional request stream, optional response stream, terminal response). Descriptors erase to ``AnyMethod`` and are grouped in a ``MethodNamespace``, whose `all` list is what a server cross-checks at startup and what discovery serves as ``MethodSignature`` values.

Contracts can be *declared as data* with the runtime DSL — `Schema("prefix") { Enum / Type / Call { Access; Request; RequestStream; ResponseStream; Response } }` — producing a ``SchemaDeclaration`` that can compute its ``SchemaFingerprint`` and `verify(against:)` the compiled Swift types. The `Call` part functions — `Access`, `Request`, `Response`, `RequestStream`, and `ResponseStream` — are overloaded to take a fields block, a bare ``TypeSchema``, a ``SchemaDescribable`` metatype, or a named-type reference; the full overload set is listed in the function index below. The `#schema` macro (see ``schema(_:cli:_:)``) takes the same declaration at compile time and generates everything it implies: integer-keyed request/response/element structs, string-valued wire enums with an `unknown` fallback, the typed descriptors, `all`, `types`, and the re-emitted contract. Shared named types live in `#schemaTypes` containers (``schemaTypes(_:_:)``) or hand-written ``SchemaDescribable`` types.

Wire shapes are modeled by ``TypeSchema`` (structures with integer-keyed fields, string-valued enumerations, nominal ``TypeDefinition`` references) and discovered from Swift types by `TypeSchema.of(_:)` — a memoized decoder probe with ``SchemaDescribable`` as the escape hatch. Descriptions are doc-only everywhere: served by discovery, never hashed into the fingerprint.

Schema *walking* is written once rather than per consumer: ``TypeResolver`` is the canonical `.reference` resolution through a definitions table (chains followed, cycles reported), ``TypeSchema/fold(resolver:_:)`` is the one recursion for schema analyses, and ``SchemaValue`` is a schema-shaped value as plain data — loose input (typically parsed JSON) canonicalized by ``SchemaValue/validated(against:resolver:path:)``, where the schema decides every scalar kind and failures carry their dotted path. The schema-driven wire coders in MMCLI build on all three.

Calendar and clock values are first-class wire kinds, never strings: `.date` is a calendar date, `.datetime` a floating wall-clock reading, `.timestamp` an absolute instant with a fixed offset — ``MMDate``, ``MMDateTime``, and ``MMTimestamp`` in Swift. The types are dependency-free (hand-rolled ISO 8601 parsing and rendering, no Foundation, no ICU), `Comparable` (timestamps order by instant), and come with calendar math via ``MMDateComponent`` (`date + .month(1)` clamps month ends; time components carry across days), exact `Duration` math (`timestamp - other` is the instant difference), and — where Foundation exists — `DateComponents` interop both ways. On the MessagePack wire all three ride as VPTS binary, the variable-precision timestamp codec whose reference implementation is ``MMVPTS`` (spec: the VPTS article under MMWire); their `Codable` form is the canonical ISO string, which is what JSON projections and display use.

Authorization is filesystem-style: ``EntityName`` is a validated dotted path, ``EntityACL`` carries owner uid, group gid, and 9 rwx/ugo mode bits with first-matching-class-wins semantics, and ``AccessMode`` is the rwx option set a method declares. ``PeerIdentity`` is deliberately not Codable — it is kernel-derived only and never crosses the wire.

Every server also speaks the ``Builtins``: `server.schema` (discovery, scoped by the envelope entity) and `server.entity` (an entity's ACL record).

## Topics

### Method descriptors

- ``Method``
- ``ServerStreamMethod``
- ``ClientStreamMethod``
- ``BidirectionalStreamMethod``
- ``AnyMethod``
- ``MethodSignature``
- ``MethodDocumentation``
- ``MethodNamespace``
- ``SchemaBuilder``

### Contract DSL

- ``Schema(_:_:)``
- ``Types(_:_:)``
- ``Call(_:description:_:)``
- ``Enum(_:description:_:)``
- ``Type(_:description:_:)``
- ``Case(_:description:)``
- ``Field``
- ``Fields(_:)``
- ``StreamOptions``

### Contract declarations

- ``SchemaDeclaration``
- ``TypeNamespaceDeclaration``
- ``MethodDeclaration``
- ``TypeDeclaration``
- ``EnumCaseDeclaration``
- ``SchemaEntry``
- ``MethodPart``

### DSL result builders

- ``SchemaDeclarationBuilder``
- ``MethodDeclarationBuilder``
- ``SchemaFieldsBuilder``
- ``EnumCasesBuilder``
- ``SchemaTypesBuilder``

### Macros

- ``schema(_:cli:_:)``
- ``schemaTypes(_:_:)``

### Type schemas

- ``TypeSchema``
- ``TypeDefinition``
- ``TypeNamespace``
- ``SchemaDescribable``

### Schema-shaped values

- ``SchemaValue``
- ``SchemaValueError``
- ``TypeResolver``
- ``TypeResolutionFailure``

### Builtins

- ``Builtins``
- ``SchemaRequest``
- ``SchemaResponse``
- ``StatRequest``
- ``StatResponse``

### Time

- ``MMDate``
- ``MMDateTime``
- ``MMTimestamp``
- ``MMDateComponent``
- ``MMVPTS``

### Authorization

- ``AccessMode``
- ``EntityACL``

### Identity and naming

- ``PeerIdentity``
- ``EntityName``

### Fingerprint

- ``SchemaFingerprint``

### Errors

- ``SchemaError``
- ``InvalidEntityNameReason``
- ``MMDateTimeParseFailure``
- ``MMVPTSDecodeFailure``

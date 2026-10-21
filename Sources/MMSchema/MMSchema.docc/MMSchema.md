# ``MMSchema``

The contract layer: method descriptors, wire type schemas, the declarative schema DSL and `#schema` macro, filesystem-style ACLs, peer identity, and the schema fingerprint.

## Overview

MMSchema contains only values: no NIO import, no IO. Client-only processes can depend on it (plus MMClient) without server code.

A wire contract is a set of **method descriptors**. Each method has four parts: an opening request, an optional request stream, an optional response stream, and a terminal response.

- ``Method`` describes unary calls.
- ``ServerStreamMethod``, ``ClientStreamMethod``, and ``BidirectionalStreamMethod`` describe the three streaming shapes.

Descriptors erase to ``AnyMethod``. A ``MethodNamespace`` groups them. Its `all` list is what a server cross-checks at startup and what discovery serves as ``MethodSignature`` values.

You can *declare a contract as data* with the runtime DSL: `Schema("prefix") { Enum / Type / Call { Access; Request; RequestStream; ResponseStream; Response } }`. The result is a ``SchemaDeclaration``. It computes its ``SchemaFingerprint`` and can `verify(against:)` the compiled Swift types.

The `Call` part functions (`Access`, `Request`, `Response`, `RequestStream`, `ResponseStream`) accept a fields block, a bare ``TypeSchema``, a ``SchemaDescribable`` metatype, or a named-type reference. The function index below lists all overloads.

The `#schema` macro (see ``schema(_:description:_:)``) takes the same declaration at compile time. It generates:

- integer-keyed request, response, and element structs
- string-valued wire enums with an `unknown` fallback
- the typed descriptors, `all`, and `types`
- the re-emitted contract

Shared named types live in `#schemaTypes` containers (``schemaTypes(_:_:)``) or in hand-written ``SchemaDescribable`` types.

``TypeSchema`` models wire shapes: structures with integer-keyed fields, string-valued enumerations, and nominal ``TypeDefinition`` references. `TypeSchema.of(_:)` reads the schema of a Swift type with a memoized decoder probe. If the probe cannot handle a type, conform it to ``SchemaDescribable`` instead.

Descriptions are documentation only. Discovery serves them, but the fingerprint never includes them. The same applies to the namespace description (`Schema("journal", description: "...")` / `#schema(description:)`). Discovery returns it in the ``NamespaceSignature`` list, and the generated CLI group uses it as its abstract.

Schema *walking* code is shared by all consumers:

- ``TypeResolver`` resolves `.reference` through a definitions table. It follows chains and reports cycles.
- ``TypeSchema/fold(resolver:_:)`` is the one recursion for schema analyses.
- ``SchemaValue`` is a schema-shaped value as plain data. ``SchemaValue/validated(against:resolver:path:)`` canonicalizes loose input, typically parsed JSON. The schema decides every scalar kind, and each failure includes its dotted path.

The schema-driven wire coders in MMCLI use all three.

Calendar and clock values are wire kinds of their own, never strings:

- `.date` is a calendar date (``MMDate``).
- `.datetime` is a floating wall-clock reading (``MMDateTime``).
- `.timestamp` is an absolute instant with a fixed offset (``MMTimestamp``).

These types:

- have no dependencies: their own ISO 8601 parsing and rendering, no Foundation, no ICU
- are `Comparable` (timestamps order by instant)
- support calendar math with ``MMDateComponent``: `date + .month(1)` clamps to the month end, and time components carry across days
- support exact `Duration` math: `timestamp - other` is the instant difference
- step by day: ``MMDate`` is `Strideable`, so `startDate..<endDate` iterates
- with Foundation, convert to and from `DateComponents` and read the current moment: `MMTimestamp.now(in:)`, `MMDateTime.now(in:)`, `MMDate.today(in:)`

The core types never read the clock themselves.

On the MessagePack wire, all three use VPTS binary, the variable-precision timestamp codec. ``MMVPTS`` is its reference implementation (spec: the VPTS article under MMWire). Their `Codable` form is the canonical ISO string, which JSON projections and display use.

Authorization works like a filesystem:

- ``EntityName`` is a validated dotted path.
- ``EntityACL`` holds an owner uid, a group gid, and 9 rwx/ugo mode bits. The first matching class wins.
- ``AccessMode`` is the rwx option set a method declares.

``PeerIdentity`` is intentionally not Codable. It comes only from the kernel and never crosses the wire.

Every server also serves the ``Builtins``:

- `server.schema`: discovery, scoped by the envelope entity
- `server.entity`: an entity's ACL record

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

- ``Schema(_:description:_:)``
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

- ``schema(_:description:_:)``
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
- ``NamespaceSignature``
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

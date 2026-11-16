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
- string-valued wire enums with an `unknown(String)` fallback that keeps an undeclared value
- tagged unions (`Union`, whose `Case`s carry their own fields), with an `unknown(tag:fields:)` fallback that keeps an undeclared case's name and its fields' bytes (``MMPackRawValue``)
- the typed descriptors, `all`, and `types`
- the re-emitted contract

A contract also declares the errors its calls fail with. A top-level `Errors` block holds the namespace's, an `Errors` part in a `Call` adds the call's own, and `Error("Full", exitCode:)` declares a named error that `Case(.reference("Full"))` lists. `#schema` generates one flat ``MMDeclaredError`` enum per call (`Journal.AppendError`) and wraps the call's descriptor in ``MethodWithErrors``. Each ``MethodSignature`` serves the call's errors as a union (``MethodSignature/errors``), and the fingerprint covers them. Exit codes are presentation for the generated CLI, in ``declaredErrorExitCodes``.

A contract also declares the rules values keep beyond their shape. A field takes a `constraints:` list (`Field("limit", .int, constraints: .range(1...1000))`), and `Alias("Slug", .string, constraints: .length(1...64), .pattern("[a-z0-9-]+"))` declares a **named scalar** that fields refer to by name. Each ``Constraint`` is a range (inclusive, on `int`, `uint`, `float`, `double`), a length (inclusive, counting a string's Unicode scalars, a byte string's bytes, an array's elements, a map's entries), or a pattern (a regular expression a string matches whole). A declaration that puts a rule on a kind that does not take it, or whose bounds cross, is refused where it is written. Constraints are part of the contract: discovery serves them as ``TypeSchema/Constraints``, and the fingerprint covers them.

A server checks them at ingress in every build, after decoding and before the handler, and its error names the failing field's path (`malformed params: limit: is 0, less than the minimum 1`). `#schema` generates the check for every type that holds a constrained value (``MMConstraintValidating``) and hands it to the call's descriptor (``MMConstraintCheck``). In debug builds of the declaring module, a client runs the same check before sending. ``SchemaValue/validated(against:resolver:path:checkingConstraints:)`` checks constraints on loose input, as the CLI does.

A contract evolves without a version bump. A `default:` on a field that is not optional is a **wire default** (``TypeSchema/Default``): the field travels as an optional, the generated type holds the bare value, an absent key or a `nil` reads as the default, and the field is always written. A default is a literal of the field's kind that keeps its constraints, or a declaration is refused where it is written. ``Reserved(_:)`` retires a removed field's key and name so no later field takes either, and unpinned fields skip reserved keys. A `deprecated:` reason on a field, a case, a type or a call is documentation: discovery serves it, a deprecated generated struct field is `@available(*, deprecated)`, and the fingerprint never includes it. The fingerprint covers defaults, and never reservations.

Shared named types live in `#schemaTypes` containers (``schemaTypes(_:_:)``) or in hand-written ``SchemaDescribable`` types.

``TypeSchema`` models wire shapes: structures with integer-keyed fields, string-valued enumerations, tagged unions, raw bytes (``MMBytes``), and nominal ``TypeDefinition`` references. `TypeSchema.of(_:)` reads the schema of a Swift type with a memoized decoder probe. If the probe cannot handle a type, conform it to ``SchemaDescribable`` instead.

Descriptions are documentation only. Discovery serves them, but the fingerprint never includes them. The same applies to the namespace description (`Schema("journal", description: "...")` / `#schema(description:)`). Discovery returns it in the ``NamespaceSignature`` list, and the generated CLI group uses it as its abstract.

Schema *walking* code is shared by all consumers:

- ``TypeResolver`` resolves `.reference` through a definitions table. It follows chains and reports cycles.
- ``TypeSchema/fold(resolver:_:)`` is the one recursion for schema analyses.
- ``SchemaValue`` is a schema-shaped value as plain data. ``SchemaValue/validated(against:resolver:path:checkingConstraints:)`` canonicalizes loose input, typically parsed JSON. The schema decides every scalar kind, and each failure includes its dotted path.

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
- ``Call(_:description:deprecated:_:)``
- ``Enum(_:description:deprecated:_:)``
- ``Union(_:description:deprecated:_:)``
- ``Type(_:description:deprecated:_:)``
- ``Alias(_:_:constraints:description:deprecated:)``
- ``Case(_:description:deprecated:)``
- ``Case(_:description:deprecated:_:)``
- ``Field``
- ``Fields(_:)``
- ``StreamOptions``

### Constraints

- ``Constraint``
- ``TypeSchema/Constraints``
- ``TypeSchema/Bound``
- ``TypeSchema/ConstraintChecker``
- ``MMConstraintValidating``
- ``MMConstraintCheck``
- ``MMConstraintPath``

### Schema evolution

- ``FieldDefault``
- ``TypeSchema/Default``
- ``Reserved(_:)``
- ``FieldReservation``

### Declared errors

- ``Errors(_:)``
- ``Error(_:exitCode:description:)``
- ``Error(_:exitCode:description:_:)``
- ``Case(_:)``
- ``Case(_:exitCode:description:)``
- ``Case(_:exitCode:description:_:)``
- ``Case(_:_:exitCode:description:)``
- ``ErrorsDeclaration``
- ``ErrorCaseDeclaration``
- ``NamedErrorDeclaration``
- ``ErrorsBuilder``
- ``declaredErrorExitCodes``
- ``MMDeclaredError``
- ``MethodWithErrors``

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

### Generated MessagePack code

- ``MMPackEncodable``
- ``MMPackDecodable``
- ``MMPackCodable``
- ``MMPackWriter``
- ``MMPackReader``
- ``MMPackMapKey``

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

### Bytes

- ``MMBytes``
- ``MMPackRawValue``

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

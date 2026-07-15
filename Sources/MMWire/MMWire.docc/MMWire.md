# ``MMWire``

The wire layer: MessagePack coding over `ByteBuffer`, length-prefix framing, the RPC envelope, and the hello preamble.

## Overview

MMWire implements the bottom layers of the matter-in-motion protocol and depends on NIOCore only:

- **Framing** — `[u32 LE length][payload]` frames via ``MMFrameDecoder`` and ``MMFrameEncoder``. The length counts the payload only, and the cap (default 16 MiB, see ``MMWireInfo``) is enforced before a single body byte is accumulated.
- **Hello preamble** — ``MMHello``, a fixed 15-byte structure (magic `MM`, protocol version, schema fingerprint, capability bitset) sent as the first frame in each direction.
- **Envelope** — ``MMEnvelope``, tagged MessagePack arrays with kinds 0–6: terminal, open, credit, item, END, STOP, and CANCEL. Params, results, and stream items stay raw `ByteBuffer` slices until a typed layer decodes them.

Typed payloads are coded by ``MMPackEncoder`` and ``MMPackDecoder``: structs encode as MessagePack maps with integer keys, unknown keys are skipped on decode, and `ByteBuffer`-typed fields get zero-copy bin/str slices. Beneath the coders, the MessagePack value layer is exposed as the `readMessagePack*` / `writeMessagePack*` method families on `ByteBuffer` — readers for every format family, writers that always emit the smallest correct representation, a structural `skipMessagePackValue(maxDepth:)`, and `readMessagePackRawValueSlice(maxDepth:)` for zero-copy raw extents. Because those methods extend a NIOCore type, they appear under `ByteBuffer`'s extensions in the reference rather than in the lists below.

Failures surface as `Result` with the single typed error ``MMWireError``. Well-known RPC error codes live in ``MMErrorCode``: codes 1–63 are reserved for the protocol, applications use 64 and above.

The byte-level contract — every frame, envelope kind, ACL rule, fingerprint step, and pinned conformance vector — is specified in <doc:WireProtocol>.

## Topics

### Wire protocol

- <doc:WireProtocol>

### Constants and endpoints

- ``MMWireInfo``
- ``MMEndpoint``

### MessagePack coding

- ``MMPackEncoder``
- ``MMPackDecoder``
- ``MMPackExtValue``

### Framing

- ``MMFrameDecoder``
- ``MMFrameEncoder``

### Envelope

- ``MMEnvelope``
- ``MMErrorObject``

### Hello preamble

- ``MMHello``

### Errors

- ``MMWireError``
- ``MMErrorCode``

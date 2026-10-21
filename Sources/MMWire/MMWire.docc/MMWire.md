# ``MMWire``

The wire layer: MessagePack coding over `ByteBuffer`, length-prefix framing, the RPC envelope, and the hello preamble.

## Overview

MMWire implements the lowest layers of the matter-in-motion protocol. It depends only on NIOCore and MMSchema (for the VPTS codec of the wire time kinds).

- **Framing**: `[u32 LE length][payload]` frames, through ``MMFrameDecoder`` and ``MMFrameEncoder``. The length counts only the payload. The decoder checks the size limit (default 16 MiB, see ``MMWireInfo``) before it stores any body byte.
- **Hello preamble**: ``MMHello``, a fixed 15-byte structure (magic `MM`, protocol version, schema fingerprint, capability bitset). Each side sends it as its first frame.
- **Envelope**: ``MMEnvelope``, tagged MessagePack arrays with kinds 0 to 6: terminal, open, credit, item, END, STOP, and CANCEL. Params, results, and stream items stay raw `ByteBuffer` slices until a typed layer decodes them.

``MMPackEncoder`` and ``MMPackDecoder`` code typed payloads:

- Structs encode as MessagePack maps with integer keys.
- The decoder skips unknown keys.
- `ByteBuffer`-typed fields get zero-copy bin/str slices.
- The wire time kinds (`MMDate`, `MMDateTime`, `MMTimestamp` from MMSchema) are also special-cased. They travel as MessagePack bin holding a VPTS encoding (<doc:VPTS>), never as their ISO-string `Codable` form.

Below the coders, the MessagePack value layer is available as the `readMessagePack*` and `writeMessagePack*` method families on `ByteBuffer`:

- readers for every format family
- writers that always produce the smallest correct representation
- `skipMessagePackValue(maxDepth:)`, a structural skip
- `readMessagePackRawValueSlice(maxDepth:)`, for zero-copy raw value slices

They extend a NIOCore type, so the reference lists them under `ByteBuffer` extensions, not below.

Failures return a `Result` with one typed error, ``MMWireError``. ``MMErrorCode`` defines the well-known RPC error codes. Codes 1 to 63 are reserved for the protocol. Applications use 64 and above.

<doc:WireProtocol> specifies the byte-level contract: every frame, envelope kind, ACL rule, fingerprint step, and pinned conformance vector.

## Topics

### Wire protocol

- <doc:WireProtocol>
- <doc:VPTS>

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
- ``MMError``

### Hello preamble

- ``MMHello``

### Errors

- ``MMWireError``
- ``MMErrorCode``

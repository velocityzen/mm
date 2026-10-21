# matter-in-motion wire protocol, version 1

This is the normative specification of the matter-in-motion binary RPC protocol. It is implementation-independent: an engineer must be able to build an interoperable client or server in any language from this document alone.

MUST, MUST NOT, SHOULD, and MAY are used as defined in RFC 2119. Hex strings are lowercase, in wire byte order, and have no separators except spaces for readability. Every worked example is a pinned conformance vector from the reference implementation's test suite, or is cross-checked against it (see the appendix).

## 1. Overview and layering

The protocol runs over any reliable, ordered byte stream. The primary transport is Unix domain sockets. TCP is supported for trusted networks. Layers, bottom to top:

1. **Framing**: `[u32 LE length][payload]` length-prefixed frames.
2. **Hello preamble**: a fixed 15-byte binary structure, the first frame each side sends.
3. **Envelope**: tagged MessagePack arrays of seven kinds, tags 0 to 6 (section 4).
4. **Payloads**: MessagePack values in the envelope's raw slots, using the struct conventions of section 5.

Byte order: every raw integer that this protocol's own layers write (frame length prefix, hello fields, fingerprint canonical encoding) is **little-endian**. MessagePack values are big-endian internally, as the MessagePack specification defines. This protocol does not change that.

The wire protocol version is a single `u8`, currently **1**. It is independent of any package or library version.

## 2. Framing

A frame is:

```
+-------------------+------------------------+
| length: u32 LE    | payload: length bytes  |
+-------------------+------------------------+
```

- The length prefix counts **payload bytes only**, not the 4 prefix bytes.
- Zero-length frames are legal at the framing layer and produce an empty payload. The framing layer passes them up. Upper layers reject them, because no valid hello or envelope is zero-length.
- The maximum payload length defaults to **16 MiB (16,777,216 bytes)** and is configurable per endpoint. An endpoint applies its cap in both directions. The two endpoints of a connection are expected to have compatible caps. Version 1 has no hello field or capability bit that advertises the cap. So a sender MUST assume the peer uses the default, unless it knows otherwise out of band, and endpoints must raise the cap on both sides together. (A future version may reserve a hello field or capability bit for this.)

**Cap semantics (normative).** A receiver MUST check the length prefix against its cap as soon as the 4 prefix bytes are readable, before it waits for, buffers, or consumes any body bytes. A length above the cap is a **fatal protocol violation: the receiver fails the connection**. There is no error response, no resynchronization, and no skipping. A sender MUST NOT emit a frame whose payload exceeds its cap. (This also guarantees that the length fits in the `u32` prefix.)

A stream that ends mid-frame (a partial length prefix or partial body at EOF) is a truncation error. Complete frames received before the truncated part are still valid and MUST be delivered upward.

### 2.1 Worked examples

Payload `2a` (one byte):

```
01 00 00 00 2a
└─ length=1 ─┘└ payload
```

Empty payload: `00000000`. Payload `01020304` (4 bytes): `0400000001020304`.

A frame with the request envelope from section 4.1 (payload `950101a470696e67a3626f7890`, 13 bytes):

```
0d 00 00 00 95 01 01 a4 70 69 6e 67 a3 62 6f 78 90
```

## 3. Connection preamble (hello)

The first frame each side sends on a new connection MUST be a hello. Both sides send one. A side does not need to wait for the peer's hello before it sends its own, so the exchange may be concurrent. After its hello, a side sends only envelopes (section 4).

The hello payload is a fixed **15-byte** binary layout. It is not MessagePack, so it can be parsed before any coder state exists:

```
offset  0         1         2         3 .. 10                     11 .. 14
       +---------+---------+---------+------------------------------+---------------------+
       | 0x4d    | 0x4d    | version | schemaFingerprint            | capabilities        |
       | 'M'     | 'M'     | u8      | u64 little-endian            | u32 little-endian   |
       +---------+---------+---------+------------------------------+---------------------+
```

- **Magic** (offsets 0 to 1): `4d 4d` (ASCII `MM`). Any other value is a fatal `badMagic` error, and the connection is failed.
- **protocolVersion** (offset 2): the highest protocol version the sender supports. Currently 1.
- **schemaFingerprint** (offsets 3 to 10): the sender's 8-byte schema fingerprint (section 9) as a little-endian `u64`. A client with no schema of its own sends the fingerprint of the schema it expects, or 0 if it has none.
- **capabilities** (offsets 11 to 14): a little-endian `u32` bitset. **Version 1 defines no capability bits, so senders MUST send 0.** Receivers MUST ignore bits they do not recognize.

**Forward compatibility.** A receiver MUST parse exactly the first 15 bytes of the hello frame and ignore any trailing bytes. A future version can then append hello fields without breaking older peers.

**Short hellos are fatal.** A hello payload shorter than 15 bytes is a fatal `truncated` error. It is treated exactly like a truncated stream (sections 2 and 10): the connection is failed. Error precedence:

- Fewer than 2 readable bytes: `truncated`.
- Both magic bytes readable and wrong: `badMagic`, even if the rest of the layout is missing.
- Correct magic, fewer than 15 bytes in total: `truncated`.

**Version negotiation is min-wins.** The effective version of the connection is `min(local version, peer version)`. A peer that cannot operate at that version closes the connection. Otherwise both sides use the effective version. Because the exchange may be concurrent, a side may send envelopes before it has processed the peer's hello, and so before it knows the effective version. Such envelopes MUST be valid at the sender's lowest supported version (in version 1, that is version 1). A sender that needs features of a higher version MUST wait for the peer's hello before its first envelope.

**Fingerprint mismatch means discovery, never disconnection.** If the fingerprints differ, the connection stays open, and the client SHOULD call schema discovery (`server.schema`, section 8.1) and adapt. A mismatch only signals that the method set changed. Implementations MUST NOT close a connection because the fingerprints differ.

### 3.1 Worked example

Hello with version 1, fingerprint `0x0123456789abcdef`, capabilities `0xdeadbeef`. The capabilities are nonzero only to show byte order. A conforming v1 sender sends 0, and a receiver ignores unknown bits.

```
4d 4d 01 ef cd ab 89 67 45 23 01 ef be ad de
│M │M │v1│←──── u64 LE fingerprint ────→│←u32 LE→│
```

The bytes are reversed (little-endian): fingerprint `0x0123456789abcdef` is `ef cd ab 89 67 45 23 01`, and capabilities `0xdeadbeef` is `ef be ad de`. The all-zero hello (version 0, fingerprint 0, capabilities 0) is `4d4d` followed by thirteen `00` bytes.

Inside a frame, this hello is `0f000000 4d4d01efcdab8967452301efbeadde`.

## 4. Envelope

Every frame after the hello contains exactly one envelope: a MessagePack array whose first element is an integer **kind tag**. The frame payload MUST contain only the envelope. Trailing bytes after the envelope array are a decode error.

| Kind | Wire form | Meaning | Array arity |
|---|---|---|---|
| 0 | `[0, msgid, error, result]` | terminal response (server → client); `error` nil = graceful | exactly 4 |
| 1 | `[1, msgid, method, entity, params]` | open a call (client → server); `entity` is the target's dotted path, `""` = root | 5, or 6 with the reserved options element |
| 2 | `[2, msgid, credits]` | credit grant (stream flow control, either direction) | exactly 3 |
| 3 | `[3, msgid, seq, item]` | stream item | exactly 4 |
| 4 | `[4, msgid, 0]` | END: the sender finishes its own stream direction | 3 or more; the third element and beyond are reserved and skipped |
| 5 | `[5, msgid, code]` | STOP: asks the peer to finish its stream direction; code 0 = graceful, others reserved | exactly 3 |
| 6 | `[6, msgid]` | CANCEL: the client aborts the whole call | 2 or more; elements after msgid are skipped |

Kinds 2 to 6 are the stream frames. Section 4.2 specifies credit accounting, per-call stream state, and the termination matrix. There is no notification kind: **tag 7 is reserved**. (Server push is an ordinary method with a response stream, section 4.2.)

Element semantics:

- **Kind tag**: a MessagePack integer from 0 to 6. Any other value (7, a larger integer, or a negative integer) is an `unknownEnvelope` error, which fails the connection like any malformed envelope (below).
- **Arity tolerance.** Arity is exact per kind, with three required tolerances for forward evolution. In each case the extra elements are skipped structurally and never interpreted:
  - Kind 1 accepts arity 6. The sixth element is reserved for future call options.
  - Kind 4 accepts any arity ≥ 3. The third element is reserved (senders MUST write the integer 0). It and all later elements are skipped.
  - Kind 6 accepts any arity ≥ 2. Elements after msgid are skipped.

  The rest of the envelope is fixed. All other evolution happens inside payloads and the error object.
- **msgid**: an unsigned integer that MUST fit in `u32`. The caller that opens the call assigns it. It is scoped **per connection** and **wraps around** modulo 2³². A caller MUST NOT reuse a msgid while a call with that msgid still awaits its terminal response on the same connection (after a wrap, the caller must avoid live collisions). The integer representability rule of section 5.4 applies: a value that `u32` cannot represent exactly (wider than `u32`, or a negative MessagePack integer) is a decode error (`numberOutOfRange`). An oversized encoding of a representable value is accepted (for example, msgid 1 as `cc 01`).
- **method**: a MessagePack string (for example, `journal.append`, `server.schema`). Method names are dotted paths, like entity names.
- **entity**: a MessagePack string with the dotted path of the target entity (`""` = root). It is **authorization metadata, not payload**. The server parses and authorizes it (section 7) before it interprets the params slot. A string that is not a valid entity path is answered with `malformedParams` (code 3).
- **params**, **result**, **item**: **raw payload slots**. Each holds exactly one complete MessagePack value of any type, which the envelope layer does not interpret. A receiver finds the slot's byte extent by walking the value structurally (within the nesting cap, section 5.6), without materializing it. The payload is decoded later, after dispatch and authorization, against the concrete request, response, or element type. A sender MUST put exactly one complete MessagePack value in each raw slot, no more and no fewer bytes.
- **error**: `nil` (success) or an error object (section 6). In a response, the sender MUST encode `nil` in the slot it does not use: `error` is `nil` on success, and `result` SHOULD be `nil` on failure. A receiver treats any non-nil `error` as failure. `nil` in both slots is a valid void success.
- **credits**: an additive credit grant for one stream direction. **seq**: a per-direction item sequence number, starting at 0. **code** (in STOP): 0 is the only defined (graceful) value, and nonzero values are reserved. All three are `u32` slots with the same representability rule as msgid.

A call opened by a request (kind 1) ends with exactly one terminal response (kind 0) with the same msgid, on the same connection. This applies to unary and streaming calls (section 4.2). The protocol has no unsolicited frame without a msgid. Every frame after the hello opens a call, refers to an open call's msgid, or is the terminal that retires it.

An unknown method in a request MUST produce an error response (code 1, section 6). It is never silently dropped.

**Malformed envelopes are fatal.** A post-hello frame is malformed if its payload does not decode as exactly one well-formed envelope:

- a payload that is not an array;
- an arity outside its kind's tolerance;
- an unknown kind tag (7 or beyond);
- a msgid or method that cannot be decoded;
- trailing bytes after the envelope array;
- a `0xc1` byte or a nesting-cap violation during the raw-slot walk;
- a zero-length payload.

The receiver fails the connection (section 10). No error response is possible (the msgid may be unparseable), and there is no per-frame recovery. These well-formed cases are *not* fatal:

- an unknown *method* in a request: answered with a code-1 error;
- a stream frame (kinds 2 to 6) for an unknown or retired msgid: dropped and counted (section 4.2);
- a stream *contract* violation on a live call: answered with a code-6 terminal (section 4.2).

**Receiver rules for stale correlation (normative).** These frames are dropped, never fatal:

- a response (kind 0) whose msgid matches no outstanding call;
- a second response with an already-retired msgid;
- any response that a server receives (the server treats it as a peer protocol error);
- a stream frame (kinds 2 to 6) whose msgid has no live stream state (never opened, or retired by its terminal). It is also counted.

The last rule makes late items that arrive while a call ends tolerated, not a violation (see the state machine in section 4.2).

### 4.1 Worked examples

All of these are pinned test vectors.

Request `[1, 1, "ping", "box", []]`: msgid 1, method `ping`, entity `box`, params the empty array:

```
95 01 01 a4 70 69 6e 67 a3 62 6f 78 90
│  │  │  └ fixstr(4) "ping" │           └ params: fixarray(0)
│  │  └ msgid 1             └ entity: fixstr(3) "box"
│  └ kind 1 (request)
└ fixarray(5)
```

Hex: `950101a470696e67a3626f7890`.

Success response `[0, 5, nil, true]`: `940005c0c3` (`c0` = nil error, `c3` = result `true`).

Void success response `[0, 9, nil, nil]`: `940009c0c0`.

Reserved tag rejected: `[7, "evt", {1: 2}]` → `9307a3657674810102`. This is a well-formed MessagePack array, but tag 7 is reserved. It decodes to an `unknownEnvelope` error, and the connection is failed. (Tag 7 was the notification kind in a pre-release design.)

Error response `[0, 7, [-32601, "no"], nil]`: `94000792d180a7a26e6fc0`. The error object is `92 d180a7 a26e6f` (array(2), int16 −32601, fixstr "no"). The result slot is `c0`.

Error response with error payload `[0, 7, [1, "e", [1, 2]], nil]`: `9400079301a165920102c0`.

msgid extremes: msgid 0 → `950100a16da0c0` (request, method "m", root entity, params nil). msgid 4294967295 → `9501ceffffffffa16da090` (`ce ffffffff` = uint32 max).

Stream kinds: credit `[2, 1, 8]` → `93020108`; item `[3, 1, 0, "x"]` → `94030100a178` (seq 0, item fixstr "x"); END `[4, 1, 0]` → `93040100`; STOP `[5, 1, 0]` → `93050100`; CANCEL `[6, 1]` → `920601`.

Arity tolerance:

- `[1, 1, "m", "", nil, {}]` (request with a reserved sixth element) → `960101a16da0c080` decodes exactly as `[1, 1, "m", "", nil]`.
- `[4, 1, 99]` (END with a nonzero reserved element) → `93040163` decodes as END msgid 1.
- `[6, 1, 0]` (CANCEL with an extra element) → `93060100` decodes as CANCEL msgid 1.

### 4.2 Streaming

A method may have a **request stream** (elements the client sends after opening), a **response stream** (elements the server sends before its terminal), both, or neither (a unary call). Both streams belong to the one call opened by kind 1 and use its msgid. The schema (section 8.1) models a method in four parts: opening request, request stream, response stream, terminal response. This section is the wire and state contract between the peers.

**One authorization, at open.** Authorization runs exactly once, on the entity slot of the open envelope (kind 1: parse, traversal, target check, section 7), before any stream element is sent. Stream items are **never authorized individually**. An ACL change does not affect an in-flight stream.

**The terminal is the sole retirement.** Every call ends with exactly one terminal response (kind 0, section 4). The server always sends it, and it is always the last frame for that msgid. A nil-error terminal is the graceful outcome, and an error terminal is the failed outcome. The terminal is how the client tells them apart, and it is the only frame that retires the msgid.

#### Stream frames

- **item** `[3, msgid, seq, item]`: one stream element. `seq` is a per-direction `u32` starting at 0. Client request items and server response items have independent sequences. `item` is a raw value slot (section 4), decoded later against the declared element type. A `seq` that skips a value is a violation (below).
- **credit** `[2, msgid, credits]`: an additive credit grant. The side that *receives* items on a direction sends it to add to the sender's window (below).
- **END** `[4, msgid, 0]`: the item sender gracefully finishes **its own** direction. Client END ends the request stream. Server END ends the response stream (the terminal may follow later while the server finalizes). On END, the receiver's element sequence finishes cleanly.
- **STOP** `[5, msgid, code]`: the item receiver asks the item sender to gracefully finish **the peer's** direction (`code` 0 = graceful, the only defined value). STOP is **advisory**: items already in flight are accepted, never a violation. The sender's next send reports a typed *peer-stopped* outcome, which is a graceful signal, not an error. The call continues to its terminal.
- **CANCEL** `[6, msgid]`: client to server only. The client abandons the whole call. The server cancels the handler task and still sends the terminal (error code 7, `cancelled`) to retire the msgid. When the server itself exits abnormally, it sends an error terminal. It never needs a cancel frame.

#### State machine

Each of the two item directions of a call is a small state machine, and both peers track the same state. A direction moves `open → ended` exactly once: through its own END, through a STOP that the sender acknowledges by ending, or through the terminal. The terminal retires the whole msgid from any state.

**Late items are tolerated, not violations.** An item that arrives after its direction ended is dropped and counted. This covers items after the sender's own END, after the server terminated the request source, or racing CANCEL or the terminal. The section 4 receiver rules drop stream frames for unknown or retired msgids for the same reason.

The **four true violations** are:

- an item on a direction that the method did not declare;
- a `seq` gap;
- a credit overrun on a live source (an item that arrives with zero credit);
- a request item that fails to decode against the element type.

The server answers them with a code-6 (`streamViolation`) terminal when it can still answer. Broken framing (a malformed envelope) is still connection-fatal (section 4).

#### Termination matrix

How each ending appears, symmetric between the peers. Implementations SHOULD present these outcomes. The wire contract is the frames above.

| Event | Frames | Item-sending side observes | Item-receiving side observes |
|---|---|---|---|
| Graceful finish of a direction | END | — (it sent END) | element sequence finishes cleanly |
| Receiver has seen enough | STOP → sender ENDs | next send reports *peer-stopped* (graceful); call runs to terminal | — (it sent STOP) |
| Server done, success | server END + nil-error terminal | — | response sequence finishes; terminal is success |
| Failure | error terminal | — | response sequence finishes; terminal is the error |
| Client abandons the call | CANCEL → code-7 terminal | server handler task cancelled; runtime sends code-7 terminal | client APIs resolve as *cancelled* locally |
| Connection death | — (transport) | all live streams and calls fail with a transport error | same |

Connection death is the only involuntary ending. Every live stream and call on both sides fails with a transport error, which is always distinguishable from every graceful ending.

#### Credit flow control

Flow control is **credit-based, per stream direction, counted in items**. A new direction starts with an **initial window of 8 items**. This is a spec constant that both peers know, never sent as a frame. The sender MAY send that many items before it receives any grant. Each item spends one credit. At **zero credit the sender MUST suspend** until a credit frame arrives. So backpressure reaches the producing task, and per-stream buffering is bounded by window × frame cap. There is **no head-of-line blocking between streams**: a stalled stream blocks only itself, not other calls on the same connection.

The **receiver** grants more credit as its consumer reads items, in batches at a watermark, not per item. The reference implementation grants after its consumer reads at least half the window (4 items) since the last grant, and one additive frame refills the sender's window to 8. Granting only the missing amount keeps the sender's credit ≤ the initial window, so the overrun check stays exact. The batching schedule is receiver policy. The protocol fixes only that a grant is additive and per-direction, and that a conforming sender never exceeds its granted window.

#### Stream worked examples

All pinned test vectors. In a follow-style server stream (msgid 1), the server sends items and the client grants credit:

- credit grant of 8: `[2, 1, 8]` → `93020108`
- item at seq 0, payload `"x"`: `[3, 1, 0, "x"]` → `94030100a178`
- END of a direction: `[4, 1, 0]` → `93040100`
- STOP (graceful, code 0): `[5, 1, 0]` → `93050100`
- CANCEL of the call: `[6, 1]` → `920601`

## 5. MessagePack usage conventions

Payloads (the contents of the `params`, `result`, and error payload slots) are MessagePack values that follow these conventions. They are the protocol's schema-evolution contract.

### 5.1 Structs are int-keyed maps

A struct encodes as a MessagePack map with integer keys, assigned statically per field (in the reference implementation, `CodingKeys: Int` raw values). The key space is **signed 64-bit** (`i64`, as in the fingerprint's canonical encoding, section 9.1). Negative keys are legal, but schemas usually use small non-negative keys. A wire integer key that does not fit in `i64` (a `uint64` above `2^63 − 1`) never matches a field and is skipped like any unknown key (section 5.2). Int-keyed structs never send field names. Example: fields `id = key 1` and `name = key 2`, value `{id: 42, name: "mm"}`:

```
82 01 2a 02 a2 6d 6d
│  │  │  │  └ fixstr(2) "mm"
│  │  │  └ key 2
│  │  └ 42
│  └ key 1
└ fixmap(2)
```

String keys are supported as a fallback: a field without an integer key encodes under its name as a MessagePack string key. One map may mix integer and string keys. Lookup rules (normative, in wire terms):

- A wire **integer** key `k` matches a field with integer key `k`. It also matches a string-named entry (such as a dictionary key) whose name is exactly the canonical decimal form of `k` (`"5"`, never `"05"`).
- A wire **string** key matches the field or entry with exactly that name. As a decode-side fallback, this includes a field that also has an integer key.
- A wire string key is never parsed into an integer: wire string `"5"` does not match integer field key `5`. Implementations MUST NOT let a string-derived key (such as dictionary key `"05"`) alias a different integer key `5`.

### 5.2 Unknown keys are skipped

A decoder MUST skip map entries with unrecognized keys **structurally**: it walks the value without materializing it, for any MessagePack family at any depth (str, bin, arrays, maps, ext, any width). This applies at every nesting level. Keys that can never match a field are also skipped with their values, not treated as errors: integers outside the `i64` key space (section 5.1), strings with invalid UTF-8, and keys that are neither integers nor strings.

### 5.3 Evolution contract: new fields must be optional

To evolve a struct, add new fields with new keys and make them **optional**. A missing optional field decodes as absent (nil), and so does an explicit MessagePack `nil`. A missing **non-optional** field is a decode error (`keyNotFound`). Never reuse or renumber keys. Never change the type of an existing field.

**Duplicate keys: the first occurrence wins.** A decoder keeps the first value for a key and skips later duplicates.

### 5.4 Non-canonical decode tolerance

Encoders SHOULD write the minimal canonical encoding: the smallest integer width for the value, fixstr/fixmap/fixarray when the length allows, and `bin` for binary. Decoders MUST accept non-canonical input:

- An integer of any width and signedness decodes into any target type that can represent the value exactly (`cc 05`, `d3 0000000000000005`, and `05` all decode as 5). A value the target cannot represent is `numberOutOfRange`.
- `float64` decodes into a 32-bit float target when exactly representable. **Any** `float64` NaN decodes into a float target as a NaN. NaN is never rejected as unrepresentable, and its payload bits are not preserved.
- Oversized length encodings (`str8` for a fixstr-sized string, `array16` for one element, `map32` for one entry, and so on) decode normally.
- A `str` value decodes into a binary target as its UTF-8 bytes (some encoders send raw bytes as str).

The reserved byte `0xc1` is invalid in every position and is a decode error.

### 5.5 Binary values

Raw byte payloads encode as MessagePack `bin`. Decoders SHOULD expose them without copying where the host language allows.

### 5.6 Nesting depth cap (receiver limit)

Receivers enforce a container-nesting cap, default **128** levels. It applies to full decoding and to the structural walks that find raw-slot extents (section 4) and skip unknown values. Exceeding it is a decode error (`nestingTooDeep`), not a crash. The cap is a **receiver limit, not a wire grammar rule**: endpoints MAY raise it on both sides together, and a sender must assume the default unless it knows otherwise. Depth counting (normative):

- A top-level scalar is at depth 0. Each container entered adds 1.
- The cap applies per payload value. Each raw slot is walked with its own counter.
- The envelope array does not count toward a slot's depth.

So a value nested exactly 128 container levels deep passes the default cap.

## 6. Error objects

A non-nil `error` slot of a response is a MessagePack array:

```
[code, message]              — 2 elements
[code, message, payload]     — 3 elements
```

- **code**: a MessagePack integer (any width, signed values allowed).
- **message**: a human-readable MessagePack string.
- **payload** (optional): one complete MessagePack value, not interpreted (a raw slot, like `params`). An explicit `nil` decodes as an absent payload.

**Trailing-element tolerance (normative).** Unlike the envelope, the error object accepts extra elements. Fewer than 2 elements is an error, but a decoder MUST accept and structurally skip any elements after the third. `[1, "e", nil, 99, "ex"]` (`9501a165c063a26578`) decodes as code 1, message "e", no payload.

### 6.1 Protocol error codes

Codes **1 to 63 are reserved for the protocol**. Applications MUST use codes **>= 64**. (Negative codes are representable and outside the reserved range, but the application space is defined as >= 64.) The v1 reserved codes:

| Code | Name | Meaning |
|---|---|---|
| 1 | unknownMethod | The request named a method that the router has no route for. |
| 2 | permissionDenied | The peer's identity does not grant the access class the method requires on the target entity (or on one of its ancestors, for traversal). |
| 3 | malformedParams | The params payload failed to decode as the method's request type. |
| 4 | tooManyInFlight | The connection exceeded its in-flight request cap. |
| 5 | internalError | The handler failed, and it is not the caller's fault. |
| 6 | streamViolation | The peer broke the stream contract: an item on an undeclared stream, a seq gap, or a credit overrun. |
| 7 | cancelled | Terminal response that acknowledges a client CANCEL: the call was aborted. |

**Existence is never leaked (normative).** There is no "entity not found" code. A request for an entity with no ACL record, including an entity that does not exist, is denied with `permissionDenied` (code 2), exactly as if an ACL denied it. A server MUST NOT reveal through its choice of error whether an entity exists. (A failure of the ACL store itself is `internalError`, code 5.)

**Unknown-case decoding rule (applies to every wire-decoded enum in this protocol).** Decoding a code, or any enumerated wire value (TypeSchema tags, access-mode bits, capability bits), MUST NOT fail on an unrecognized value. An unrecognized value maps to an explicit "unknown" case that carries the raw value. Implementations MUST NOT switch exhaustively over wire enums without a default. Future versions may add codes and tags, and old peers must handle them without failing.

Worked vectors: `92d180a7a26e6f` = `[-32601, "no"]` (no payload); `9301a165c0` = `[1, "e", nil]` (explicit nil payload, decodes as absent).

## 7. Entities and authorization

### 7.1 Entity names

An entity name is a dotted path (`domain.area.name`) that identifies a node in the entity tree.

Grammar: one or more **segments** joined by single dots (`.`, 0x2e). Each segment is non-empty and uses only ASCII `a-z`, `0-9`, `_`, `-`. Names are lowercase only, canonical, and never case-folded. A name has no leading dot, no trailing dot, and no empty segment (`..` is invalid).

**Root.** The empty string is reserved for **root**, which means "the whole entity tree". Root never names a concrete entity. It exists for discovery-style requests. It encodes as the empty string and has no parent, no ancestors, and no ACL. The traversal rule (7.4) never checks an ACL for root. Every non-root name is a descendant of root. Root is a descendant of nothing, including itself.

Descendants are strict and follow dot boundaries: `a.b.c` is a descendant of `a.b` and `a`; `a.bc` is **not** a descendant of `a.b`; nothing is a descendant of itself. The ancestors of `a.b.c` are `[a, a.b]`, outermost first. A single-segment name and root have no ancestors.

On the wire, an entity name is a plain MessagePack string.

### 7.2 The entity-in-the-envelope convention

**The call's target entity is envelope metadata, never payload.** It is the dotted-path string in the open frame's entity slot (section 4). The server parses it and runs the full authorization (traversal and target check) **before it interprets any byte of the params slot**. So the server never decodes an unauthorized peer's payload, which saves work and reduces the attack surface before authorization. As a result, request payloads are plain values, like responses and stream elements: fields are keyed from 0, with no reserved key. Any named type (a `reference`, section 8.3) can be a whole request payload without a special shape.

Worked example: a `server.schema` call scoped to entity `journal` puts `journal` in the envelope's entity slot. Its request payload is the empty map `{}` (`80`).

### 7.3 The rwx / ugo ACL model

Each entity has an ACL: an owning uid, an owning gid, and nine permission bits, exactly as in the POSIX filesystem model.

Access bits (per class): **execute/traverse = 1, write/mutate = 2, read/observe = 4**. On the wire, an access mode is its raw `u8`. Unknown high bits are preserved on decode, never rejected (the unknown-case rule of section 6).

Mode layout: `mode` is a `u16` whose low 9 bits are `(owner_bits << 6) | (group_bits << 3) | other_bits`, usually written in octal (`0o750` = owner rwx, group r-x, other ---). The default creation mode for new entities is **0o750**, configurable per server like a umask.

Each method declares the access class that its verb requires on the target entity (for example, `journal.append` requires write and `server.schema` requires read).

**Class selection.** The peer is classified once, in this order:

1. `peer.uid == acl.owner` → **owner** class,
2. else `peer.gid == acl.group` or `acl.group ∈ peer.supplementaryGroups` → **group** class,
3. else → **other** class.

**First-matching-class-wins (normative).** Only the selected class's bits decide, and all requested bits must be present in them. A denial in the matching class is final. Later classes are **never** checked, even when they would grant the access. An empty request (no bits) is always permitted.

Truth table for `EntityACL(owner: 1000, group: 100, mode: 0o750)`:

| Peer | Class | read | write | execute |
|---|---|---|---|---|
| uid 1000, gid 100 | owner | yes | yes | yes |
| uid 2000, gid 100 | group | yes | **no** | yes |
| uid 2000, gid 9, supp. groups [100] | group | yes | **no** | yes |
| uid 2000, gid 9 | other | no | no | no |

**Owner-denied-other-granted asymmetry.** Mode `0o007` (owner ---, group ---, other rwx), owner 1000, group 100:

| Peer | Class | read | write | execute |
|---|---|---|---|---|
| uid 1000 (the owner) | owner | **no** | **no** | **no** |
| uid 2000, gid 9 (a stranger) | other | yes | yes | yes |

The owner matches the owner class, whose bits are 000. The other class's rwx is never checked. The same applies one class down: with mode `0o707`, a group member is denied what strangers are granted.

### 7.4 Traversal: x on every ancestor

Before the method's own access check, the peer must hold **execute (x)** on **every ancestor prefix** of the target entity. For target `a.b.c`, the peer needs x on `a` and on `a.b` (each checked against that ancestor's own ACL with the first-matching-class-wins rule), plus the method's declared access on `a.b.c`. Root is excluded because it has no ACL. A traversal failure is `permissionDenied` (code 2), indistinguishable on the wire from a target check failure.

### 7.5 Identity: kernel-attested, never wire-claimed

The server derives peer identity (uid, primary gid, supplementary groups) from the transport: kernel peer credentials on Unix domain sockets (`SO_PEERCRED` / `LOCAL_PEERCRED`). It reads them once at accept time, and they stay fixed for the connection's lifetime. **Identity never travels on the wire and is never claimed by the client.** The protocol has no field for it, by design. The peer's pid is diagnostic only, never an authorization input.

- **uid 0 is not special.** The protocol has no superuser override. Administrative recovery uses the daemon's own uid.
- **Anonymous TCP peers.** Raw TCP connections have no kernel credentials. In v1 they get the anonymous identity (`uid = uid_t.max`, `gid = gid_t.max`, no supplementary groups). These values get no special handling. No real entity should be owned by them, so in practice anonymous peers match the **other** class, and the other bits decide their access. Do not create ACLs owned by `uid_t.max`.

## 8. Schema discovery

Every server has two builtin methods. Both declare **read** on their target entity and follow the traversal rule of section 7.4 like any other method. A **root** target has no ACL and no ancestors (section 7.1), so it skips both checks and always reaches the handler. Then `server.schema` filters its response by the peer's traversal rights for each method (section 8.1), and `server.entity` denies root inside its handler by the no-ACL rule (section 8.2).

### 8.1 `server.schema`

Request (`SchemaRequest`): the empty map `{}`. The discovery **scope** is the call's envelope entity: a concrete entity limits it to that subtree, and root (the empty path) covers the whole tree. Response (`SchemaResponse`):

| Key | Field | Type |
|---|---|---|
| 0 | fingerprint | u64: the fingerprint of the server's **complete** method set and type table (not of the filtered lists below), so a client can compare it with the hello fingerprint |
| 1 | methods | array of MethodSignature |
| 2 | types | array of TypeDefinition, **optional**: absent from pre-types servers, decodes as empty |
| 3 | namespaces | array of NamespaceSignature, **optional**: absent from servers that predate the key (decodes as empty), and absent when no served namespace declared a description |

The methods list is scoped by the request's entity and filtered by the requesting peer's traversal rights, so it shows what that peer can reach. The types list contains the named-type definitions **transitively reachable** from the served methods' schemas (including references inside the definitions). Every `reference` in the response resolves within the response.

`NamespaceSignature` is an int-keyed struct that documents one namespace: key 0 = `name` (string, the namespace prefix entity, for example `journal`), key 1 = `description` (string). Only namespaces that declared a description have entries. Entries are sorted by name and filtered with the methods: a namespace is listed if and only if at least one of its methods is listed. Like every description, this list is documentation only (section 9).

**Scope.** A method's **method-name prefix** is its name without the final verb segment (`journal.append` → `journal`; a single-segment name → root), read as an entity name. A non-root request entity limits the list to methods whose prefix equals it or is a descendant of it. Root selects every method. A scope that matches nothing gives an empty `methods` list, not an error.

**Filter predicate (normative).** A method is listed if and only if the requesting peer holds **execute** on the method's prefix entity and on every ancestor of that prefix. Each is checked against its own ACL with the first-matching-class-wins rule (section 7.3). A missing ACL record anywhere on the chain excludes the method. A single-segment method name (a namespace **root call**, where the method is the namespace itself, for example `search`) is its own prefix, and is filtered by execute on that entity like its dotted siblings. The filter does not check **read** on the prefix or the method's own declared access class.

`MethodSignature` is an int-keyed struct. Keys are grouped: single digits for the method itself, the 10s for the request direction, the 20s for the response direction. Every slot is directly followed by its own description slot:

| Key | Field | Type |
|---|---|---|
| 0 | name | string (for example, `journal.append`) |
| 1 | access | u8: raw access bits (section 7.3); unknown bits preserved |
| 2 | description | string, **optional**: human-readable method documentation |
| 10 | request | TypeSchema: opening-request shape |
| 11 | requestDescription | string, **optional** |
| 12 | requestStream | TypeSchema, **optional**: element shape the client may stream (present only for methods with a request stream) |
| 13 | requestStreamDescription | string, **optional** |
| 20 | response | TypeSchema: terminal-response shape |
| 21 | responseDescription | string, **optional** |
| 22 | responseStream | TypeSchema, **optional**: element shape the server may stream before the terminal (present only for methods with a response stream) |
| 23 | responseStreamDescription | string, **optional** |

An unset optional slot is absent (its key is omitted). Readers skip unknown keys, per the evolution rule. A method may have any combination of the four parts (request, response, requestStream, responseStream). The five description slots (keys 2, 11, 13, 21, 23) are documentation only: discovery serves them, but they are **never** hashed into the fingerprint and never used in compatibility comparisons. A documentation edit is not schema drift.

`TypeDefinition` is an int-keyed struct: the definition that a `reference` (section 8.3) resolves to. Names are **nominal**: the qualified name (`journal.Priority`) is part of the contract and is hashed into the fingerprint (section 9.1), so renaming a type is a schema change. Servers check at startup that every reference in their registered schemas resolves.

| Key | Field | Type |
|---|---|---|
| 0 | name | string, qualified (`<namespace>.<TypeName>`) |
| 1 | schema | TypeSchema: a `structure` or `enumeration` |
| 2 | description | string, **optional**; documentation only |

### 8.2 `server.entity`

Request (`StatRequest`): the empty map `{}`. The stat **target** is the call's envelope entity. Root has no ACL to report: a stat call with the empty string as envelope entity reaches the handler (section 8) but is denied with `permissionDenied` (code 2), by the same no-ACL rule as section 6.1. Response (`StatResponse`) is the target's ACL:

| Key | Field | Type |
|---|---|---|
| 0 | owner | u32 (uid) |
| 1 | group | u32 (gid) |
| 2 | mode | u16 (nine permission bits, section 7.3) |

Worked example: `StatResponse{owner: 1000, group: 100, mode: 0o750}` (0o750 = 488 = 0x1e8):

```
83 00 cd 03 e8 01 64 02 cd 01 e8
│  │  └ 1000 │  └ 100│  └ 488
│  └ key 0   └ key 1  └ key 2
└ fixmap(3)
```

Hex: `8300cd03e8016402cd01e8`.

### 8.3 TypeSchema wire encoding

A `TypeSchema` describes the wire shape of a value. It encodes as a map with integer keys:

- key **0**: the case **tag**, a `u8`;
- key **1**: the first payload: the wrapped schema for `optional`, the element schema for `array`, the **key** schema for `map`, the field list for `structure`;
- key **2**: the second payload: the **value** schema for `map`.

Tag table:

| Tag | Case | Payloads |
|---|---|---|
| 0 | bool | — |
| 1 | int | — (any signed width) |
| 2 | uint | — (any unsigned width) |
| 3 | float | — (32-bit) |
| 4 | double | — (64-bit) |
| 5 | string | — |
| 6 | bytes | — (MessagePack bin) |
| 7 | optional | key 1: wrapped schema |
| 8 | array | key 1: element schema |
| 9 | map | key 1: key schema; key 2: value schema |
| 10 | structure | key 1: array of Field |
| 11 | enumeration | key 1: array of EnumCase |
| 12 | reference | key 1: qualified type name (string) |
| 13 | date | — (VPTS binary, calendar-date precision; rules below) |
| 14 | datetime | — (VPTS binary, wall-clock precision, no offset; rules below) |
| 15 | timestamp | — (VPTS binary with offset, an absolute instant; rules below) |
| 255 | unknown | — |

**Calendar and clock values (tags 13 to 15).** All three encode as a MessagePack **bin** that holds one VPTS encoding (the variable-precision timestamp codec, specified in <doc:VPTS>). They are separate schema kinds, not bytes, because their meanings differ: a `date` has no time zone, a `datetime` is a floating wall-clock reading, and a `timestamp` is an absolute instant. Per-kind constraints on the VPTS component mask (normative):

- `date`: exactly YEAR+MONTH+DAY. No time components, no fraction, no offset.
- `datetime`: YEAR through SECOND, an optional FRACTION, no OFFSET. **Canonical emission** omits a zero fraction.
- `timestamp`: YEAR through SECOND, an optional FRACTION, OFFSET **required**. Canonical emission omits a zero fraction. Offset zero is `OFFSET = 0` (VPTS has no `Z`/`+00:00` distinction).

Value ranges:

- year 0 to 9999, proleptic Gregorian (leap years validated);
- hour 00 to 23, minute 00 to 59, second 00 to 60 (leap second allowed);
- fraction precision is nanoseconds. A receiver accepts the wide (attosecond) VPTS form only when the value is a whole number of nanoseconds;
- offset within ±18:00.

The VPTS **null** encoding (`0x00`) is never a value. Optionality uses MessagePack nil through the `optional` schema, and a null VPTS where a value is expected is a decode failure. A bin that violates the VPTS grammar or these per-kind constraints is a decode failure of its payload, answered like any malformed payload (`malformedParams`, code 3, for a request slot).

In **JSON projections** of wire values (discovery tooling, the CLI's parameter and output trees), the three kinds map to canonical ISO 8601 / RFC 3339 strings: `2026-07-21`, `2026-07-21T14:30:00.5`, `2026-07-21T14:30:00Z`. The fraction appears only when non-zero (1 to 9 digits, trailing zeros removed). `T` and `Z` are uppercase, and offset zero is `Z`. Parsers of this projection accept only two variations: lowercase `t`/`z`, and `±00:00` as an alias of `Z`. This string form never appears on the wire.

A `structure` lists its fields in **declaration order** (the order in which the type's decoder requests them). `Field` is an int-keyed struct: key 0 = `key` (the field's integer wire key, or nil/absent for string-keyed fields), key 1 = `name` (string), key 2 = `type` (TypeSchema), key 3 = `description` (string, **optional**, documentation only).

An `enumeration` is a closed set of **string-valued** cases. The wire value of an enum-typed field is the case name as a MessagePack string (fixed decision). Renaming a case breaks the wire. Reordering does not, but it changes the fingerprint, like field order. Decoders MUST map an unrecognized value to a local fallback case instead of failing (the wire-enum rule of section 6.1). `EnumCase` is an int-keyed struct: key 0 = `name` (string, the wire value), key 1 = `description` (string, **optional**). Cases appear in declaration order.

A `reference` names a `TypeDefinition` (section 8.1) served with the method list. Discovery responses are self-contained (every reference resolves within the response).

**Decoding TypeSchema never fails (normative).** A client that cannot decode the schema response cannot discover anything else. So a decoder MUST map anything unrecognized to `unknown` instead of failing: an unknown tag, a missing tag, a corrupt or missing payload, even a non-map value. Old peers therefore decode tags added in future versions as `unknown`.

Worked example: `optional(string)` = `{0: 7, 1: {0: 5}}`:

```
82 00 07 01 81 00 05
│  │  │  │  └ nested map {0: 5} = string
│  │  │  └ key 1 (first payload)
│  │  └ tag 7 (optional)
│  └ key 0
└ fixmap(2)
```

Hex: `82000701810005`. A bare `string` is `810005`.

## 9. Schema fingerprint

The 8-byte fingerprint in the hello is a stable, cross-platform hash of the server's method set **and named-type table**. The set includes the builtins `server.schema` and `server.entity` (section 8), fingerprinted like any application method (canonical signatures in section 9.5). Independent implementations MUST compute identical values for the same set of method signatures and type definitions. The fingerprint is **FNV-1a 64** over a canonical byte encoding of the sorted signatures, followed by the sorted type definitions.

**Descriptions are never hashed.** The canonical encoding includes none of: the five signature description slots (keys 2, 11, 13, 21, 23), field descriptions (Field key 3), enum-case descriptions, or definition descriptions. Documentation edits never change the fingerprint.

### 9.1 Canonical encoding

A simple tagged, length-prefixed byte encoding, intentionally **not** MessagePack. All integers are little-endian.

**string** := `u32 LE` byte count, then the UTF-8 bytes.

**signature** := name (string) ‖ access (`u8`, the raw rwx bits) ‖ request schema ‖ response schema ‖ *stream entries, emitted only when present*: `u8` tag `1` then the request-stream element schema; `u8` tag `2` then the response-stream element schema. A method with no streams emits neither entry, so a set of only unary methods hashes to the same value as before streaming was added (the pinned value of 9.4 is unchanged). The two different tags keep the request and response stream slots distinguishable.

**schema** := `u8` case tag (the same values as the wire tag table in 8.3: 0 bool, 1 int, 2 uint, 3 float, 4 double, 5 string, 6 bytes, 7 optional, 8 array, 9 map, 10 structure, 11 enumeration, 12 reference, 13 date, 14 datetime, 15 timestamp, 255 unknown), then payload:

- `optional` (7), `array` (8): the child schema.
- `map` (9): the key schema, then the value schema.
- `structure` (10): `u32 LE` field count, then for each field, in declaration order: `u8` key-presence flag (1 if the field has an integer key, else 0), `i64 LE` key when present, the field name (string), the field schema.
- `enumeration` (11): `u32 LE` case count, then for each case, in declaration order: the case name (string).
- `reference` (12): the qualified type name (string).
- all other tags: no payload.

**type definition** := `u8` tag `3` ‖ the qualified name (string) ‖ the definition's schema. Type-definition entries follow the signature stream (see 9.2). An empty type table emits nothing, so a fingerprint without types keeps its value from before types were added.

### 9.2 Sorting and hashing

1. Canonically encode each signature.
2. Sort the signatures **by name**, byte-wise over the name's UTF-8 bytes (lexicographic). Signatures with the same name (illegal in a router but representable) are ordered by byte-wise comparison of their full canonical encodings. This makes the sort a total order: identical *sets* hash identically in any input order, even with duplicate names.
3. Concatenate the sorted encodings into one byte stream.
4. Canonically encode each type definition (the `u8` tag-3 form of 9.1), sort them by qualified name (same byte-wise rule and tie-break), and append them to the stream.
5. Hash the stream with FNV-1a 64: offset basis `0xcbf29ce484222325`, prime `0x00000100000001b3`, that is, `h = basis; for each byte b: h ^= b; h = (h * prime) mod 2^64`. The resulting `u64` is the fingerprint (sent little-endian in the hello, section 3).

Consequences:

- Registration order in source never matters (the encodings are sorted).
- Struct **field order does** matter (declaration order is hashed). Reordering fields changes the fingerprint, although int-keyed maps keep the wire compatible. This is acceptable: the fingerprint is only a quick "nothing changed" check, and a mismatch only triggers discovery.
- The empty set hashes to the offset basis, `0xcbf29ce484222325`.

### 9.3 Worked example

Canonical encoding of the `server.entity` builtin signature: name `server.entity`, access read (4), request `structure[]` (an empty payload, because the target is in the envelope), response `structure[{key 0, "owner", uint}, {key 1, "group", uint}, {key 2, "mode", uint}]`:

```
0d000000 7365727665722e656e74697479    name: len 13, "server.entity"
04                                      access: read (4)
0a 00000000                             request: structure, 0 fields
0a 03000000                             response: structure, 3 fields
  01 0000000000000000                   key 0
  05000000 6f776e6572                   "owner"
  02                                    uint
  01 0100000000000000                   key 1
  05000000 67726f7570                   "group"
  02                                    uint
  01 0200000000000000                   key 2
  04000000 6d6f6465                     "mode"
  02                                    uint
```

### 9.4 Conformance values

FNV-1a 64 reference vectors (published test values): empty input → `0xcbf29ce484222325`; `"a"` → `0xaf63dc4c8601ec8c`; `"foobar"` → `0x85944171f73967e8`.

Pinned fingerprint: the three-signature set below MUST fingerprint to **`0x401118443279fc06`** (verified independently against the reference implementation). A change to this value in any implementation is a wire-protocol break.

1. `journal.append`, access write (2), request `structure[{0, "entity", string}, {1, "events", array(bytes)}, {2, "note", optional(string)}]`, response `structure[{0, "sequence", uint}]`.
2. `entity.stat`, access read (4), request `structure[{0, "entity", string}]`, response as in 9.3 (a fixture name kept from before the builtin rename; do not change it).
3. `journal.list`, access read (4), request `structure[{0, "entity", string}, {1, "filters", map(string, bool)}, {no key, "legacy", unknown}]`, response `array(double)`.

(Sorted order for hashing: `entity.stat`, `journal.append`, `journal.list`.)

Pinned fingerprint for a **typed** set, which tests `enumeration`, `reference`, and the tag-3 type-definition entries (verified independently against the reference implementation): the set below MUST fingerprint to **`0x96667b7065cbb8e4`**.

- Signature: `box.set`, access write (2), request `structure[{0, "entity", string}, {1, "meta", reference("box.LineMeta")}]`, response `structure[{0, "count", uint}]`.
- Type definition: `box.Priority` = `enumeration["low", "high"]`.
- Type definition: `box.LineMeta` = `structure[{0, "author", string}, {1, "priority", reference("box.Priority")}]`.

(Sorted order for hashing: the one signature, then definitions `box.LineMeta`, `box.Priority`.)

### 9.5 Builtin canonical signatures

The builtins (section 8) are in the fingerprinted set, so a real server's fingerprint can be reproduced only with their exact canonical signatures, given here.

`server.entity` is exactly the signature of section 9.3.

`server.schema`: name `server.schema`, access read (4), request `structure[]` (empty, the same as the `server.entity` request, because targets are in the envelope), response `structure[{0, "fingerprint", uint}, {1, "methods", array(MethodSignature)}, {2, "types", optional(array(TypeDefinition))}, {3, "namespaces", optional(array(NamespaceSignature))}]`.

- `MethodSignature` hashes as `structure[{0, "name", string}, {1, "access", uint}, {2, "description", optional(string)}, {10, "request", TypeSchema}, {11, "requestDescription", optional(string)}, {12, "requestStream", optional(TypeSchema)}, {13, "requestStreamDescription", optional(string)}, {20, "response", TypeSchema}, {21, "responseDescription", optional(string)}, {22, "responseStream", optional(TypeSchema)}, {23, "responseStreamDescription", optional(string)}]`. In the *type*, the stream and description slots are always-present optional fields. In the wire encoding of a concrete signature, an absent slot omits its key.
- `TypeDefinition` hashes as `structure[{0, "name", string}, {1, "schema", TypeSchema}, {2, "description", optional(string)}]`.
- `NamespaceSignature` hashes as `structure[{0, "name", string}, {1, "description", string}]`.
- A `TypeSchema`-typed field uses the pinned schema `structure[{0, "tag", uint}, {1, "first", unknown}, {2, "second", unknown}]`. The payload slots are `unknown` (tag 255) because their shape depends on the tag, which a static schema cannot express.
- The `types` and `namespaces` slots are `optional(array(...))` because the reference decoder reads them with a presence check (the keys are absent on older wires).

## 10. Connection lifecycle (protocol-normative subset)

The protocol itself requires:

- The hello (section 3) is the **first frame in each direction**. Everything after it is envelopes.
- These are fatal, and the connection is failed: a frame-cap violation (section 2), bad magic, a short hello (section 3), a malformed envelope (section 4), a truncated stream. A fingerprint mismatch is **not** fatal (section 3).
- Requests are answered on the same connection, correlated by msgid. The protocol has no reconnection, resumption, or msgid continuity across connections.
- A request the caller abandons (for example, cancelled on the client side) may still run on the server. The protocol makes no cancellation guarantee.

All other connection behavior is **endpoint policy, not protocol**: idle timeouts, connection caps, per-connection in-flight request caps (reported as error code 4 when exceeded), graceful-shutdown draining, socket file permissions, and retry/reconnect strategy. Peers MUST NOT assume any specific policy values.

### 10.1 Reference implementation behavior (non-normative)

How the reference implementation sets the endpoint policy above. Other implementations are not bound by it.

**Hello-first enforcement.** The server writes its hello when the channel becomes active, without waiting for the peer's hello. The peer's first frame must decode as a hello. Bad magic, or a truncated or undecodable hello, closes the connection before the frame passes the hello handler, so no envelope is processed before the hello. The client does the same: it sends its hello as its first outbound frame and requires the server's first frame to be a decodable hello. Otherwise `connect` fails (the channel is closed and no connection is returned).

**Idle-timeout reaping.** Each server connection has a traffic-idle timer (default 120 s) that counts traffic in *either* direction. Outbound stream frames count, so a client that only consumes a response stream is never closed mid-stream. A connection with no traffic in either direction for the timeout is closed. The reaper runs below the frame decoder, so it also closes peers that connect and never complete the hello. The client has the same reaper, off by default.

**Connection cap.** Enforced at accept (default 128 concurrent connections). An over-cap connection is closed immediately with no busy frame, because before the hello there is no msgid for an error response. The server hello may already have been flushed at channel activation, so a rejected peer may see a hello before the close.

**Per-connection in-flight cap.** At most N requests (default 16) run concurrently per connection, and nothing queues beyond the cap. An over-cap request is answered immediately with error code 4 (`tooManyInFlight`). Concurrent streams have a separate limit (default 8 per connection).

**Server graceful shutdown.** In order:

1. The listener closes (no new accepts).
2. Every open connection, including one still waiting for its peer's hello, stops reading through an input-half close. In-flight handlers complete, and their responses flush through the connection's writer.
3. Connection channels close.
4. Last, for unix endpoints, the socket file is removed. A device/inode comparison against the file that this instance bound ensures that a successor's socket at the same path is never deleted.

Cancellation (as opposed to graceful shutdown) closes connections immediately.

**Client behavior on connection death.** When the inbound loop ends (EOF, transport error, protocol violation, local close, or cancellation):

- every pending call fails with a connection-closed (or transport) error;
- the connection's observable state makes its single transition `connected` → `closed(reason:)`;
- state-update streams yield that final state and finish;
- live response streams end after their buffered elements drain, and their terminal resolves to a transport error.

A closed connection stays closed. There is no reconnection.

**Cancellation = local msgid abandonment.** Cancelling a task that awaits a call abandons the msgid on the client side. The call returns a cancellation error promptly, and a late response for that msgid is dropped with a debug log. The request may still run on the server, which matches the normative rule above: the protocol makes no cancellation guarantee.

## Appendix A. Conformance test vectors

All vectors below are pinned in the reference implementation's test suite and copied exactly. `→` means "encodes to / decodes from".

### A.1 MessagePack canonical values

| Value | Hex |
|---|---|
| int 0 | `00` |
| int 127 | `7f` |
| int 128 | `cc80` |
| int 256 | `cd0100` |
| int 65536 | `ce00010000` |
| int 4294967296 | `cf0000000100000000` |
| int −1 | `ff` |
| int −32 | `e0` |
| int −33 | `d0df` |
| int −129 | `d1ff7f` |
| float32 0.15625 | `ca3e200000` |
| float64 1.1 | `cb3ff199999999999a` |
| "" | `a0` |
| "abc" | `a3616263` |
| "é" | `a2c3a9` |
| 32×"a" (str8 boundary) | `d920` + 32×`61` |
| bin [de ad be ef] | `c404deadbeef` |
| array [1, 2, −33] | `930102d0df` |
| 16-element array16 boundary | `dc0010` + 16×`00` |
| map {1: 1} | `810101` |

Non-canonical decode-only vectors: `cc05` → 5, `d30000000000000005` → 5, `d903616263` → "abc", `de00010101` → {1: 1}, `cb3ff8000000000000` → Float 1.5.

### A.2 Hello

| Description | Hex |
|---|---|
| version 1, fingerprint `0x0123456789abcdef`, capabilities `0xdeadbeef` | `4d4d01efcdab8967452301efbeadde` |
| all-zero fields | `4d4d00000000000000000000000000` |

(The nonzero capabilities in the first vector only pin byte order. A conforming v1 sender sends 0.)

### A.3 Framing

| Payload | Frame |
|---|---|
| `2a` | `010000002a` |
| (empty) | `00000000` |
| `01020304` | `0400000001020304` |

### A.4 Envelopes

| Envelope | Hex |
|---|---|
| request `[1, 1, "ping", "", []]` | `950101a470696e67a090` |
| request msgid 0, "m", root entity, nil params | `950100a16da0c0` |
| request msgid 4294967295, "m", root entity, `[]` | `9501ceffffffffa16da090` |
| response `[0, 5, nil, true]` | `940005c0c3` |
| response `[0, 9, nil, nil]` (void) | `940009c0c0` |
| response `[0, 7, [-32601, "no"], nil]` | `94000792d180a7a26e6fc0` |
| response `[0, 7, [1, "e", [1, 2]], nil]` | `9400079301a165920102c0` |
| credit `[2, 1, 8]` | `93020108` |
| item `[3, 1, 0, "x"]` | `94030100a178` |
| END `[4, 1, 0]` | `93040100` |
| STOP `[5, 1, 0]` | `93050100` |
| CANCEL `[6, 1]` | `920601` |
| reserved tag `[7, "evt", {1: 2}]` (decodes to `unknownEnvelope`) | `9307a3657674810102` |
| request with reserved sixth element `[1, 1, "m", "", nil, {}]` | `960101a16da0c080` (decodes as `[1, 1, "m", "", nil]`) |

### A.5 Error objects

| Object | Hex | Decodes as |
|---|---|---|
| `[-32601, "no"]` | `92d180a7a26e6f` | code −32601, message "no", no payload |
| `[1, "e", nil]` | `9301a165c0` | code 1, message "e", absent payload |
| `[1, "e", nil, 99, "ex"]` | `9501a165c063a26578` | code 1, message "e", absent payload; trailing elements skipped |

### A.6 Fingerprint

| Input | FNV-1a 64 |
|---|---|
| (empty) | `0xcbf29ce484222325` |
| "a" | `0xaf63dc4c8601ec8c` |
| "foobar" | `0x85944171f73967e8` |
| three-signature set of §9.4 | `0x401118443279fc06` |

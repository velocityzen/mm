# matter-in-motion wire protocol, version 1

This document is the normative specification of the matter-in-motion binary RPC protocol. It is implementation-independent: a competent engineer must be able to build an interoperable client or server in any language from this document alone.

The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as in RFC 2119. All hex strings in this document are lowercase, byte-ordered as they appear on the wire, with no separators unless spaced for readability. Every worked example is a pinned conformance vector taken from (or cross-checked against) the reference implementation's test suite; see the appendix.

## 1. Overview and layering

The protocol runs over any reliable, ordered byte stream — Unix domain sockets are the primary transport; TCP is supported for trusted networks. The layers, bottom to top:

1. **Framing** — `[u32 LE length][payload]` length-prefixed frames.
2. **Hello preamble** — a fixed 15-byte binary structure; the first frame each side sends.
3. **Envelope** — tagged MessagePack arrays: seven kinds, tags 0–6 (section 4).
4. **Payloads** — MessagePack-encoded values inside the envelope's raw slots, following the struct conventions in section 5.

Byte order: every raw integer written by this protocol's own layers (frame length prefix, hello fields, fingerprint canonical encoding) is **little-endian**. MessagePack values are big-endian internally, per the MessagePack specification — that is MessagePack's business, not this protocol's.

The wire protocol version is a single `u8`, currently **1**. It is decoupled from any package or library version.

## 2. Framing

A frame is:

```
+-------------------+------------------------+
| length: u32 LE    | payload: length bytes  |
+-------------------+------------------------+
```

- The length prefix counts **payload bytes only** — the 4 prefix bytes are not included.
- Zero-length frames are legal at the framing layer and emit an empty payload. (No valid hello or envelope is zero-length, so upper layers will reject them, but the framing layer passes them through.)
- The maximum payload length defaults to **16 MiB (16,777,216 bytes)** and is configurable per endpoint. Both directions of a connection use the endpoint's configured cap; the two endpoints of a connection are expected to be configured compatibly. The cap is not discoverable on the wire in version 1 — no hello field or capability bit advertises it — so a sender MUST assume the peer's cap is the default unless it knows otherwise out of band, and endpoints that raise the cap must do so in matched pairs. (A future version may reserve a hello field or capability bit to advertise the cap.)

**Cap semantics (normative).** A receiver MUST validate the length prefix against its cap as soon as the 4 prefix bytes are readable — before waiting for, buffering, or consuming any body bytes. A length exceeding the cap is a **fatal protocol violation: the receiver fails the connection**. There is no error response, no resynchronization, no skipping; the stream is dead. A sender MUST NOT emit a frame whose payload exceeds its cap (this also guarantees the length is representable in the `u32` prefix).

A byte stream ending mid-frame (a partial length prefix or a partial body at EOF) is a truncation error; complete frames received before the truncated tail are still valid and MUST be delivered upward.

### 2.1 Worked examples

Payload `2a` (one byte):

```
01 00 00 00 2a
└─ length=1 ─┘└ payload
```

Empty payload: `00000000`. Payload `01020304` (4 bytes): `0400000001020304`.

A frame carrying the request envelope from section 4.1 (payload `950101a470696e67a3626f7890`, 13 bytes):

```
0d 00 00 00 95 01 01 a4 70 69 6e 67 a3 62 6f 78 90
```

## 3. Connection preamble (hello)

The first frame each side sends on a new connection MUST be a hello. Both sides send one; neither side is required to wait for the peer's hello before sending its own (the exchange may be concurrent). After its hello, each side sends only envelopes (section 4).

The hello payload is a fixed **15-byte** binary layout — deliberately not MessagePack, so it can be parsed before any coder state exists:

```
offset  0         1         2         3 .. 10                     11 .. 14
       +---------+---------+---------+------------------------------+---------------------+
       | 0x4d    | 0x4d    | version | schemaFingerprint            | capabilities        |
       | 'M'     | 'M'     | u8      | u64 little-endian            | u32 little-endian   |
       +---------+---------+---------+------------------------------+---------------------+
```

- **Magic** (offsets 0–1): the two bytes `4d 4d` (ASCII `MM`). Anything else is a fatal `badMagic` error; the connection is failed.
- **protocolVersion** (offset 2): the highest protocol version the sender speaks. Currently 1.
- **schemaFingerprint** (offsets 3–10): the sender's 8-byte schema fingerprint (section 9), as a `u64` little-endian. A client that exposes no schema of its own sends the fingerprint of the schema it expects, or 0 if it has none.
- **capabilities** (offsets 11–14): a `u32` little-endian bitset. **In version 1 no capability bits are defined; senders MUST send 0.** Receivers MUST ignore bits they do not recognize.

**Forward compatibility.** A receiver MUST parse exactly the first 15 bytes of the hello frame and tolerate (ignore) any trailing bytes, so a future version may append fields to its hello without breaking older peers.

**Short hellos are fatal.** A hello frame whose payload is shorter than 15 bytes is a fatal `truncated` error — a complete frame that ends before the fixed layout does is treated exactly like a truncated stream (sections 2 and 10): the connection is failed. Error precedence: with fewer than 2 readable bytes the error is `truncated`; once both magic bytes are readable, a wrong magic is `badMagic` even if the rest of the layout is missing; a correct magic followed by fewer than 15 total bytes is `truncated`.

**Version negotiation is min-wins.** The effective protocol version of the connection is `min(local version, peer version)`. A peer that cannot operate at the resulting version closes the connection; otherwise both sides proceed speaking the effective version. Because the hello exchange may be concurrent, a side may send envelopes before it has processed the peer's hello — before the effective version is known. Envelopes sent in that window MUST be valid at the sender's lowest supported version (in version 1, that is version 1); a sender that needs the features of a higher version MUST wait for the peer's hello before its first envelope.

**Fingerprint mismatch means discovery, never disconnection.** If the fingerprints differ, the connection stays up; the client SHOULD invoke schema discovery (`server.schema`, section 7) and adapt. A fingerprint mismatch is a hint that the method set changed, nothing more. Implementations MUST NOT close a connection because the fingerprints differ.

### 3.1 Worked example

Hello with version 1, fingerprint `0x0123456789abcdef`, capabilities `0xdeadbeef` (capabilities is nonzero here only to demonstrate byte order — a conforming v1 sender sends 0, and a receiver ignores the unknown bits):

```
4d 4d 01 ef cd ab 89 67 45 23 01 ef be ad de
│M │M │v1│←──── u64 LE fingerprint ────→│←u32 LE→│
```

Note the little-endian byte reversal: fingerprint `0x0123456789abcdef` appears as `ef cd ab 89 67 45 23 01`; capabilities `0xdeadbeef` as `ef be ad de`. The all-zero hello (version 0, fingerprint 0, capabilities 0) is `4d4d` followed by thirteen `00` bytes.

On the wire, this hello travels inside a frame: `0f000000 4d4d01efcdab8967452301efbeadde`.

## 4. Envelope

Every frame after the hello contains exactly one envelope: a MessagePack array with a leading integer **kind tag**. The frame payload MUST contain exactly the envelope value — trailing bytes after the envelope array are a decode error.

| Kind | Wire form | Meaning | Array arity |
|---|---|---|---|
| 0 | `[0, msgid, error, result]` | terminal response (server → client); `error` nil = graceful | exactly 4 |
| 1 | `[1, msgid, method, entity, params]` | open a call (client → server); `entity` is the target's dotted path, `""` = root | 5, or 6 with the reserved options element |
| 2 | `[2, msgid, credits]` | credit grant (stream flow control, either direction) | exactly 3 |
| 3 | `[3, msgid, seq, item]` | stream item | exactly 4 |
| 4 | `[4, msgid, 0]` | END — the sender finishes its own stream direction | 3 or more; the third element and beyond are reserved and skipped |
| 5 | `[5, msgid, code]` | STOP — asks the peer to finish its stream direction; code 0 = graceful, others reserved | exactly 3 |
| 6 | `[6, msgid]` | CANCEL — the client aborts the whole call | 2 or more; elements after msgid are skipped |

Kinds 2–6 are the stream frames; their full semantics — credit accounting, per-call stream state, and the termination matrix — are specified in section 4.2. There is no notification kind: **tag 7 is reserved** (server push is an ordinary method with a response stream, section 4.2), and a receiver that sees a leading tag of 7 or any other value outside 0–6 fails the connection with an `unknownEnvelope` error like any malformed envelope (below).

Element semantics:

- The leading element is the **kind tag**, a MessagePack integer 0–6. Any other value — 7, a larger integer, or a negative one — is an `unknownEnvelope` error.
- **Arity tolerance.** Arity is exact per kind, with three mandated tolerances for forward evolution: kind 1 tolerates arity 6 — the sixth element is reserved for future call options and is structurally skipped, never interpreted; kind 4 tolerates any arity ≥ 3 — the third element is reserved (senders MUST write the integer 0) and it and anything beyond are structurally skipped; kind 6 tolerates any arity ≥ 2 — elements after msgid are structurally skipped. Everything else about the envelope is fixed; evolution otherwise happens inside payloads and the error object.
- **msgid** is an unsigned integer that MUST fit in `u32`. It is assigned by the caller opening the call, is scoped **per connection**, and **wraps around** modulo 2³². A caller MUST NOT reuse a msgid while a call with that msgid is still awaiting its terminal response on the same connection (on wrap, the caller must ensure no live collision). The msgid slot follows the integer representability rule of section 5.4: any value not exactly representable in `u32` — wider than `u32`, or a negative MessagePack integer — is a decode error (`numberOutOfRange`); a non-canonical wider-than-necessary (oversized) encoding of a representable value is tolerated (e.g. msgid 1 encoded as `cc 01`).
- **method** is a MessagePack string (e.g. `journal.append`, `server.schema`). Method names are dotted paths like entity names.
- **entity** is a MessagePack string: the dotted path of the call's target entity (`""` = root). It is **authorization metadata, not payload** — the server parses and authorizes it (section 7) before the params slot is ever interpreted. A string that does not parse as an entity path is answered with `malformedParams` (code 3).
- **params**, **result**, and **item** are **raw payload slots**: each holds exactly one complete MessagePack value of any type, passed through opaquely by the envelope layer. A receiver computes the slot's byte extent by structurally walking the value (respecting the nesting cap, section 5.6) without materializing it; the payload is decoded later, against the concrete request/response/element type, after dispatch and authorization. On encode, a sender MUST place exactly one complete MessagePack value in each raw slot — no more, no fewer bytes.
- **error** in a response is either MessagePack `nil` (success) or an error object (section 6). In a response, the sender MUST encode `nil` in the slot it is not using: `error` is `nil` on success; `result` SHOULD be `nil` on failure. A receiver treats any non-nil `error` as failure. A response with `nil` in both slots is a valid void success.
- **credits** is an additive credit grant for one stream direction; **seq** is a per-direction item sequence number counting from 0; **code** in a STOP has 0 as its only defined (graceful) value, nonzero values reserved. All three are `u32` slots following the same representability rule as msgid.

A call opened by a request (kind 1) terminates with exactly one terminal response (kind 0) bearing the same msgid, on the same connection — for unary and streaming calls alike (section 4.2). There is no unsolicited, msgid-less frame in the protocol: every frame after the hello either opens a call, correlates to an open call's msgid, or is the terminal that retires it.

An unknown method in a request MUST produce an error response (code 1, section 6), never a silently dropped frame.

**Malformed envelopes are fatal.** A post-hello frame whose payload does not decode as exactly one well-formed envelope — a non-array payload, an arity outside its kind's tolerance, an unknown kind tag (7 or beyond), an undecodable msgid or method, trailing bytes after the envelope array, a `0xc1` byte or nesting-cap violation during the raw-slot walk, or a zero-length payload — is a fatal protocol violation: the receiver fails the connection (section 10). No error response is possible (the msgid may itself be unparseable) and no per-frame recovery is defined. Contrast three well-formed cases that are *not* fatal: an unknown *method* in a request, which is answered with a code-1 error; a stream frame (kinds 2–6) for a msgid that is unknown or already retired, which is dropped and counted (section 4.2); and a stream *contract* violation on a still-live call, which is answered with a code-6 terminal (section 4.2), not a connection failure.

**Receiver rules for stale correlation (normative).** A response (kind 0) whose msgid matches no outstanding call, and a second response bearing an already-retired msgid, are dropped, not fatal; a server that receives any inbound response treats it as a peer protocol error and drops it. A stream frame (kinds 2–6) bearing a msgid with no live stream state — never opened, or already retired by its terminal — is likewise dropped and counted, never fatal (this is what makes late items racing a call's end tolerable rather than a violation; see the state machine in section 4.2).

### 4.1 Worked examples

All of these are pinned test vectors.

Request `[1, 1, "ping", "box", []]` — msgid 1, method `ping`, entity `box`, params the empty array:

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

Reserved tag rejected — `[7, "evt", {1: 2}]` → `9307a3657674810102` is a well-formed MessagePack array but its leading tag 7 is reserved, so it decodes to an `unknownEnvelope` error and the connection is failed. (Tag 7 was the notification kind in a pre-release design; it now ships reserved.)

Error response `[0, 7, [-32601, "no"], nil]`: `94000792d180a7a26e6fc0` — the error object is `92 d180a7 a26e6f` (array(2), int16 −32601, fixstr "no"); the result slot is `c0`.

Error response with error payload `[0, 7, [1, "e", [1, 2]], nil]`: `9400079301a165920102c0`.

msgid extremes: msgid 0 → `950100a16da0c0` (request, method "m", root entity, params nil); msgid 4294967295 → `9501ceffffffffa16da090` (`ce ffffffff` = uint32 max).

Stream kinds: credit `[2, 1, 8]` → `93020108`; item `[3, 1, 0, "x"]` → `94030100a178` (seq 0, item fixstr "x"); END `[4, 1, 0]` → `93040100`; STOP `[5, 1, 0]` → `93050100`; CANCEL `[6, 1]` → `920601`.

Arity tolerance: request with a reserved sixth element `[1, 1, "m", "", nil, {}]` → `960101a16da0c080` decodes exactly as `[1, 1, "m", "", nil]`; END with a nonzero reserved element `[4, 1, 99]` → `93040163` decodes as END msgid 1; CANCEL with an extra element `[6, 1, 0]` → `93060100` decodes as CANCEL msgid 1.

### 4.2 Streaming

A method may carry, in any combination, a **request stream** (elements the client sends after opening) and a **response stream** (elements the server sends before its terminal). Both ride the one call opened by kind 1 and correlated by its msgid; a unary call is the degenerate case with neither. The four-part method model — opening request, request stream, response stream, terminal response — is reflected in the schema (section 8.1); this section is the wire and state contract the two peers share.

**One authorization, at open.** Authorization runs exactly once, on the open envelope's entity slot (kind 1: parse, traversal, target check — section 7), before any stream element flows. Stream items ride the already-authorized call and are **never individually authorized**. An entity's ACL change does not affect an in-flight stream.

**The terminal is the sole retirement.** Every call — unary or streaming — ends with exactly one terminal response (kind 0, section 4), always sent by the server, always the call's last frame for that msgid. A nil-error terminal is the graceful outcome; an error terminal the failed one. The terminal *is* how the client distinguishes graceful from failed, and it is the only frame that retires the msgid.

#### Stream frames

- **item** `[3, msgid, seq, item]` — one stream element. `seq` is a per-direction `u32` counting from 0 (the client's request items and the server's response items each carry their own independent sequence); `item` is a raw MessagePack value slot (section 4), decoded later against the declared element type. Cheap gap detection: a `seq` that skips a value is a violation (below).
- **credit** `[2, msgid, credits]` — an additive credit grant, sent by whichever side *receives* items on a direction, replenishing the sender's window (below).
- **END** `[4, msgid, 0]` — the sender of items gracefully finishes **its own** direction. Client END ends the request stream; server END ends the response stream (the terminal may still lag while the server finalizes). Receiving END finishes the receiver's element sequence cleanly.
- **STOP** `[5, msgid, code]` — the receiver of items asks the sender to gracefully finish **the peer's** direction (`code` 0 = graceful, the only defined value). STOP is **advisory**: items already in flight are tolerated, never a violation. The sender's next send reports a typed *peer-stopped* outcome — a graceful signal, not an error — and the call continues to its terminal.
- **CANCEL** `[6, msgid]` — client → server only: the client abandons the whole call. The server cancels the handler task and still sends the terminal (error code 7, `cancelled`) to retire the msgid. A server's own abnormal exit is just an error terminal; it never needs a cancel frame.

#### State machine

Each of a call's two item directions is a small state machine, mirrored on both peers: it moves `open → ended` exactly once, and the call's terminal retires the whole msgid from any state. A direction ends via its own END, via a STOP that the sender acknowledges by ending, or via the terminal. **Late items are tolerated, not violations:** an item arriving after its own direction ended — after the sender's own END, after the server terminated the request source, or racing CANCEL / the terminal — is dropped and counted, because the direction is already closed. The receiver rules of section 4 make a stream frame for an unknown or retired msgid a silent drop for the same reason.

The **four true violations** — an item on a direction the method did not declare, a `seq` gap, a credit overrun on a still-live source (an item arriving with zero credit), or a request item that fails to decode against the element type — get a code-6 (`streamViolation`) terminal from the server when it can still answer; broken framing (a malformed envelope) stays connection-fatal per section 4.

#### Termination matrix

How each ending surfaces, symmetric between the peers (implementations SHOULD present these outcomes; the wire contract is the frames above):

| Event | Frames | Item-sending side observes | Item-receiving side observes |
|---|---|---|---|
| Graceful finish of a direction | END | — (it sent END) | element sequence finishes cleanly |
| Receiver has seen enough | STOP → sender ENDs | next send reports *peer-stopped* (graceful); call runs to terminal | — (it sent STOP) |
| Server done, success | server END + nil-error terminal | — | response sequence finishes; terminal is success |
| Failure | error terminal | — | response sequence finishes; terminal is the error |
| Client abandons the call | CANCEL → code-7 terminal | server handler task cancelled; runtime sends code-7 terminal | client surfaces resolve *cancelled* locally |
| Connection death | — (transport) | all live streams and calls fail with a transport error | same |

Connection death is the one involuntary ending: every live stream and call fails with a transport error on both sides, always distinguishable from every graceful path.

#### Credit flow control

Flow control is **credit-based, per stream direction, counted in items**. A fresh direction starts with an **initial window of 8 items** — a spec constant known to both peers, never sent as a frame; the sender MAY send that many items before receiving any grant. Each item sent spends one credit; at **zero credit the sender MUST suspend** until a credit frame arrives. Backpressure thus reaches the producing task and per-stream buffering is bounded by construction (window × frame cap). There is **no head-of-line blocking between streams**: a stalled stream starves only itself; sibling calls on the same connection are unaffected.

The **receiver** grants more credit as its consumer drains, batched at a watermark rather than per item — the reference implementation grants once at least half the window (4 items) has been consumed since the last grant, topping the sender's window back up to 8 in one additive frame. Granting only the deficit keeps the sender's credit ≤ the initial window, so the overrun check stays exact. The exact batching cadence is receiver policy; what the protocol fixes is that a grant is additive, per-direction, and that a conforming sender never exceeds its granted window.

#### Stream worked examples

All pinned test vectors. On a follow-style server stream (msgid 1), the server sends items and the client grants credit:

- credit grant of 8 — `[2, 1, 8]` → `93020108`
- item at seq 0, payload `"x"` — `[3, 1, 0, "x"]` → `94030100a178`
- END of a direction — `[4, 1, 0]` → `93040100`
- STOP (graceful, code 0) — `[5, 1, 0]` → `93050100`
- CANCEL of the call — `[6, 1]` → `920601`

## 5. MessagePack usage conventions

Payloads (the contents of `params`, `result`, and error payload slots) are MessagePack values obeying the following conventions. These conventions are the schema-evolution contract of the protocol.

### 5.1 Structs are int-keyed maps

A struct encodes as a MessagePack map whose keys are integers assigned statically per field (in the reference implementation, `CodingKeys: Int` raw values). The key space is **signed 64-bit** (`i64`, matching the fingerprint's canonical encoding, section 9.1): negative keys are representable and legal, though schemas conventionally assign small non-negative keys. A wire integer key not representable in `i64` (a `uint64` above `2^63 − 1`) can never match a field and is skipped like any unknown key (section 5.2). Field names never travel on the wire for int-keyed structs. Example — a struct with fields `id = key 1` and `name = key 2`, value `{id: 42, name: "mm"}`:

```
82 01 2a 02 a2 6d 6d
│  │  │  │  └ fixstr(2) "mm"
│  │  │  └ key 2
│  │  └ 42
│  └ key 1
└ fixmap(2)
```

String keys remain supported as a fallback: a field without an integer key encodes under its name as a MessagePack string key. Integer and string keys may coexist in one map. Lookup rules (normative, in wire terms): a wire **integer** key `k` matches a field declared with integer key `k`, and also matches a string-named entry (such as a dictionary key) whose name is exactly the canonical decimal form of `k` (`"5"`, never `"05"`); a wire **string** key matches the field or entry bearing that exact name — including, as a decode-side fallback, a field that also has an integer key. A wire string key is never parsed into an integer: wire string `"5"` does not match integer field key `5`, and implementations MUST NOT let a string-derived key (like a dictionary key `"05"`) alias a distinct integer key `5`.

### 5.2 Unknown keys are skipped

A decoder MUST skip map entries whose keys it does not recognize, **structurally** — walking the value (of any MessagePack family, however nested: str, bin, arrays, maps, ext, any width) without materializing it. This applies at every nesting level. Keys that can never match a field (integers outside the `i64` key space of section 5.1, strings with invalid UTF-8, keys of non-integer/non-string families) are likewise skipped along with their values, not treated as errors.

### 5.3 Evolution contract: new fields must be optional

To evolve a struct, add new fields with fresh keys and make them **optional**. A decoder maps a missing optional field to "absent" (nil), and an explicit MessagePack `nil` value also decodes as absent. A missing **non-optional** field is a decode error (`keyNotFound`). Never reuse or renumber keys; never change a field's type in place.

**Duplicate keys: the first occurrence wins.** A decoder indexing a map keeps the first value seen for a key and skips later duplicates.

### 5.4 Non-canonical decode tolerance

Encoders SHOULD write the canonically minimal encoding (smallest integer width that represents the value; fixstr/fixmap/fixarray when the length allows; `bin` for binary). Decoders MUST tolerate non-canonical input:

- An integer of any MessagePack width and either signedness decodes into any target type that can exactly represent the value (`cc 05`, `d3 0000000000000005`, and `05` all decode as 5). A value the target type cannot represent is `numberOutOfRange`.
- `float64` decodes into a 32-bit float target when exactly representable; additionally, **any** `float64` NaN decodes into a float target as a NaN — NaN is never rejected as unrepresentable, and its payload bits are not preserved across the narrowing.
- Oversized length encodings (`str8` for a fixstr-sized string, `array16` for one element, `map32` for one entry, …) decode normally.
- A `str` value decodes into a binary target as its UTF-8 bytes (some encoders ship raw bytes as str).

The reserved MessagePack byte `0xc1` is invalid anywhere and is a decode error.

### 5.5 Binary values

Raw byte payloads encode as MessagePack `bin`. Decoders SHOULD expose them zero-copy where the host language allows.

### 5.6 Nesting depth cap (receiver limit)

Receivers enforce a container-nesting cap, default **128** levels, on both full decoding and the structural walks that compute raw-slot extents (section 4) and skip unknown values. Exceeding the cap is a decode error (`nestingTooDeep`), not a crash. The cap is a **receiver limit, not a wire grammar rule**: endpoints MAY raise it in matched pairs, and a sender must assume the default unless it knows otherwise. Depth counting (normative): a top-level scalar is at depth 0 and each container entered increments the depth by one; the cap applies per payload value — each raw slot is walked with its own counter — and the envelope array itself does not count toward a slot's depth. A value nested to exactly 128 container levels therefore passes the default cap.

## 6. Error objects

The `error` slot of a response, when non-nil, is a MessagePack array:

```
[code, message]              — 2 elements
[code, message, payload]     — 3 elements
```

- **code** is a MessagePack integer (any width, signed values allowed).
- **message** is a MessagePack string, human-readable.
- **payload** is optional: one complete MessagePack value, passed through opaquely (a raw slot, like `params`). An explicit `nil` in the payload slot decodes as an absent payload.

**Trailing-element tolerance (normative).** Unlike the envelope, the error object is evolution-tolerant: fewer than 2 elements is an error, but a decoder MUST tolerate and structurally skip any elements after the third. `[1, "e", nil, 99, "ex"]` (`9501a165c063a26578`) decodes as code 1, message "e", no payload.

### 6.1 Protocol error codes

Codes **1–63 are reserved for the protocol**; applications MUST use codes **>= 64** (negative codes are representable and also outside the reserved range, but the application space is defined as >= 64). The v1 reserved codes:

| Code | Name | Meaning |
|---|---|---|
| 1 | unknownMethod | The request named a method the router has no route for. |
| 2 | permissionDenied | The peer's identity does not grant the access class the method requires on the target entity (or on one of its ancestors, for traversal). |
| 3 | malformedParams | The params payload failed to decode as the method's request type. |
| 4 | tooManyInFlight | The connection exceeded its in-flight request cap. |
| 5 | internalError | The handler failed in a way that is not the caller's fault. |
| 6 | streamViolation | The peer broke the stream contract: an item on an undeclared stream, an item after its own END, a seq gap, or a credit overrun. |
| 7 | cancelled | Terminal response acknowledging a client CANCEL: the call was aborted. |

**Existence is never leaked (normative).** There is no "entity not found" code. A request targeting an entity for which the server has no ACL record — including an entity that simply does not exist — is denied with `permissionDenied` (code 2), exactly as if an ACL had denied the access; a server MUST NOT reveal through its choice of error whether an entity exists. (A failure of the ACL store itself is `internalError`, code 5.)

**Unknown-case decoding rule (applies to every wire-decoded enum in this protocol).** Decoding a code — or any enumerated wire value: TypeSchema tags, access-mode bits, capability bits — MUST NOT fail on an unrecognized value. Unrecognized codes map to an explicit "unknown" case carrying the raw value; implementations MUST NOT switch exhaustively over wire enums without a default. New codes and tags may appear in future versions; old peers degrade gracefully.

Worked vectors: `92d180a7a26e6f` = `[-32601, "no"]` (no payload); `9301a165c0` = `[1, "e", nil]` (explicit nil payload, decodes as absent).

## 7. Entities and authorization

### 7.1 Entity names

An entity name is a dotted path (`domain.area.name`) identifying a node in the entity tree.

Grammar: one or more **segments** joined by single dots (`.`, 0x2e). Each segment is non-empty and drawn from the ASCII set `a-z`, `0-9`, `_`, `-` — lowercase only; names are canonical and never case-folded. No leading dot, no trailing dot, no empty segment (`..` is invalid).

**Root.** The empty string is reserved for the distinguished **root** value, meaning "the whole entity tree". Root never names a concrete entity; it exists for discovery-style requests. It encodes as the empty string on the wire, has no parent and no ancestors, and carries no ACL — the traversal rule (7.4) never consults an ACL for root. Every non-root name is a descendant of root; root is a descendant of nothing, including itself.

Descendant-ship is strict and dot-bounded: `a.b.c` is a descendant of `a.b` and `a`; `a.bc` is **not** a descendant of `a.b`; nothing is a descendant of itself. The ancestors of `a.b.c` are `[a, a.b]`, outermost first; a single-segment name and root have none.

On the wire an entity name is a plain MessagePack string.

### 7.2 The entity-in-the-envelope convention

**The call's target entity is envelope metadata, never payload**: it rides the open frame's dedicated entity slot (section 4), as the dotted-path string. The server parses it and runs the full authorization (traversal + target check) **before interpreting a single byte of the params slot** — an unauthorized peer's payload is never decoded at all, which both saves work and minimizes the pre-auth attack surface. Request payloads are consequently plain values like responses and stream elements: fields keyed from 0, no reserved key, and any named type (a `reference`, section 8.3) can stand as a whole request payload with no special shape.

Worked example — a `server.schema` call scoped to entity `journal` puts `journal` in the envelope's entity slot; its request payload is the empty map `{}` (`80`).

### 7.3 The rwx / ugo ACL model

Each entity carries an ACL: an owning uid, an owning gid, and nine permission bits, exactly the POSIX filesystem model.

Access bits (per class): **execute/traverse = 1, write/mutate = 2, read/observe = 4**. On the wire an access mode is its raw `u8`; unknown high bits are preserved on decode, never rejected (section 6's unknown-case rule).

Mode layout: `mode` is a `u16` whose low 9 bits are `(owner_bits << 6) | (group_bits << 3) | other_bits` — conventionally written in octal (`0o750` = owner rwx, group r-x, other ---). The default creation mode for new entities is **0o750**, configurable umask-style per server.

Each method declares the access class its verb requires on the target entity (e.g. `journal.append` requires write; `server.schema` requires read).

**Class selection.** The peer is classified once, in this order:

1. `peer.uid == acl.owner` → **owner** class,
2. else `peer.gid == acl.group` or `acl.group ∈ peer.supplementaryGroups` → **group** class,
3. else → **other** class.

**First-matching-class-wins (normative).** Only the selected class's bits decide. The requested bits must all be present in that class's bits. A denial in the matching class is final — later classes are **never** consulted, even when they would grant the access. The empty request (no bits) is vacuously permitted for everyone.

Truth table for `EntityACL(owner: 1000, group: 100, mode: 0o750)`:

| Peer | Class | read | write | execute |
|---|---|---|---|---|
| uid 1000, gid 100 | owner | yes | yes | yes |
| uid 2000, gid 100 | group | yes | **no** | yes |
| uid 2000, gid 9, supp. groups [100] | group | yes | **no** | yes |
| uid 2000, gid 9 | other | no | no | no |

**Owner-denied-other-granted asymmetry** — mode `0o007` (owner ---, group ---, other rwx), owner 1000, group 100:

| Peer | Class | read | write | execute |
|---|---|---|---|---|
| uid 1000 (the owner) | owner | **no** | **no** | **no** |
| uid 2000, gid 9 (a stranger) | other | yes | yes | yes |

The owner is matched by the owner class, whose bits are 000; the other class's rwx is never consulted. The same asymmetry holds one class down: with mode `0o707`, a group member is denied what strangers are granted.

### 7.4 Traversal: x on every ancestor

Before a method's own access check, the peer must hold **execute (x)** on **every ancestor prefix** of the target entity. For target `a.b.c`, the peer needs x on `a` and x on `a.b` (each checked against that ancestor's own ACL by the same first-matching-class-wins rule), plus the method's declared access on `a.b.c` itself. Root is excluded — it carries no ACL. Failing traversal is `permissionDenied` (code 2), indistinguishable on the wire from failing the target check.

### 7.5 Identity: kernel-attested, never wire-claimed

Peer identity (uid, primary gid, supplementary groups) is derived by the server from the transport — kernel peer credentials on Unix domain sockets (`SO_PEERCRED` / `LOCAL_PEERCRED`), captured once at accept time and frozen for the connection's lifetime. **Identity never travels on the wire and is never claimed by the client**; there is no protocol field for it, by design. The peer's pid is diagnostic only, never an authorization input.

- **uid 0 is not special.** There is no superuser override anywhere in this protocol; administrative recovery uses the daemon's own uid.
- **Anonymous TCP peers.** Raw TCP connections carry no kernel credentials; in v1 they are assigned the anonymous identity (`uid = uid_t.max`, `gid = gid_t.max`, no supplementary groups). These values are not special-cased: because no real entity should be owned by them, anonymous peers match the **other** class in practice, and other-bits decide their access. Do not create ACLs owned by `uid_t.max`.

## 8. Schema discovery

Two builtin methods exist on every server. Both declare **read** on their target entity and are subject to the traversal rule of section 7.4 like any other method. A **root** target, having no ACL and no ancestors (section 7.1), is exempt from both checks and reaches the handler unconditionally: `server.schema` then filters its response by the peer's per-method traversal rights (section 8.1), and `server.entity` denies root inside its handler via the no-ACL rule (section 8.2).

### 8.1 `server.schema`

Request (`SchemaRequest`): the empty map `{}` — the discovery **scope** is the call's envelope entity (a concrete entity narrows to its subtree; root, the empty path, asks about the whole tree). Response (`SchemaResponse`):

| Key | Field | Type |
|---|---|---|
| 0 | fingerprint | u64 — the fingerprint of the server's **complete** method set and type table (not of the filtered lists below), so a client can compare it with the hello fingerprint |
| 1 | methods | array of MethodSignature |
| 2 | types | array of TypeDefinition — **optional**; absent from pre-types servers and decodes as empty |
| 3 | namespaces | array of NamespaceSignature — **optional**; absent from servers predating the key (decodes as empty) and when no served namespace declared a description |

The methods list is scoped by the request's entity and filtered by the requesting peer's traversal rights: discovery reflects what that peer can reach. The types list contains the named-type definitions **transitively reachable** from the served methods' schemas (chased through the definitions themselves): every `reference` in the response resolves within the response.

`NamespaceSignature` is an int-keyed struct documenting one namespace: key 0 = `name` (string, the namespace prefix entity, e.g. `journal`), key 1 = `description` (string). Entries exist only for namespaces that declared a description, sorted by name, and are filtered with the methods: a namespace is listed iff at least one of its methods is. Like every description, the list is documentation only — served by discovery, **never** hashed into the fingerprint and never consulted by compatibility comparisons.

**Scope.** Each method's **method-name prefix** — its name minus the final verb segment (`journal.append` → `journal`; a single-segment name → root) — is interpreted as an entity name. A non-root request entity narrows the listing to methods whose prefix equals it or is a descendant of it; root selects every method. A scope that matches nothing yields an empty `methods` list, not an error.

**Filter predicate (normative).** A method is listed iff the requesting peer holds **execute** on the method's prefix entity and on every ancestor of that prefix — each checked against its own ACL by the first-matching-class-wins rule of section 7.3, with a missing ACL record anywhere on the chain excluding the method. A single-segment method name (a namespace **root call** — the method is the namespace itself, e.g. `search`) is its own prefix: it is filtered by execute on that entity, exactly like its dotted siblings. Neither **read** on the prefix nor the method's own declared access class is consulted by the filter.

`MethodSignature` is an int-keyed struct. Keys are grouped by what they describe: the method itself in the single digits, the request direction in the 10s, the response direction in the 20s — and every slot is immediately followed by its own description slot:

| Key | Field | Type |
|---|---|---|
| 0 | name | string (e.g. `journal.append`) |
| 1 | access | u8 — raw access bits (section 7.3); unknown bits preserved |
| 2 | description | string — **optional**; human-readable method documentation |
| 10 | request | TypeSchema — opening-request shape |
| 11 | requestDescription | string — **optional** |
| 12 | requestStream | TypeSchema — **optional**; element shape the client may stream (present only for methods with a request stream) |
| 13 | requestStreamDescription | string — **optional** |
| 20 | response | TypeSchema — terminal-response shape |
| 21 | responseDescription | string — **optional** |
| 22 | responseStream | TypeSchema — **optional**; element shape the server may stream before the terminal (present only for methods with a response stream) |
| 23 | responseStreamDescription | string — **optional** |

Every optional slot is absent (the key omitted from the map) when unset; readers skip unknown keys, per the evolution rule. A method may carry any combination of the four request/response/requestStream/responseStream parts. The five description slots (keys 2, 11, 13, 21, 23) are documentation only: served by discovery, **never** hashed into the fingerprint and never consulted by compatibility comparisons — a doc edit is not schema drift.

`TypeDefinition` is an int-keyed struct — the definition a `reference` (section 8.3) resolves to. Names are **nominal**: the qualified name (`journal.Priority`) is part of the contract, hashed into the fingerprint (section 9.1); renaming a type is a schema change. Servers validate at startup that every reference in their registered schemas resolves.

| Key | Field | Type |
|---|---|---|
| 0 | name | string — qualified (`<namespace>.<TypeName>`) |
| 1 | schema | TypeSchema — a `structure` or `enumeration` |
| 2 | description | string — **optional**; documentation only |

### 8.2 `server.entity`

Request (`StatRequest`): the empty map `{}` — the stat **target** is the call's envelope entity. Root has no ACL to report: a stat call whose envelope entity is the empty string reaches the handler (section 8) but is denied with `permissionDenied` (code 2), the same no-ACL rule as section 6.1. Response (`StatResponse`) is the target's ACL:

| Key | Field | Type |
|---|---|---|
| 0 | owner | u32 (uid) |
| 1 | group | u32 (gid) |
| 2 | mode | u16 (nine permission bits, section 7.3) |

Worked example — `StatResponse{owner: 1000, group: 100, mode: 0o750}` (0o750 = 488 = 0x1e8):

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
- key **1**: first payload — the wrapped schema for `optional`, the element schema for `array`, the **key** schema for `map`, the field list for `structure`;
- key **2**: second payload — the **value** schema for `map`.

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

**Calendar and clock values (tags 13–15).** All three encode as MessagePack **bin** holding one VPTS encoding (the variable-precision timestamp codec; normative spec in <doc:VPTS>). They are distinct schema kinds — not bytes — because they carry different semantics (a `date` has no time zone by nature; a `datetime` is a floating wall-clock reading; a `timestamp` is an absolute instant). Per-kind constraints on the VPTS component mask (normative):

- `date` — exactly YEAR+MONTH+DAY; no time components, no fraction, no offset.
- `datetime` — YEAR through SECOND, an optional FRACTION, no OFFSET. **Canonical emission** omits the fraction when it is zero.
- `timestamp` — YEAR through SECOND, an optional FRACTION, OFFSET **required**. Canonical emission omits a zero fraction; offset zero is `OFFSET = 0` (there is no `Z`/`+00:00` distinction in VPTS).

Value ranges within those masks: year 0–9999, proleptic Gregorian (leap years validated); hour 00–23, minute 00–59, second 00–60 (leap second allowed); fraction precision is nanoseconds (a receiver accepts the wide/attosecond VPTS form only when the value is nanosecond-divisible); the offset is within ±18:00. The VPTS **null** encoding (`0x00`) is never a value — payload optionality is MessagePack nil via the `optional` schema, and a null VPTS where a value is expected is a decode failure. A bin whose contents violate the VPTS grammar or these per-kind constraints is a decode failure of its payload, answered like any malformed payload (`malformedParams`, code 3, for a request slot).

In **JSON projections** of wire values (discovery tooling, the CLI's parameter and output trees) the three kinds map to canonical ISO 8601 / RFC 3339 strings — `2026-07-21`, `2026-07-21T14:30:00.5`, `2026-07-21T14:30:00Z` — with the fraction only when non-zero (1–9 digits, trailing zeros trimmed), uppercase `T`/`Z`, and `Z` for offset zero. Parsers of that projection accept two liberties only: lowercase `t`/`z`, and `±00:00` as an alias of `Z`. This string form never appears on the wire.

A `structure`'s fields appear in **declaration order** (the order the type's decoder requests them). `Field` is an int-keyed struct: key 0 = `key` (the field's integer wire key, or nil/absent for string-keyed fields), key 1 = `name` (string), key 2 = `type` (TypeSchema), key 3 = `description` (string, **optional**, documentation only).

An `enumeration` is a closed set of **string-valued** cases: the wire value of an enum-typed field is the case name as a MessagePack string (fixed decision). Renaming a case is a wire break; reordering is not (though it changes the fingerprint, like field order). Decoders MUST map an unrecognized value to a local fallback case rather than fail (the house wire-enum rule). `EnumCase` is an int-keyed struct: key 0 = `name` (string, the wire value), key 1 = `description` (string, **optional**). Cases appear in declaration order.

A `reference` names a `TypeDefinition` (section 8.1) served alongside the method list; discovery responses are self-contained (every reference resolves within the response).

**Decoding TypeSchema never fails (normative).** A client that cannot decode the schema response cannot discover anything else, so a decoder MUST map anything unrecognized — an unknown tag, a missing tag, a corrupt or missing payload, even a non-map value — to `unknown` instead of failing. New tags added in future versions therefore degrade to `unknown` on old peers.

Worked example — `optional(string)` = `{0: 7, 1: {0: 5}}`:

```
82 00 07 01 81 00 05
│  │  │  │  └ nested map {0: 5} = string
│  │  │  └ key 1 (first payload)
│  │  └ tag 7 (optional)
│  └ key 0
└ fixmap(2)
```

Hex: `82000701810005`. Bare `string` alone is `810005`.

## 9. Schema fingerprint

The 8-byte fingerprint exchanged in the hello is a stable, cross-platform hash of the server's method set **and named-type table**. The set includes the two builtin methods of section 8: `server.schema` and `server.entity` are fingerprinted like any application method (their canonical signatures are pinned in section 9.5). Two independent implementations MUST compute identical values for the same set of method signatures and type definitions. It is computed as **FNV-1a 64** over a canonical byte encoding of the sorted signatures followed by the sorted type definitions.

**Descriptions are never hashed.** None of the five signature doc slots (keys 2, 11, 13, 21, 23), field descriptions (Field key 3), enum-case descriptions, or definition descriptions appear in the canonical encoding — doc edits never change the fingerprint.

### 9.1 Canonical encoding

A simple tagged, length-prefixed byte encoding — deliberately **not** MessagePack. All integers little-endian.

**string** := `u32 LE` byte count, then the UTF-8 bytes.

**signature** := name (string) ‖ access (`u8`, the raw rwx bits) ‖ request schema ‖ response schema ‖ *stream entries, emitted only when present*: `u8` tag `1` then the request-stream element schema; `u8` tag `2` then the response-stream element schema. A method with no streams emits neither entry, so any unary-only set hashes to exactly its pre-streaming value (the golden of 9.4 is unchanged); the distinct tags keep the request and response stream slots asymmetric.

**schema** := `u8` case tag (the same values as the wire tag table in 8.3: 0 bool, 1 int, 2 uint, 3 float, 4 double, 5 string, 6 bytes, 7 optional, 8 array, 9 map, 10 structure, 11 enumeration, 12 reference, 13 date, 14 datetime, 15 timestamp, 255 unknown), then payload:

- `optional` (7), `array` (8): the child schema.
- `map` (9): the key schema, then the value schema.
- `structure` (10): `u32 LE` field count, then per field, in declaration order: `u8` key-presence flag (1 if the field has an integer key, else 0), `i64 LE` key when present, the field name (string), the field schema. Field descriptions are not encoded.
- `enumeration` (11): `u32 LE` case count, then per case, in declaration order: the case name (string). Case descriptions are not encoded.
- `reference` (12): the qualified type name (string).
- all other tags: no payload.

**type definition** := `u8` tag `3` ‖ the qualified name (string) ‖ the definition's schema. Definition descriptions are not encoded. Type-definition entries follow the signature stream (see 9.2); an empty type table emits nothing, so every type-free fingerprint keeps its pre-types value.

### 9.2 Sorting and hashing

1. Canonically encode each signature.
2. Sort the signatures **by name**, byte-wise over the name's UTF-8 bytes (lexicographic). Signatures sharing a name (illegal in a router but representable) tie-break by byte-wise comparison of their full canonical encodings, making the sort a total order — identical *sets* hash identically regardless of input order, even with duplicate names.
3. Concatenate the sorted encodings into one byte stream.
4. Canonically encode each type definition (the `u8` tag-3 form of 9.1), sort by qualified name (same byte-wise rule, same tie-break), and append the sorted encodings to the stream.
5. Hash the stream with FNV-1a 64: offset basis `0xcbf29ce484222325`, prime `0x00000100000001b3`, i.e. `h = basis; for each byte b: h ^= b; h = (h * prime) mod 2^64`. The resulting `u64` is the fingerprint (transmitted little-endian in the hello, section 3).

Consequences: source registration order never matters (sorted); struct **field order does** matter (declaration order is hashed) — reordering fields changes the fingerprint even though int-keyed maps make it wire-compatible, which is acceptable because the fingerprint is only a fast-path "nothing changed" hint and a mismatch only triggers discovery. The empty set hashes to the offset basis, `0xcbf29ce484222325`.

### 9.3 Worked example

The canonical encoding of the `server.entity` signature — name `server.entity`, access read (4), request `structure[]` (an empty payload: the target rides the envelope), response `structure[{key 0, "owner", uint}, {key 1, "group", uint}, {key 2, "mode", uint}]`:

```
0b000000 656e746974792e73746174        name: len 11, "server.entity"
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

Pinned golden fingerprint: the three-signature set below MUST fingerprint to **`0x401118443279fc06`** (verified independently against the reference implementation). A change to this value in any implementation is a wire-protocol break.

1. `journal.append`, access write (2), request `structure[{0, "entity", string}, {1, "events", array(bytes)}, {2, "note", optional(string)}]`, response `structure[{0, "sequence", uint}]`.
2. `server.entity`, access read (4), request and response as in 9.3.
3. `journal.list`, access read (4), request `structure[{0, "entity", string}, {1, "filters", map(string, bool)}, {no key, "legacy", unknown}]`, response `array(double)`.

(Sorted order for hashing: `server.entity`, `journal.append`, `journal.list`.)

Pinned golden fingerprint for a **typed** set (exercises `enumeration`, `reference`, and the tag-3 type-definition entries; verified independently against the reference implementation): the set below MUST fingerprint to **`0x96667b7065cbb8e4`**.

- Signature: `box.set`, access write (2), request `structure[{0, "entity", string}, {1, "meta", reference("box.LineMeta")}]`, response `structure[{0, "count", uint}]`.
- Type definition: `box.Priority` = `enumeration["low", "high"]`.
- Type definition: `box.LineMeta` = `structure[{0, "author", string}, {1, "priority", reference("box.Priority")}]`.

(Sorted order for hashing: the one signature, then definitions `box.LineMeta`, `box.Priority`.)

### 9.5 Builtin canonical signatures

Because the builtins (section 8) are part of the fingerprinted set, a real server's fingerprint is reproducible only with their exact canonical signatures, pinned here.

`server.entity` is exactly the signature of section 9.3.

`server.schema` is: name `server.schema`, access read (4), request `structure[]` (empty, identical to `server.entity`'s request — targets ride the envelope), response `structure[{0, "fingerprint", uint}, {1, "methods", array(MethodSignature)}, {2, "types", optional(array(TypeDefinition))}]`. `MethodSignature` hashes as the structure `structure[{0, "name", string}, {1, "access", uint}, {2, "description", optional(string)}, {10, "request", TypeSchema}, {11, "requestDescription", optional(string)}, {12, "requestStream", optional(TypeSchema)}, {13, "requestStreamDescription", optional(string)}, {20, "response", TypeSchema}, {21, "responseDescription", optional(string)}, {22, "responseStream", optional(TypeSchema)}, {23, "responseStreamDescription", optional(string)}]` (the stream and doc slots are always-present optional fields in the *type*, distinct from the wire encoding of a concrete signature, where an absent slot omits the key). `TypeDefinition` hashes as `structure[{0, "name", string}, {1, "schema", TypeSchema}, {2, "description", optional(string)}]`. The schema standing for a `TypeSchema`-typed field is the pinned structure `structure[{0, "tag", uint}, {1, "first", unknown}, {2, "second", unknown}]` — the payload slots are `unknown` (tag 255) because the shape in those positions depends on the tag, which a static schema cannot express. (The `types` slot is `optional(array(...))` because the reference decoder reads it with a presence check — the key is absent on pre-types wires.)

## 10. Connection lifecycle (protocol-normative subset)

What the protocol itself requires:

- The hello (section 3) is the **first frame in each direction**. Everything after it is envelopes.
- A frame-cap violation (section 2), bad magic, a short hello (section 3), a malformed envelope (section 4), or a truncated stream is fatal: the connection is failed. A fingerprint mismatch is **not** fatal (section 3).
- Requests are answered on the same connection, correlated by msgid. There is no protocol-level reconnection, resumption, or msgid continuity across connections.
- A request abandoned by the caller (e.g. cancelled client-side) may still execute server-side; the protocol makes no cancellation guarantee.

Everything else about connection behavior is **endpoint policy, not protocol**: idle timeouts, connection caps, per-connection in-flight request caps (surfaced as error code 4 when exceeded), graceful-shutdown draining, socket file permissions, and retry/reconnect strategy. Peers MUST NOT assume any particular policy values.

### 10.1 Reference implementation behavior (non-normative)

How the reference implementation fills in the endpoint policy above. None of this binds other implementations.

**Hello-first enforcement.** The server writes its hello at channel activation, without waiting for the peer's. The peer's first frame must decode as a hello: bad magic or an undecodable/truncated hello closes the connection before the frame is ever forwarded past the hello handler — no envelope is processed pre-hello. The client symmetrically sends its hello as the first outbound frame and requires the server's first frame to be a decodable hello; anything else fails `connect` (the channel is torn down, no connection is returned).

**Idle-timeout reaping.** Each server connection carries a traffic-idle timer (default 120 s) judged on traffic in *either* direction — outbound stream frames count as liveness, so a client that only consumes a response stream is never reaped mid-stream. A connection with no traffic either way for the timeout is closed; because the reaper sits below the frame decoder, this also reaps peers that connect and never complete the hello. The client has the same reaper, off by default.

**Connection cap.** Enforced at accept (default 128 concurrent connections): an over-cap connection is closed immediately, with no busy frame — pre-hello there is no msgid to correlate an error response to. The server hello may already have flushed at channel activation, so a rejected peer can observe a hello before the close.

**Per-connection in-flight cap.** At most N requests (default 16) run concurrently per connection; nothing queues beyond the cap. An over-cap request is answered immediately with error code 4 (`tooManyInFlight`). Concurrent streams are bounded separately (default 8 per connection).

**Server graceful shutdown.** In order: the listener closes (no new accepts); every open connection — including one still awaiting its peer's hello — stops reading via input-half close, while in-flight handlers complete and their responses flush through the connection's writer; connection channels close; last, for unix endpoints, the socket file is removed, guarded by a device/inode comparison against the file this instance bound so a successor's socket at the same path is never deleted. Cancellation (as opposed to graceful shutdown) tears connections down immediately.

**Client behavior on connection death.** When the inbound loop terminates — EOF, transport error, protocol violation, local close, or cancellation — every pending call fails with a connection-closed (or transport) error, the connection's observable state makes its single transition `connected` → `closed(reason:)`, state-update streams yield that terminal state and finish, and live response streams end after buffered elements drain (their terminal resolving to a transport error). A closed connection stays closed; there is no reconnection.

**Cancellation = local msgid abandonment.** Cancelling a task awaiting a call abandons the msgid client-side: the call returns a cancellation error promptly, and a late response for that msgid is dropped with a debug log. The request may still execute server-side — consistent with the normative rule above that the protocol makes no cancellation guarantee.

## Appendix A. Conformance test vectors

All vectors below are pinned in the reference implementation's test suite and reproduced verbatim. `→` means "encodes to / decodes from".

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

(The nonzero capabilities in the first vector exist only to pin byte order; a conforming v1 sender sends 0.)

### A.3 Framing

| Payload | Frame |
|---|---|
| `2a` | `010000002a` |
| (empty) | `00000000` |
| `01020304` | `0400000001020304` |

### A.4 Envelopes

| Envelope | Hex |
|---|---|
| request `[1, 1, "ping", []]` | `940101a470696e6790` |
| request msgid 0, "m", nil params | `940100a16dc0` |
| request msgid 4294967295, "m", `[]` | `9401ceffffffffa16d90` |
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
| request with reserved fifth element `[1, 1, "m", nil, {}]` | `950101a16dc080` (decodes as `[1, 1, "m", nil]`) |

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

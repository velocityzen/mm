import NIOCore

extension ByteBuffer {
    /// Consumes exactly one MessagePack value (of any family, however nested) and
    /// returns its raw byte extent as a zero-copy slice, using the structural skip
    /// from the value layer to compute the extent. The value is never materialized.
    /// Nesting beyond `maxDepth` container levels fails with `.nestingTooDeep`.
    /// On failure the reader index is restored.
    public mutating func readMessagePackRawValueSlice(
        maxDepth: Int = 128
    ) -> Result<ByteBuffer, MMWireError> {
        self.sliceMessagePackValue(currentDepth: 0, cap: maxDepth)
    }
}

/// Decodes one optional raw slot per the spec rule stated once in §4: an
/// explicit nil in the slot decodes as absent; anything else goes through
/// `read`. Shared by the envelope's error/result slots and the `MMError`
/// payload slot.
private func readOptionalSlot<Value>(
    from reader: inout ByteBuffer,
    _ read: (inout ByteBuffer) -> Result<Value, MMWireError>
) -> Result<Value?, MMWireError> {
    if reader.peekMessagePackFormat() == MPFormat.nilByte {
        return reader.readMessagePackNil().map { _ in nil }
    }
    return read(&reader).map { $0 }
}

/// Structurally skips `count` reserved/tolerated trailing elements — a fold:
/// any skip failure short-circuits. Shared by the envelope's
/// evolution-tolerant kinds and the `MMError` trailing-element rule.
private func mpSkipElements(
    from reader: inout ByteBuffer,
    count: Int,
    maxDepth: Int
) -> Result<Void, MMWireError> {
    (0..<count).reduce(.success(())) { skipped, _ in
        skipped.flatMap { reader.skipMessagePackValue(maxDepth: maxDepth) }
    }
}

/// Validates that `slot` contains exactly one complete MessagePack value and nothing
/// else. Encoding raw slots without this check could corrupt the stream for the peer.
/// A slot that is one complete value but nested beyond `maxDepth` fails with the
/// truthful `.nestingTooDeep`, never a misattributed `.encodingFailed`.
private func mpValidateRawSlot(
    _ slot: ByteBuffer,
    name: String,
    maxDepth: Int
) -> Result<Void, MMWireError> {
    var copy = slot
    if case .failure(let error) = copy.skipMessagePackValue(maxDepth: maxDepth) {
        if case .nestingTooDeep = error {
            return .failure(error)
        }
        return .failure(
            .encodingFailed(description: "\(name) is not a single complete MessagePack value")
        )
    }
    guard copy.readableBytes == 0 else {
        return .failure(
            .encodingFailed(description: "\(name) has trailing bytes after one MessagePack value")
        )
    }
    return .success(())
}

/// The RPC error (`MMError`) carried in the error slot of a response envelope.
///
/// Wire form is a MessagePack array: `[code, message]` or `[code, message, payload]`.
/// For evolution, decoding tolerates and structurally skips any extra trailing
/// elements, and an explicit `nil` in the payload slot decodes as an absent payload.
/// `payload` is a raw pre-encoded MessagePack value slice; this layer never decodes it.
public struct MMError: Equatable, Sendable {
    public var code: Int
    public var message: String
    /// A single pre-encoded MessagePack value, passed through opaquely.
    public var payload: ByteBuffer?

    public init(code: Int, message: String, payload: ByteBuffer? = nil) {
        self.code = code
        self.message = message
        self.payload = payload
    }

    /// Validates the raw payload slot without writing anything.
    func validateForEncoding(maxDepth: Int) -> Result<Void, MMWireError> {
        guard let payload = self.payload else { return .success(()) }
        return mpValidateRawSlot(payload, name: "error payload", maxDepth: maxDepth)
    }

    /// Writes the wire form. Callers must have run `validateForEncoding(maxDepth:)`
    /// first; `MMEnvelope.encode(into:maxDepth:)` does so before writing any bytes.
    func write(into buffer: inout ByteBuffer) {
        if let payload = self.payload {
            buffer.writeMessagePackArrayHeader(count: 3)
            buffer.writeMessagePackInt(Int64(self.code))
            buffer.writeMessagePackString(self.message)
            buffer.writeImmutableBuffer(payload)
        } else {
            buffer.writeMessagePackArrayHeader(count: 2)
            buffer.writeMessagePackInt(Int64(self.code))
            buffer.writeMessagePackString(self.message)
        }
    }

    /// Encodes the wire form into `buffer`. On failure nothing is written.
    /// `maxDepth` bounds the payload slot's container nesting; match it to the
    /// endpoint's configured `MMPackDecoder.maxDepth` when that cap is raised.
    public func encode(
        into buffer: inout ByteBuffer,
        maxDepth: Int = 128
    ) -> Result<Void, MMWireError> {
        self.validateForEncoding(maxDepth: maxDepth).map { self.write(into: &buffer) }
    }

    /// Decodes one error, consuming it from `buffer`.
    /// On failure the reader index is restored.
    public static func decode(
        from buffer: inout ByteBuffer,
        maxDepth: Int = 128
    ) -> Result<MMError, MMWireError> {
        let start = buffer.readerIndex
        let result = Self.decodeBody(from: &buffer, maxDepth: maxDepth)
        if case .failure = result { buffer.moveReaderIndex(to: start) }
        return result
    }

    private static func decodeBody(
        from buffer: inout ByteBuffer,
        maxDepth: Int
    ) -> Result<MMError, MMWireError> {
        let count: Int
        switch buffer.readMessagePackArrayHeader() {
            case .failure(let error): return .failure(error)
            case .success(let value): count = value
        }
        guard count >= 2 else {
            return .failure(.invalidArity(expected: 2, got: count))
        }
        let code: Int
        switch buffer.readMessagePackInt() {
            case .failure(let error):
                return .failure(error)
            case .success(let raw):
                guard let narrowed = Int(exactly: raw) else {
                    return .failure(.numberOutOfRange(target: "Int"))
                }
                code = narrowed
        }
        let message: String
        switch buffer.readMessagePackString() {
            case .failure(let error): return .failure(error)
            case .success(let value): message = value
        }
        var payload: ByteBuffer?
        if count >= 3 {
            switch readOptionalSlot(from: &buffer, { $0.readMessagePackRawValueSlice(maxDepth: maxDepth) }) {
                case .failure(let error): return .failure(error)
                case .success(let slice): payload = slice
            }
            // Evolution tolerance: skip any extra trailing elements structurally.
            if case .failure(let error) = mpSkipElements(
                from: &buffer, count: count - 3, maxDepth: maxDepth)
            {
                return .failure(error)
            }
        }
        return .success(MMError(code: code, message: message, payload: payload))
    }
}

extension MMError: CustomStringConvertible {
    /// Log-ready one-liner: `code 64: journal is read-only`, with an opaque
    /// payload noted by size only (this layer never decodes it).
    public var description: String {
        let suffix = self.payload.map { " (payload: \($0.readableBytes) bytes)" } ?? ""
        return "code \(self.code): \(self.message)\(suffix)"
    }
}

/// The v1 RPC envelope, hand-coded to/from MessagePack (hottest path —
/// no `Codable` machinery).
///
/// Wire forms — every kind is a MessagePack array with a leading integer tag
/// (fixed decisions, streaming amendment):
///
/// | Kind | Layout | Meaning |
/// |---|---|---|
/// | 0 | `[0, msgid, error, result]` | terminal response (server→client); `error` nil = graceful |
/// | 1 | `[1, msgid, method, entity, params]` | open a call (client→server); `entity` is the dotted target path (`""` = root); decode tolerates arity 6 (6th element reserved for options, skipped) |
/// | 2 | `[2, msgid, credits]` | credit grant, additive u32, either direction |
/// | 3 | `[3, msgid, seq, item]` | stream item; `seq` u32 from 0 per direction; `item` stays raw |
/// | 4 | `[4, msgid, 0]` | END — sender finishes its own direction; third element reserved (write 0; decode tolerates+ignores third-and-beyond elements) |
/// | 5 | `[5, msgid, code]` | STOP — receiver asks the peer to finish theirs; code 0 = graceful, others reserved |
/// | 6 | `[6, msgid]` | CANCEL — client aborts the whole call; decode tolerates+ignores extra elements |
///
/// The `params`/`result`/`item` slots are raw `ByteBuffer` slices whose extents are
/// computed with the value layer's structural skip — the envelope layer never decodes
/// payloads; that happens after dispatch resolves the concrete type. On encode, raw
/// slots must each contain exactly one complete MessagePack value; this is validated
/// up front (before any bytes are written) and violations fail with `.encodingFailed`,
/// except nesting beyond `maxDepth`, which fails with the truthful `.nestingTooDeep`.
///
/// Decoding requires exact arity except where the table above mandates tolerance
/// (kind 1 arity 6; kinds 4 and 6 extra elements, structurally skipped); evolution
/// otherwise happens inside payloads and `MMError`. An unknown (or negative)
/// leading type integer fails with `.unknownEnvelope`; malformed input always yields
/// a typed failure, never a crash.
public enum MMEnvelope: Equatable, Sendable {
    /// Kind 1 — opens a call (unary or streaming), client→server. `entity` is
    /// the target's dotted path (`""` = root) — authorization metadata, read
    /// by the router before the params slice is ever interpreted. It is a
    /// plain string at this layer; MMWire cannot depend on MMSchema's
    /// `EntityName`, so parsing/validation happens at dispatch.
    case request(msgid: UInt32, method: String, entity: String, params: ByteBuffer)
    /// Kind 0 — the terminal response, server→client, always the call's last frame.
    /// `error` nil = graceful outcome.
    case response(msgid: UInt32, error: MMError?, result: ByteBuffer?)
    /// Kind 2 — additive credit grant for one stream direction (flow control).
    case credit(msgid: UInt32, credits: UInt32)
    /// Kind 3 — one stream item. `seq` counts from 0 per direction; `item` is a raw
    /// MessagePack value slice, never decoded at this layer.
    case item(msgid: UInt32, seq: UInt32, item: ByteBuffer)
    /// Kind 4 — END: the sender gracefully finishes its own item direction.
    /// Encodes `[4, msgid, 0]`; the third element is reserved.
    case end(msgid: UInt32)
    /// Kind 5 — STOP: asks the peer to gracefully finish its item direction.
    /// `code` 0 = graceful (the only defined value); nonzero reserved.
    case stop(msgid: UInt32, code: UInt32)
    /// Kind 6 — CANCEL: the client abandons the whole call (abnormal).
    case cancel(msgid: UInt32)

    static let trailingBytesDescription = "trailing bytes after envelope"

    /// Encodes the envelope into `buffer`. On failure nothing is written.
    /// `maxDepth` bounds container nesting inside the raw params/result/error-payload
    /// slots (default 128); pass the endpoint's configured cap when it differs from
    /// the default, so a payload the endpoint's coder accepts also frames.
    public func encode(
        into buffer: inout ByteBuffer,
        maxDepth: Int = 128
    ) -> Result<Void, MMWireError> {
        switch self {
            case .request(let msgid, let method, let entity, let params):
                return mpValidateRawSlot(params, name: "params", maxDepth: maxDepth).map {
                    buffer.writeMessagePackArrayHeader(count: 5)
                    buffer.writeMessagePackUInt(1)
                    buffer.writeMessagePackUInt(UInt64(msgid))
                    buffer.writeMessagePackString(method)
                    buffer.writeMessagePackString(entity)
                    buffer.writeImmutableBuffer(params)
                }

            case .response(let msgid, let responseError, let result):
                return (responseError.map { $0.validateForEncoding(maxDepth: maxDepth) }
                    ?? .success(()))
                    .flatMap {
                        result.map { mpValidateRawSlot($0, name: "result", maxDepth: maxDepth) }
                            ?? .success(())
                    }
                    .map {
                        buffer.writeMessagePackArrayHeader(count: 4)
                        buffer.writeMessagePackUInt(0)
                        buffer.writeMessagePackUInt(UInt64(msgid))
                        if let responseError {
                            responseError.write(into: &buffer)
                        } else {
                            buffer.writeMessagePackNil()
                        }
                        if let result {
                            buffer.writeImmutableBuffer(result)
                        } else {
                            buffer.writeMessagePackNil()
                        }
                    }

            case .credit(let msgid, let credits):
                buffer.writeMessagePackArrayHeader(count: 3)
                buffer.writeMessagePackUInt(2)
                buffer.writeMessagePackUInt(UInt64(msgid))
                buffer.writeMessagePackUInt(UInt64(credits))
                return .success(())

            case .item(let msgid, let seq, let item):
                return mpValidateRawSlot(item, name: "item", maxDepth: maxDepth).map {
                    buffer.writeMessagePackArrayHeader(count: 4)
                    buffer.writeMessagePackUInt(3)
                    buffer.writeMessagePackUInt(UInt64(msgid))
                    buffer.writeMessagePackUInt(UInt64(seq))
                    buffer.writeImmutableBuffer(item)
                }

            case .end(let msgid):
                buffer.writeMessagePackArrayHeader(count: 3)
                buffer.writeMessagePackUInt(4)
                buffer.writeMessagePackUInt(UInt64(msgid))
                // Reserved third element: always 0 for now.
                buffer.writeMessagePackUInt(0)
                return .success(())

            case .stop(let msgid, let code):
                buffer.writeMessagePackArrayHeader(count: 3)
                buffer.writeMessagePackUInt(5)
                buffer.writeMessagePackUInt(UInt64(msgid))
                buffer.writeMessagePackUInt(UInt64(code))
                return .success(())

            case .cancel(let msgid):
                buffer.writeMessagePackArrayHeader(count: 2)
                buffer.writeMessagePackUInt(6)
                buffer.writeMessagePackUInt(UInt64(msgid))
                return .success(())
        }
    }

    /// Encodes the envelope into a fresh buffer.
    public func encoded(
        allocator: ByteBufferAllocator = ByteBufferAllocator(),
        maxDepth: Int = 128
    ) -> Result<ByteBuffer, MMWireError> {
        var buffer = allocator.buffer(capacity: 64)
        return self.encode(into: &buffer, maxDepth: maxDepth).map { buffer }
    }

    /// Decodes one envelope from a frame payload. The frame must contain exactly the
    /// envelope: trailing bytes after the envelope array are a `.decodingFailed` error.
    /// `maxDepth` bounds container nesting inside the raw params/result/error-payload
    /// slots (default 128); pass the endpoint's configured `MMPackDecoder.maxDepth`
    /// when it is raised above the default, or deep-but-decodable payloads fail here
    /// before the payload decoder ever runs.
    public static func decode(
        from buffer: ByteBuffer,
        maxDepth: Int = 128
    ) -> Result<MMEnvelope, MMWireError> {
        var reader = buffer
        return reader.readMessagePackArrayHeader()
            .flatMap { count -> Result<MMEnvelope, MMWireError> in
                guard count >= 1 else { return .failure(.unknownEnvelope) }
                return reader.readMessagePackInt()
                    .mapError { error in
                        // A tag wider than Int64 is simply a kind this decoder
                        // does not know: the spec maps every tag outside 0...6
                        // to unknownEnvelope.
                        if case .numberOutOfRange = error { .unknownEnvelope } else { error }
                    }
                    .flatMap { tag in
                        Self.decodeKind(
                            tag: tag, count: count, from: &reader, maxDepth: maxDepth)
                    }
            }
            .flatMap { envelope in
                reader.readableBytes == 0
                    ? .success(envelope)
                    : .failure(.decodingFailed(description: Self.trailingBytesDescription))
            }
    }

    /// Decodes the tagged body of one envelope kind (the elements after the
    /// leading tag; `count` is the whole array's arity).
    private static func decodeKind(
        tag: Int64,
        count: Int,
        from reader: inout ByteBuffer,
        maxDepth: Int
    ) -> Result<MMEnvelope, MMWireError> {
        switch tag {
            case 0:
                guard count == 4 else {
                    return .failure(.invalidArity(expected: 4, got: count))
                }
                return Self.decodeU32(from: &reader).flatMap { msgid in
                    Self.decodeErrorSlot(from: &reader, maxDepth: maxDepth).flatMap { responseError in
                        Self.decodeResultSlot(from: &reader, maxDepth: maxDepth).map { result in
                            MMEnvelope.response(msgid: msgid, error: responseError, result: result)
                        }
                    }
                }
            case 1:
                // Tolerate arity 6: the sixth element is reserved for future call
                // options and is structurally skipped, never interpreted.
                guard count == 5 || count == 6 else {
                    return .failure(.invalidArity(expected: 5, got: count))
                }
                return Self.decodeU32(from: &reader).flatMap { msgid in
                    reader.readMessagePackString().flatMap { method in
                        reader.readMessagePackString().flatMap { entity in
                            reader.readMessagePackRawValueSlice(maxDepth: maxDepth).flatMap {
                                params in
                                mpSkipElements(
                                    from: &reader, count: count - 5, maxDepth: maxDepth
                                ).map { _ in
                                    MMEnvelope.request(
                                        msgid: msgid, method: method, entity: entity, params: params
                                    )
                                }
                            }
                        }
                    }
                }
            case 2:
                guard count == 3 else {
                    return .failure(.invalidArity(expected: 3, got: count))
                }
                return Self.decodeU32(from: &reader).flatMap { msgid in
                    Self.decodeU32(from: &reader).map { credits in
                        MMEnvelope.credit(msgid: msgid, credits: credits)
                    }
                }
            case 3:
                guard count == 4 else {
                    return .failure(.invalidArity(expected: 4, got: count))
                }
                return Self.decodeU32(from: &reader).flatMap { msgid in
                    Self.decodeU32(from: &reader).flatMap { seq in
                        reader.readMessagePackRawValueSlice(maxDepth: maxDepth).map { item in
                            MMEnvelope.item(msgid: msgid, seq: seq, item: item)
                        }
                    }
                }
            case 4:
                // The third element is reserved; it and anything beyond are
                // structurally skipped and ignored.
                guard count >= 3 else {
                    return .failure(.invalidArity(expected: 3, got: count))
                }
                return Self.decodeU32(from: &reader).flatMap { msgid in
                    mpSkipElements(
                        from: &reader, count: count - 2, maxDepth: maxDepth
                    ).map { _ in
                        MMEnvelope.end(msgid: msgid)
                    }
                }
            case 5:
                guard count == 3 else {
                    return .failure(.invalidArity(expected: 3, got: count))
                }
                return Self.decodeU32(from: &reader).flatMap { msgid in
                    Self.decodeU32(from: &reader).map { code in
                        MMEnvelope.stop(msgid: msgid, code: code)
                    }
                }
            case 6:
                // Extra elements beyond msgid are structurally skipped and ignored.
                guard count >= 2 else {
                    return .failure(.invalidArity(expected: 2, got: count))
                }
                return Self.decodeU32(from: &reader).flatMap { msgid in
                    mpSkipElements(
                        from: &reader, count: count - 2, maxDepth: maxDepth
                    ).map { _ in
                        MMEnvelope.cancel(msgid: msgid)
                    }
                }
            default:
                return .failure(.unknownEnvelope)
        }
    }

    /// Reads one u32 slot (msgid, seq, credits, stop code). Non-canonical integer
    /// widths are tolerated; values wider than u32 are `.numberOutOfRange`.
    private static func decodeU32(
        from reader: inout ByteBuffer
    ) -> Result<UInt32, MMWireError> {
        reader.readMessagePackUInt().flatMap { raw in
            guard let value = UInt32(exactly: raw) else {
                return .failure(.numberOutOfRange(target: "UInt32"))
            }
            return .success(value)
        }
    }

    private static func decodeErrorSlot(
        from reader: inout ByteBuffer,
        maxDepth: Int
    ) -> Result<MMError?, MMWireError> {
        readOptionalSlot(from: &reader) { MMError.decode(from: &$0, maxDepth: maxDepth) }
    }

    private static func decodeResultSlot(
        from reader: inout ByteBuffer,
        maxDepth: Int
    ) -> Result<ByteBuffer?, MMWireError> {
        readOptionalSlot(from: &reader) { $0.readMessagePackRawValueSlice(maxDepth: maxDepth) }
    }
}

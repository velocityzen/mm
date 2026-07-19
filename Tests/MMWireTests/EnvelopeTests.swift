import NIOCore
import Testing

@testable import MMWire

// All expected byte sequences in this file are hand-derived from the MessagePack
// spec (fixarray 0x90+N, fixstr 0xa0+N, positive fixint as-is, uint8 cc, uint16 cd,
// uint32 ce, uint64 cf, int16 d1, nil c0, false c2, true c3, fixmap 0x80+N) —
// never from the encoder under test.

@Suite("MMEnvelope golden vectors — request/response")
struct EnvelopeGoldenVectorTests {
    @Test("request [1, 1, \"ping\", \"box\", []] encodes and decodes")
    func requestVector() {
        let vector = "950101a470696e67a3626f7890"
        let envelope = MMEnvelope.request(
            msgid: 1, method: "ping", entity: "box", params: mpBytes("90"))
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("response success [0, 5, nil, true] encodes and decodes")
    func responseSuccessVector() {
        let vector = "940005c0c3"
        let envelope = MMEnvelope.response(msgid: 5, error: nil, result: mpBytes("c3"))
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("a leading tag of 7 (former notification) decodes to .unknownEnvelope")
    func tagSevenIsUnknown() {
        // [7, "evt", {1: 2}] — the shape the deleted transitional notification
        // used. Tag 7 is now outside the table (0–6), so it decodes as any
        // other unknown kind: a typed failure, never a crash.
        #expect(
            MMEnvelope.decode(from: mpBytes("9307a3657674810102")) == .failure(.unknownEnvelope))
    }

    @Test("response with error [-32601, \"no\"] and nil result")
    func responseErrorVector() {
        let vector = "94000792d180a7a26e6fc0"
        let envelope = MMEnvelope.response(
            msgid: 7,
            error: MMError(code: -32601, message: "no"),
            result: nil
        )
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("response with error payload [1, \"e\", [1, 2]]")
    func responseErrorPayloadVector() {
        let vector = "9400079301a165920102c0"
        let envelope = MMEnvelope.response(
            msgid: 7,
            error: MMError(code: 1, message: "e", payload: mpBytes("920102")),
            result: nil
        )
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("request msgid 0 and UInt32.max round trip with pinned bytes")
    func msgidExtremes() {
        let zeroVector = "950100a16da0c0"
        let zero = MMEnvelope.request(msgid: 0, method: "m", entity: "", params: mpBytes("c0"))
        #expect(zero.encoded().mpSuccess.map(mpHex) == zeroVector)
        #expect(MMEnvelope.decode(from: mpBytes(zeroVector)) == .success(zero))

        let maxVector = "9501ceffffffffa16da090"
        let max = MMEnvelope.request(msgid: .max, method: "m", entity: "", params: mpBytes("90"))
        #expect(max.encoded().mpSuccess.map(mpHex) == maxVector)
        #expect(MMEnvelope.decode(from: mpBytes(maxVector)) == .success(max))
    }
}

@Suite("MMEnvelope golden vectors — kind 1 arity-6 tolerance")
struct RequestArityToleranceTests {
    @Test("arity-6 request decodes; the reserved options slot is ignored")
    func aritySixScalarOptions() {
        // [1, 1, "m", "", nil, {}]
        let decoded = MMEnvelope.decode(from: mpBytes("960101a16da0c080"))
        #expect(
            decoded
                == .success(.request(msgid: 1, method: "m", entity: "", params: mpBytes("c0"))))
    }

    @Test("arity-6 options slot with a nested container is structurally skipped")
    func aritySixNestedOptions() {
        // [1, 1, "m", "", [], [false, true]]
        let decoded = MMEnvelope.decode(from: mpBytes("960101a16da09092c2c3"))
        #expect(
            decoded
                == .success(.request(msgid: 1, method: "m", entity: "", params: mpBytes("90"))))
    }

    @Test("trailing bytes after an arity-6 request are still rejected")
    func aritySixTrailingBytes() {
        #expect(
            MMEnvelope.decode(from: mpBytes("960101a16da0c08000"))
                == .failure(.decodingFailed(description: MMEnvelope.trailingBytesDescription))
        )
    }

    @Test("truncated options slot in an arity-6 request is truncated")
    func aritySixTruncatedOptions() {
        // Sixth element claims array2 but the frame ends.
        #expect(MMEnvelope.decode(from: mpBytes("960101a16da0c092")) == .failure(.truncated))
    }

    @Test("arity 7 is invalidArity")
    func aritySeven() {
        // [1, 1, "m", "", [], nil, nil]
        #expect(
            MMEnvelope.decode(from: mpBytes("970101a16da090c0c0"))
                == .failure(.invalidArity(expected: 5, got: 7))
        )
    }
}

@Suite("MMEnvelope golden vectors — kind 2 credit")
struct CreditGoldenVectorTests {
    @Test("credit [2, 1, 8] encodes and decodes")
    func canonicalVector() {
        let vector = "93020108"
        let envelope = MMEnvelope.credit(msgid: 1, credits: 8)
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("msgid and credits at 0 and UInt32.max with pinned bytes")
    func boundaryValues() {
        let zeroVector = "93020000"
        let zero = MMEnvelope.credit(msgid: 0, credits: 0)
        #expect(zero.encoded().mpSuccess.map(mpHex) == zeroVector)
        #expect(MMEnvelope.decode(from: mpBytes(zeroVector)) == .success(zero))

        let maxVector = "9302ceffffffffceffffffff"
        let max = MMEnvelope.credit(msgid: .max, credits: .max)
        #expect(max.encoded().mpSuccess.map(mpHex) == maxVector)
        #expect(MMEnvelope.decode(from: mpBytes(maxVector)) == .success(max))
    }

    @Test("non-canonical integer widths are tolerated on decode")
    func nonCanonicalWidths() {
        // [uint8 2, uint8 1, uint16 8]
        #expect(
            MMEnvelope.decode(from: mpBytes("93cc02cc01cd0008"))
                == .success(.credit(msgid: 1, credits: 8))
        )
    }

    @Test("credits wider than u32 is numberOutOfRange")
    func creditsOverflow() {
        #expect(
            MMEnvelope.decode(from: mpBytes("930201cf0000000100000000"))
                == .failure(.numberOutOfRange(target: "UInt32"))
        )
    }

    @Test("arity 2 and arity 4 are invalidArity")
    func arityViolations() {
        #expect(
            MMEnvelope.decode(from: mpBytes("920201"))
                == .failure(.invalidArity(expected: 3, got: 2))
        )
        #expect(
            MMEnvelope.decode(from: mpBytes("9402010800"))
                == .failure(.invalidArity(expected: 3, got: 4))
        )
    }
}

@Suite("MMEnvelope golden vectors — kind 3 item")
struct ItemGoldenVectorTests {
    @Test("item [3, 1, 0, \"x\"] encodes and decodes")
    func canonicalVector() {
        let vector = "94030100a178"
        let envelope = MMEnvelope.item(msgid: 1, seq: 0, item: mpBytes("a178"))
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("msgid and seq at 0 and UInt32.max with pinned bytes")
    func boundaryValues() {
        let zeroVector = "94030000c0"
        let zero = MMEnvelope.item(msgid: 0, seq: 0, item: mpBytes("c0"))
        #expect(zero.encoded().mpSuccess.map(mpHex) == zeroVector)
        #expect(MMEnvelope.decode(from: mpBytes(zeroVector)) == .success(zero))

        let maxVector = "9403ceffffffffceffffffffc0"
        let max = MMEnvelope.item(msgid: .max, seq: .max, item: mpBytes("c0"))
        #expect(max.encoded().mpSuccess.map(mpHex) == maxVector)
        #expect(MMEnvelope.decode(from: mpBytes(maxVector)) == .success(max))
    }

    @Test("non-canonical seq width is tolerated on decode")
    func nonCanonicalSeq() {
        // [3, 1, uint16 0, nil]
        #expect(
            MMEnvelope.decode(from: mpBytes("940301cd0000c0"))
                == .success(.item(msgid: 1, seq: 0, item: mpBytes("c0")))
        )
    }

    @Test("seq wider than u32 is numberOutOfRange")
    func seqOverflow() {
        #expect(
            MMEnvelope.decode(from: mpBytes("940301cf0000000100000000c0"))
                == .failure(.numberOutOfRange(target: "UInt32"))
        )
    }

    @Test("item slice covers exactly a nested container value")
    func nestedItemExtent() {
        // item = {1: [1, 2, "x"]}
        let itemHex = "8101930102a178"
        let decoded = MMEnvelope.decode(from: mpBytes("94030500" + itemHex))
        guard case .success(.item(let msgid, let seq, let item)) = decoded else {
            Issue.record("expected item, got \(decoded)")
            return
        }
        #expect(msgid == 5)
        #expect(seq == 0)
        #expect(mpHex(item) == itemHex)
    }

    @Test("arity 1, 3, and 5 are invalidArity — no tolerance on kind 3")
    func arityViolations() {
        #expect(
            MMEnvelope.decode(from: mpBytes("9103"))
                == .failure(.invalidArity(expected: 4, got: 1))
        )
        #expect(
            MMEnvelope.decode(from: mpBytes("93030100"))
                == .failure(.invalidArity(expected: 4, got: 3))
        )
        #expect(
            MMEnvelope.decode(from: mpBytes("95030100a178c0"))
                == .failure(.invalidArity(expected: 4, got: 5))
        )
    }

    @Test("invalid item slot fails encoding before any bytes are written")
    func invalidItemWritesNothing() {
        let incomplete = MMEnvelope.item(msgid: 1, seq: 0, item: mpBytes("9201"))
        var buffer = ByteBuffer()
        #expect(
            incomplete.encode(into: &buffer).mpFailure
                == .encodingFailed(
                    description: "item is not a single complete MessagePack value"
                )
        )
        #expect(buffer.readableBytes == 0)

        let trailing = MMEnvelope.item(msgid: 1, seq: 0, item: mpBytes("9000"))
        #expect(
            trailing.encode(into: &buffer).mpFailure
                == .encodingFailed(
                    description: "item has trailing bytes after one MessagePack value"
                )
        )
        #expect(buffer.readableBytes == 0)
    }
}

@Suite("MMEnvelope golden vectors — kind 4 END")
struct EndGoldenVectorTests {
    @Test("end encodes [4, 1, 0] and decodes")
    func canonicalVector() {
        let vector = "93040100"
        let envelope = MMEnvelope.end(msgid: 1)
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("msgid 0 and UInt32.max with pinned bytes")
    func boundaryValues() {
        let zeroVector = "93040000"
        #expect(MMEnvelope.end(msgid: 0).encoded().mpSuccess.map(mpHex) == zeroVector)
        #expect(MMEnvelope.decode(from: mpBytes(zeroVector)) == .success(.end(msgid: 0)))

        let maxVector = "9304ceffffffff00"
        #expect(MMEnvelope.end(msgid: .max).encoded().mpSuccess.map(mpHex) == maxVector)
        #expect(MMEnvelope.decode(from: mpBytes(maxVector)) == .success(.end(msgid: .max)))
    }

    @Test("reserved third element is ignored whatever its value")
    func reservedThirdElement() {
        // [4, 1, 99]
        #expect(MMEnvelope.decode(from: mpBytes("93040163")) == .success(.end(msgid: 1)))
        // [4, 1, [99]] — a container in the reserved slot is structurally skipped.
        #expect(MMEnvelope.decode(from: mpBytes("9304019163")) == .success(.end(msgid: 1)))
    }

    @Test("elements beyond the third are tolerated and ignored")
    func extraElements() {
        // [4, 1, 0, true]
        #expect(MMEnvelope.decode(from: mpBytes("94040100c3")) == .success(.end(msgid: 1)))
        // [4, 1, 0, [], 99]
        #expect(MMEnvelope.decode(from: mpBytes("950401009063")) == .success(.end(msgid: 1)))
    }

    @Test("arity 2 is invalidArity — the reserved slot must be present")
    func tooShort() {
        #expect(
            MMEnvelope.decode(from: mpBytes("920401"))
                == .failure(.invalidArity(expected: 3, got: 2))
        )
    }

    @Test("truncated tolerated element is truncated, not silently accepted")
    func truncatedExtraElement() {
        // Fourth element claims array2 but the frame ends.
        #expect(MMEnvelope.decode(from: mpBytes("9404010092")) == .failure(.truncated))
    }
}

@Suite("MMEnvelope golden vectors — kind 5 STOP")
struct StopGoldenVectorTests {
    @Test("stop [5, 1, 0] encodes and decodes")
    func canonicalVector() {
        let vector = "93050100"
        let envelope = MMEnvelope.stop(msgid: 1, code: 0)
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("reserved nonzero codes round trip with pinned bytes")
    func nonzeroCode() {
        let vector = "93050105"
        let envelope = MMEnvelope.stop(msgid: 1, code: 5)
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("msgid and code at 0 and UInt32.max with pinned bytes")
    func boundaryValues() {
        let zeroVector = "93050000"
        let zero = MMEnvelope.stop(msgid: 0, code: 0)
        #expect(zero.encoded().mpSuccess.map(mpHex) == zeroVector)
        #expect(MMEnvelope.decode(from: mpBytes(zeroVector)) == .success(zero))

        let maxVector = "9305ceffffffffceffffffff"
        let max = MMEnvelope.stop(msgid: .max, code: .max)
        #expect(max.encoded().mpSuccess.map(mpHex) == maxVector)
        #expect(MMEnvelope.decode(from: mpBytes(maxVector)) == .success(max))
    }

    @Test("non-canonical code width is tolerated on decode")
    func nonCanonicalCode() {
        // [5, 1, uint8 0]
        #expect(
            MMEnvelope.decode(from: mpBytes("930501cc00"))
                == .success(.stop(msgid: 1, code: 0))
        )
    }

    @Test("code wider than u32 is numberOutOfRange")
    func codeOverflow() {
        #expect(
            MMEnvelope.decode(from: mpBytes("930501cf0000000100000000"))
                == .failure(.numberOutOfRange(target: "UInt32"))
        )
    }

    @Test("arity 2 and arity 4 are invalidArity — no tolerance on kind 5")
    func arityViolations() {
        #expect(
            MMEnvelope.decode(from: mpBytes("920501"))
                == .failure(.invalidArity(expected: 3, got: 2))
        )
        #expect(
            MMEnvelope.decode(from: mpBytes("9405010000"))
                == .failure(.invalidArity(expected: 3, got: 4))
        )
    }
}

@Suite("MMEnvelope golden vectors — kind 6 CANCEL")
struct CancelGoldenVectorTests {
    @Test("cancel [6, 1] encodes and decodes")
    func canonicalVector() {
        let vector = "920601"
        let envelope = MMEnvelope.cancel(msgid: 1)
        #expect(envelope.encoded().mpSuccess.map(mpHex) == vector)
        #expect(MMEnvelope.decode(from: mpBytes(vector)) == .success(envelope))
    }

    @Test("msgid 0 and UInt32.max with pinned bytes")
    func boundaryValues() {
        let zeroVector = "920600"
        #expect(MMEnvelope.cancel(msgid: 0).encoded().mpSuccess.map(mpHex) == zeroVector)
        #expect(MMEnvelope.decode(from: mpBytes(zeroVector)) == .success(.cancel(msgid: 0)))

        let maxVector = "9206ceffffffff"
        #expect(MMEnvelope.cancel(msgid: .max).encoded().mpSuccess.map(mpHex) == maxVector)
        #expect(MMEnvelope.decode(from: mpBytes(maxVector)) == .success(.cancel(msgid: .max)))
    }

    @Test("extra elements are tolerated and ignored")
    func extraElements() {
        // [6, 1, 0]
        #expect(MMEnvelope.decode(from: mpBytes("93060100")) == .success(.cancel(msgid: 1)))
        // [6, 1, [], 99]
        #expect(MMEnvelope.decode(from: mpBytes("9406019063")) == .success(.cancel(msgid: 1)))
    }

    @Test("arity 1 is invalidArity")
    func tooShort() {
        #expect(
            MMEnvelope.decode(from: mpBytes("9106"))
                == .failure(.invalidArity(expected: 2, got: 1))
        )
    }

    @Test("truncated tolerated element is truncated, not silently accepted")
    func truncatedExtraElement() {
        // Third element claims str1 but the frame ends.
        #expect(MMEnvelope.decode(from: mpBytes("930601a1")) == .failure(.truncated))
    }
}

@Suite("MMEnvelope truncation at every byte position")
struct EnvelopeTruncationSweepTests {
    // One representative canonical frame per kind, hand-derived.
    static let framesByKind: [(kind: Int, hex: String)] = [
        (0, "940005c0c3"),
        (1, "950101a470696e67a3626f7890"),
        (2, "93020108"),
        (3, "94030100a178"),
        (4, "93040100"),
        (5, "93050100"),
        (6, "920601"),
    ]

    @Test("every strict prefix of a valid frame is truncated", arguments: framesByKind)
    func truncationSweep(frame: (kind: Int, hex: String)) {
        let full = mpBytes(frame.hex)
        for prefixLength in 0..<full.readableBytes {
            let prefix = full.getSlice(at: 0, length: prefixLength)!
            #expect(
                MMEnvelope.decode(from: prefix) == .failure(.truncated),
                "kind \(frame.kind), prefix of \(prefixLength) bytes"
            )
        }
    }
}

@Suite("MMEnvelope params/result slice extents")
struct EnvelopeSliceExtentTests {
    @Test("params slice covers exactly a nested container value")
    func nestedParamsExtent() {
        // params = {1: [1, 2, "x"]}
        let paramsHex = "8101930102a178"
        let decoded = MMEnvelope.decode(from: mpBytes("950105a16da0" + paramsHex))
        guard case .success(.request(let msgid, let method, _, let params)) = decoded else {
            Issue.record("expected request, got \(decoded)")
            return
        }
        #expect(msgid == 5)
        #expect(method == "m")
        #expect(mpHex(params) == paramsHex)
    }

    @Test("result slice covers exactly a nested container value")
    func nestedResultExtent() {
        // result = [{1: 2}, "ab", bin8(2 bytes)]
        let resultHex = "93810102a26162c402ffff"
        let decoded = MMEnvelope.decode(from: mpBytes("940001c0" + resultHex))
        guard case .success(.response(let msgid, let error, let result)) = decoded else {
            Issue.record("expected response, got \(decoded)")
            return
        }
        #expect(msgid == 1)
        #expect(error == nil)
        #expect(result.map(mpHex) == resultHex)
    }

    @Test("scalar params slice is exactly one byte")
    func scalarParamsExtent() {
        // [1, 5, "n", "", 42] — the request's params slice is the single byte 0x2a.
        let decoded = MMEnvelope.decode(from: mpBytes("950105a16ea02a"))
        #expect(
            decoded
                == .success(.request(msgid: 5, method: "n", entity: "", params: mpBytes("2a"))))
    }

    @Test("error payload slice covers exactly a nested value and extras are skipped")
    func errorPayloadExtentWithExtras() {
        // error = [1, "e", [1, 2], 99, "ex"] — trailing elements tolerated and skipped.
        let decoded = MMEnvelope.decode(from: mpBytes("9400019501a16592010263a26578c0"))
        #expect(
            decoded
                == .success(
                    .response(
                        msgid: 1,
                        error: MMError(code: 1, message: "e", payload: mpBytes("920102")),
                        result: nil
                    )
                )
        )
    }
}

@Suite("MMError wire form")
struct ErrorObjectTests {
    @Test("two-element form decodes with nil payload")
    func twoElementForm() {
        var buffer = mpBytes("92d180a7a26e6f")
        #expect(
            MMError.decode(from: &buffer)
                == .success(MMError(code: -32601, message: "no", payload: nil))
        )
        #expect(buffer.readableBytes == 0)
    }

    @Test("explicit nil payload slot decodes as absent payload")
    func explicitNilPayload() {
        var buffer = mpBytes("9301a165c0")
        #expect(
            MMError.decode(from: &buffer)
                == .success(MMError(code: 1, message: "e", payload: nil))
        )
    }

    @Test("extra trailing elements are tolerated and consumed")
    func extraElementsConsumed() {
        // [1, "e", nil, 99, "ex"] followed by an unrelated byte that must remain.
        var buffer = mpBytes("9501a165c063a2657859")
        #expect(
            MMError.decode(from: &buffer)
                == .success(MMError(code: 1, message: "e", payload: nil))
        )
        #expect(mpHex(buffer) == "59")
    }

    @Test("fewer than two elements is invalidArity")
    func shortErrorObject() {
        var oneElement = mpBytes("9101")
        #expect(
            MMError.decode(from: &oneElement)
                == .failure(.invalidArity(expected: 2, got: 1))
        )
        var empty = mpBytes("90")
        #expect(
            MMError.decode(from: &empty) == .failure(.invalidArity(expected: 2, got: 0))
        )
    }

    @Test("failed decode restores the reader index")
    func failureRestoresIndex() {
        var buffer = mpBytes("9101")
        let before = buffer.readerIndex
        _ = MMError.decode(from: &buffer)
        #expect(buffer.readerIndex == before)
    }
}

@Suite("MMEnvelope malformed input")
struct EnvelopeMalformedInputTests {
    @Test("unknown leading type int is unknownEnvelope")
    func unknownTypeTag() {
        // Tag 8: the first free tag after the v1 table.
        #expect(MMEnvelope.decode(from: mpBytes("92080a")) == .failure(.unknownEnvelope))
        #expect(MMEnvelope.decode(from: mpBytes("9108")) == .failure(.unknownEnvelope))
        // Tag 99.
        #expect(MMEnvelope.decode(from: mpBytes("9263c0")) == .failure(.unknownEnvelope))
        // Negative tag: still an int, still unknown.
        #expect(MMEnvelope.decode(from: mpBytes("91ff")) == .failure(.unknownEnvelope))
        #expect(MMEnvelope.decode(from: mpBytes("92ff00")) == .failure(.unknownEnvelope))
        // Empty array: no tag to read.
        #expect(MMEnvelope.decode(from: mpBytes("90")) == .failure(.unknownEnvelope))
    }

    @Test("wrong arity is a typed error, never a crash")
    func wrongArity() {
        // request with 3 elements
        #expect(
            MMEnvelope.decode(from: mpBytes("930101a16d"))
                == .failure(.invalidArity(expected: 5, got: 3))
        )
        // response with 2 elements
        #expect(
            MMEnvelope.decode(from: mpBytes("920001"))
                == .failure(.invalidArity(expected: 4, got: 2))
        )
        // response with 5 elements — the terminal has NO arity tolerance
        #expect(
            MMEnvelope.decode(from: mpBytes("950001c0c0c0"))
                == .failure(.invalidArity(expected: 4, got: 5))
        )
    }

    @Test("non-array envelope is a typeMismatch")
    func nonArrayEnvelope() {
        #expect(
            MMEnvelope.decode(from: mpBytes("810000"))
                == .failure(.typeMismatch(expected: "array", format: 0x81))
        )
    }

    @Test("msgid wider than u32 is numberOutOfRange")
    func msgidOverflow() {
        #expect(
            MMEnvelope.decode(from: mpBytes("9501cf0000000100000000a16da090"))
                == .failure(.numberOutOfRange(target: "UInt32"))
        )
    }

    @Test("non-canonical msgid width is tolerated on decode")
    func nonCanonicalMsgid() {
        #expect(
            MMEnvelope.decode(from: mpBytes("9501cc01a16da090"))
                == .success(.request(msgid: 1, method: "m", entity: "", params: mpBytes("90")))
        )
        // Non-canonical tag width is tolerated too.
        #expect(
            MMEnvelope.decode(from: mpBytes("93cc020108"))
                == .success(.credit(msgid: 1, credits: 8))
        )
    }

    @Test("truncated envelope is truncated")
    func truncatedEnvelope() {
        #expect(MMEnvelope.decode(from: mpBytes("950101a470")) == .failure(.truncated))
        #expect(MMEnvelope.decode(from: ByteBuffer()) == .failure(.truncated))
    }

    @Test("trailing bytes after the envelope array are rejected")
    func trailingBytes() {
        #expect(
            MMEnvelope.decode(from: mpBytes("950101a470696e67a3626f789000"))
                == .failure(
                    .decodingFailed(description: MMEnvelope.trailingBytesDescription)
                )
        )
        // Same for a fixed-shape streaming kind.
        #expect(
            MMEnvelope.decode(from: mpBytes("9302010800"))
                == .failure(
                    .decodingFailed(description: MMEnvelope.trailingBytesDescription)
                )
        )
    }
}

@Suite("MMEnvelope encode validation")
struct EnvelopeEncodeValidationTests {
    @Test("params that are not a single complete value fail encoding")
    func incompleteParams() {
        // array2 with only one element present
        let truncated = MMEnvelope.request(
            msgid: 1, method: "m", entity: "", params: mpBytes("9201"))
        #expect(
            truncated.encoded()
                == .failure(
                    .encodingFailed(
                        description: "params is not a single complete MessagePack value"
                    )
                )
        )
        let empty = MMEnvelope.request(msgid: 1, method: "n", entity: "", params: ByteBuffer())
        #expect(
            empty.encoded()
                == .failure(
                    .encodingFailed(
                        description: "params is not a single complete MessagePack value"
                    )
                )
        )
    }

    @Test("params with trailing bytes fail encoding")
    func paramsWithTrailingBytes() {
        let envelope = MMEnvelope.request(
            msgid: 1, method: "m", entity: "", params: mpBytes("9000"))
        #expect(
            envelope.encoded()
                == .failure(
                    .encodingFailed(
                        description: "params has trailing bytes after one MessagePack value"
                    )
                )
        )
    }

    @Test("invalid result slot fails encoding before any bytes are written")
    func invalidResultWritesNothing() {
        let envelope = MMEnvelope.response(msgid: 1, error: nil, result: mpBytes("92"))
        var buffer = ByteBuffer()
        let outcome = envelope.encode(into: &buffer)
        #expect(
            outcome.mpFailure
                == .encodingFailed(
                    description: "result is not a single complete MessagePack value"
                )
        )
        #expect(buffer.readableBytes == 0)
    }

    @Test("invalid error payload fails encoding before any bytes are written")
    func invalidErrorPayloadWritesNothing() {
        let envelope = MMEnvelope.response(
            msgid: 1,
            error: MMError(code: 1, message: "e", payload: mpBytes("c1")),
            result: nil
        )
        var buffer = ByteBuffer()
        let outcome = envelope.encode(into: &buffer)
        #expect(
            outcome.mpFailure
                == .encodingFailed(
                    description: "error payload is not a single complete MessagePack value"
                )
        )
        #expect(buffer.readableBytes == 0)
    }

    @Test("response with nil error and nil result round trips")
    func voidResponse() {
        let envelope = MMEnvelope.response(msgid: 9, error: nil, result: nil)
        let encoded = envelope.encoded()
        #expect(encoded.mpSuccess.map(mpHex) == "940009c0c0")
        #expect(MMEnvelope.decode(from: encoded.mpSuccess!) == .success(envelope))
    }
}

@Suite("MMEnvelope depth cap on raw slots")
struct EnvelopeDepthCapTests {
    /// `depth` nested single-element arrays around nil — one complete, spec-valid
    /// MessagePack value.
    private static func deepValue(depth: Int) -> ByteBuffer {
        var buffer = ByteBuffer()
        for _ in 0..<depth {
            buffer.writeMessagePackArrayHeader(count: 1)
        }
        buffer.writeMessagePackNil()
        return buffer
    }

    @Test("params beyond the default cap fail encode with the truthful nestingTooDeep")
    func encodeDepthCap() {
        // The value is complete and valid, so misreporting it as "not a single
        // complete MessagePack value" would send the caller debugging the wrong
        // thing; the typed depth error is required.
        let envelope = MMEnvelope.request(
            msgid: 1,
            method: "m",
            entity: "",
            params: Self.deepValue(depth: 200)
        )
        var buffer = ByteBuffer()
        #expect(envelope.encode(into: &buffer).mpFailure == .nestingTooDeep(limit: 128))
        #expect(buffer.readableBytes == 0)
        // An endpoint that raised its coder cap passes the matching cap through.
        #expect(envelope.encode(into: &buffer, maxDepth: 256).mpSuccess != nil)
    }

    @Test("decode honors a raised cap, symmetric with encode")
    func decodeDepthCap() {
        let envelope = MMEnvelope.request(
            msgid: 3,
            method: "n",
            entity: "",
            params: Self.deepValue(depth: 200)
        )
        let frame = envelope.encoded(maxDepth: 256).mpSuccess!
        #expect(MMEnvelope.decode(from: frame) == .failure(.nestingTooDeep(limit: 128)))
        #expect(MMEnvelope.decode(from: frame, maxDepth: 256) == .success(envelope))
    }

    @Test("params at exactly the default cap encode and decode without opting in")
    func defaultCapBoundary() {
        let envelope = MMEnvelope.request(
            msgid: 2,
            method: "m",
            entity: "",
            params: Self.deepValue(depth: 128)
        )
        let frame = envelope.encoded().mpSuccess!
        #expect(MMEnvelope.decode(from: frame) == .success(envelope))
    }

    @Test("item slot honors the depth cap on encode and decode, symmetric")
    func itemDepthCap() {
        let envelope = MMEnvelope.item(msgid: 1, seq: 0, item: Self.deepValue(depth: 200))
        var buffer = ByteBuffer()
        #expect(envelope.encode(into: &buffer).mpFailure == .nestingTooDeep(limit: 128))
        #expect(buffer.readableBytes == 0)
        let frame = envelope.encoded(maxDepth: 256).mpSuccess!
        #expect(MMEnvelope.decode(from: frame) == .failure(.nestingTooDeep(limit: 128)))
        #expect(MMEnvelope.decode(from: frame, maxDepth: 256) == .success(envelope))
    }
}

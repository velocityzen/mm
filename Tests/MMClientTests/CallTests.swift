import MMSchema
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMClient

@Suite("Calls: envelopes, multiplexing, error mapping")
struct CallTests {
    @Test("request envelope bytes are exact for a pinned fixture")
    func requestBytesPinned() async throws {
        let (result, _) = try await withRunningConnection { client in
            async let reply = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(7))
            let frame = try await withDeadline {
                try await client.channel.waitForOutboundWrite(as: ByteBuffer.self)
            }
            // Frame: u32 LE length 19, then [1, 1, "box.get", {0: "box", 1: 7}]:
            // fixarray(4), tag 0x01, msgid 1, fixstr "box.get",
            // [1, 1, "box.get", "box", {0: 7}] — the entity rides the
            // envelope; params are fixmap(1), key 0, positive fixint 7.
            let expected: [UInt8] = [
                0x12, 0x00, 0x00, 0x00,
                0x95,
                0x01,
                0x01,
                0xa7, 0x62, 0x6f, 0x78, 0x2e, 0x67, 0x65, 0x74,
                0xa3, 0x62, 0x6f, 0x78,
                0x81,
                0x00, 0x07,
            ]
            #expect(allBytes(frame) == expected)
            try await client.channel.writeInbound(
                responseFrame(msgid: 1, result: BoxResponse(value: 42))
            )
            return await reply
        }
        #expect(result == .success(BoxResponse(value: 42)))
    }

    @Test("out-of-order responses resolve the right continuations")
    func outOfOrderResponses() async throws {
        let values: [UInt8] = [1, 2, 3]
        let (outcomes, _) = try await withRunningConnection { client in
            try await withThrowingTaskGroup(
                of: (UInt8, Result<BoxResponse, MMCallError>).self,
                returning: [UInt8: Result<BoxResponse, MMCallError>].self
            ) { calls in
                for value in values {
                    calls.addTask {
                        (
                            value,
                            await client.connection.call(
                                ClientTestMethods.boxGet, on: entity("box"), boxRequest(value))
                        )
                    }
                }
                var requests: [(msgid: UInt32, value: UInt8)] = []
                for _ in values {
                    let (msgid, method, params) = try await client.readRequestFrame()
                    #expect(method == "box.get")
                    let request = try MMPackDecoder().decode(BoxRequest.self, from: params).get()
                    requests.append((msgid, request.value))
                }
                // Respond in reverse arrival order, each echoing value + 100.
                for (msgid, value) in requests.reversed() {
                    try await client.channel.writeInbound(
                        responseFrame(msgid: msgid, result: BoxResponse(value: value + 100))
                    )
                }
                var collected: [UInt8: Result<BoxResponse, MMCallError>] = [:]
                for try await (value, outcome) in calls {
                    collected[value] = outcome
                }
                return collected
            }
        }
        for value in values {
            #expect(outcomes[value] == .success(BoxResponse(value: value + 100)))
        }
    }

    @Test("protocol error codes map to dedicated cases; others arrive as .remote")
    func errorObjectMapping() async throws {
        let custom = MMErrorObject(code: 64, message: "boom", payload: encodedParams(UInt8(9)))
        let cases: [(MMErrorObject, MMCallError)] = [
            (MMErrorObject(code: 1, message: "nope"), .unknownMethod),
            (MMErrorObject(code: 2, message: "denied"), .denied),
            (MMErrorObject(code: 3, message: "bad"), .malformedParams),
            (MMErrorObject(code: 4, message: "busy"), .tooManyInFlight),
            (MMErrorObject(code: 5, message: "oops"), .remoteInternal),
            // Application code with payload: preserved verbatim.
            (custom, .remote(custom)),
            // Reserved-but-unassigned protocol code: open world, not a crash.
            (
                MMErrorObject(code: 63, message: "future"),
                .remote(MMErrorObject(code: 63, message: "future"))
            ),
        ]
        for (errorObject, expected) in cases {
            let (outcome, _) = try await withRunningConnection { client in
                async let reply = client.connection.call(
                    ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
                let (msgid, _, _) = try await client.readRequestFrame()
                try await client.channel.writeInbound(errorFrame(msgid: msgid, errorObject))
                return await reply
            }
            #expect(outcome == .failure(expected))
        }
    }

    @Test("an undecodable result fails exactly that call, not its neighbor")
    func undecodableResultFailsSameCall() async throws {
        // The result slot holds a string where BoxResponse expects a map;
        // compute the exact decode error the client must surface.
        let garbage = encodedParams("not a map")
        let expectedError = try #require(
            failure(MMPackDecoder().decode(BoxResponse.self, from: garbage))
        )
        let ((first, second), _) = try await withRunningConnection { client in
            async let callA = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
            let (msgidA, _, _) = try await client.readRequestFrame()
            async let callB = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(2))
            let (msgidB, _, _) = try await client.readRequestFrame()
            let badResponse = try MMEnvelope.response(msgid: msgidA, error: nil, result: garbage)
                .encoded().get()
            try await client.channel.writeInbound(framed(badResponse))
            try await client.channel.writeInbound(
                responseFrame(msgid: msgidB, result: BoxResponse(value: 102))
            )
            return (await callA, await callB)
        }
        #expect(first == .failure(.decode(expectedError)))
        #expect(second == .success(BoxResponse(value: 102)))
    }

    @Test("a void success ([0, msgid, nil, nil]) resolves an Optional result with nil")
    func voidSuccessResolvesOptionalResult() async throws {
        // Wire spec (MMWire.docc/WireProtocol.md) §4: a response with nil in both slots is a
        // valid void success. For a method whose result type is Optional, it
        // decodes as .success(nil).
        let maybe = Method<BoxRequest, BoxResponse?>(name: "box.maybe", access: .read)
        let (outcome, _) = try await withRunningConnection { client in
            async let reply = client.connection.call(maybe, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()
            let empty = try MMEnvelope.response(msgid: msgid, error: nil, result: nil)
                .encoded().get()
            try await client.channel.writeInbound(framed(empty))
            return await reply
        }
        #expect(outcome == .success(nil))
    }

    @Test("a void success against a non-optional result is a truthful decode failure")
    func voidSuccessAgainstNonOptionalResultFailsDecode() async throws {
        // The nil result slot decodes as the MessagePack nil value (0xc0);
        // a non-optional result type fails with the same decode error it
        // would produce for an explicit nil payload — never .truncated
        // (nothing was truncated) and never a connection death.
        let expectedError = try #require(
            failure(MMPackDecoder().decode(BoxResponse.self, from: ByteBuffer(bytes: [0xc0])))
        )
        let (outcome, _) = try await withRunningConnection { client in
            async let reply = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()
            let empty = try MMEnvelope.response(msgid: msgid, error: nil, result: nil)
                .encoded().get()
            try await client.channel.writeInbound(framed(empty))
            return await reply
        }
        #expect(outcome == .failure(.decode(expectedError)))
    }

    @Test("cancellation abandons the msgid; a late response is dropped, the map stays sound")
    func cancellationAbandonsMsgid() async throws {
        let (outcome, _) = try await withRunningConnection { client in
            let (cancelled, abandonedMsgid) = await withTaskGroup(
                of: Result<BoxResponse, MMCallError>.self,
                returning: (Result<BoxResponse, MMCallError>, UInt32).self
            ) { group in
                group.addTask {
                    await client.connection.call(
                        ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
                }
                // The request reached the wire, so the msgid is live.
                guard let (msgid, _, _) = try? await client.readRequestFrame() else {
                    group.cancelAll()
                    return (await group.next() ?? .failure(.cancelled), 0)
                }
                group.cancelAll()
                guard let result = await group.next() else {
                    return (.failure(.cancelled), msgid)
                }
                return (result, msgid)
            }
            #expect(cancelled == .failure(.cancelled))
            #expect(abandonedMsgid == 1)
            // Late response for the abandoned msgid: dropped, no crash, no
            // misdelivery to the follow-up call.
            try await client.channel.writeInbound(
                responseFrame(msgid: abandonedMsgid, result: BoxResponse(value: 99))
            )
            // Follow-up call reuses the (now clean) pending map.
            async let followUp = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(2))
            let (nextMsgid, _, _) = try await client.readRequestFrame()
            #expect(nextMsgid != abandonedMsgid)
            try await client.channel.writeInbound(
                responseFrame(msgid: nextMsgid, result: BoxResponse(value: 102))
            )
            return await followUp
        }
        #expect(outcome == .success(BoxResponse(value: 102)))
    }

    @Test("in-flight cap: the excess call fails immediately, the admitted ones complete")
    func inFlightCapBoundsCalls() async throws {
        let configuration = MMClientConfiguration(maxInFlightCalls: 2)
        let (outcomes, _) = try await withRunningConnection(configuration: configuration) {
            client in
            try await withThrowingTaskGroup(
                of: (UInt8, Result<BoxResponse, MMCallError>).self,
                returning: [(UInt8, Result<BoxResponse, MMCallError>)].self
            ) { calls in
                for value: UInt8 in [1, 2, 3] {
                    calls.addTask {
                        (
                            value,
                            await client.connection.call(
                                ClientTestMethods.boxGet, on: entity("box"), boxRequest(value))
                        )
                    }
                }
                // Both admitted requests reach the wire...
                var requests: [(msgid: UInt32, value: UInt8)] = []
                for _ in 0..<2 {
                    let (msgid, _, params) = try await client.readRequestFrame()
                    let request = try MMPackDecoder().decode(BoxRequest.self, from: params).get()
                    requests.append((msgid, request.value))
                }
                // ...and the rejected call is the only one that can finish
                // before any response is written: collecting it first proves
                // the third reservation happened while both slots were held.
                // (Bounded by withRunningConnection's outer deadline.)
                let rejected = try #require(await calls.next())
                var collected = [rejected]
                for (msgid, value) in requests {
                    try await client.channel.writeInbound(
                        responseFrame(msgid: msgid, result: BoxResponse(value: value + 100))
                    )
                }
                for try await outcome in calls {
                    collected.append(outcome)
                }
                return collected
            }
        }
        let rejections = outcomes.filter { $0.1 == .failure(.tooManyInFlight) }
        #expect(rejections.count == 1)
        for (value, outcome) in outcomes where outcome != .failure(.tooManyInFlight) {
            #expect(outcome == .success(BoxResponse(value: value + 100)))
        }
    }

    @Test("calls issued before run() park and complete once the loop starts")
    func callBeforeRunParks() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0))
        )
        let connection = try await establish(harness).get()
        let outcome = try await withThrowingTaskGroup(
            of: Result<BoxResponse, MMCallError>?.self,
            returning: Result<BoxResponse, MMCallError>.self
        ) { group in
            group.addTask {
                // Issued before run(): parks on the writer slot.
                await connection.call(ClientTestMethods.boxGet, on: entity("box"), boxRequest(5))
            }
            group.addTask {
                _ = await connection.run()
                return nil
            }
            let frame = try await withDeadline {
                try await harness.channel.waitForOutboundWrite(as: ByteBuffer.self)
            }
            let (msgid, _, _) = try requestParts(of: frame)
            try await harness.channel.writeInbound(
                responseFrame(msgid: msgid, result: BoxResponse(value: 105))
            )
            var result: Result<BoxResponse, MMCallError>?
            for try await candidate in group {
                if let candidate {
                    result = candidate
                    await connection.close()
                }
            }
            return try #require(result)
        }
        #expect(outcome == .success(BoxResponse(value: 105)))
    }

    @Test("cancellation during a backpressured write is .cancelled, not .connectionClosed")
    func cancellationDuringBackpressuredWrite() async throws {
        _ = try await withRunningConnection { client in
            // Make the channel unwritable so writer.write suspends on
            // outbound backpressure instead of completing.
            try await makeUnwritable(client)
            let result = NIOLockedValueBox<Result<BoxResponse, MMCallError>?>(nil)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let reply = await client.connection.call(
                        ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
                    result.withLockedValue { $0 = reply }
                }
                // Give the call a chance to reach the suspended write, then
                // cancel it. Whichever point cancellation lands (entry check,
                // suspended yield, already-cancelled yield), the contract is
                // the same: .cancelled on a connection that stays .connected.
                for _ in 0..<20 { await Task.yield() }
                group.cancelAll()
                await group.waitForAll()
            }
            #expect(result.withLockedValue { $0 } == .failure(.cancelled))
            // The connection did not die: cancellation is local abandonment.
            #expect(client.connection.state == .connected)
        }
    }

    @Test("an oversized outbound request fails that call locally, not the connection")
    func oversizedOutboundRequestFailsOnlyThatCall() async throws {
        // Cap small enough that the padded request trips it while the hello
        // (15 bytes) and the ordinary box.get request (19 bytes) pass.
        let configuration = MMClientConfiguration(maxFrameLength: 64)
        let (outcome, runResult) = try await withRunningConnection(
            configuration: configuration
        ) { client in
            let oversized = await client.connection.call(
                ClientTestMethods.boxPad, on: entity("box"),
                PadRequest(blob: Array(repeating: 0xAB, count: 200))
            )
            guard case .failure(.encode(.frameTooLarge(_, let limit))) = oversized else {
                Issue.record("expected .encode(.frameTooLarge), got \(oversized)")
                return oversized
            }
            #expect(limit == 64)
            // The connection survived: an unrelated call still round-trips.
            async let reply = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(2))
            let (msgid, _, _) = try await client.readRequestFrame()
            try await client.channel.writeInbound(
                responseFrame(msgid: msgid, result: BoxResponse(value: 102))
            )
            #expect(await reply == .success(BoxResponse(value: 102)))
            return oversized
        }
        #expect(failure(runResult) == nil)
        _ = outcome
    }

    @Test("an inbound request envelope is dropped; the connection stays usable")
    func inboundRequestIsDroppedNotFatal() async throws {
        let (outcome, runResult) = try await withRunningConnection { client in
            let bogusRequest = try MMEnvelope.request(
                msgid: 9,
                method: "client.poke",
                entity: "",
                params: encodedParams(UInt8(1))
            ).encoded().get()
            try await client.channel.writeInbound(framed(bogusRequest))
            async let reply = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(3))
            let (msgid, _, _) = try await client.readRequestFrame()
            try await client.channel.writeInbound(
                responseFrame(msgid: msgid, result: BoxResponse(value: 103))
            )
            return await reply
        }
        #expect(outcome == .success(BoxResponse(value: 103)))
        #expect(failure(runResult) == nil)
    }
}

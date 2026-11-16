import MMSchema
import MMTestSupport
import MMWire
import NIOCore
import Testing

@testable import MMClient

/// Calls whose requests and request-stream elements are constrained.
private enum Gate: MethodNamespace {
    #schema("gate") {
        Call("put") {
            Access { .write }
            Request {
                Field("limit", .int, constraints: .range(1...100))
            }
            Response {
                Field("count", .int)
            }
        }
        Call("watch") {
            Access { .read }
            Request {
                Field("from", .int, constraints: .range(0...))
            }
            ResponseStream {
                Field("n", .int)
            }
            Response {
                Field("sent", .int)
            }
        }
        Call("fill") {
            Access { .write }
            RequestStream {
                Field("text", .string, constraints: .nonEmpty)
            }
            Response {
                Field("filled", .int)
            }
        }
    }
}

/// `gate.put` as a release build of the declaring module describes it: the
/// check is there, and the client does not run it.
private let releasePut = Method<Gate.PutRequest, Gate.PutResponse>(
    name: "gate.put", access: .write,
    requestCheck: MMConstraintCheck(beforeSending: false))

/// Reads the next request the client sends and checks it is the one `body`
/// sent: a refused call before it sent nothing.
private func expectNextRequest(
    _ client: ConnectedClient,
    method: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> UInt32 {
    let (msgid, sent, _) = try await client.readRequestFrame()
    #expect(sent == method, sourceLocation: sourceLocation)
    return msgid
}

@Suite("Client: constraints checked before sending in debug builds")
struct ConstraintCheckTests {
    @Test("this test target is a debug build of the declaring module")
    func debugBuild() {
        #if DEBUG
            #expect(Gate.put.requestCheck?.beforeSending == true)
        #endif
    }

    @Test("a debug client refuses a violating request without sending it")
    func unaryRefused() async throws {
        #if DEBUG
            _ = try await withRunningConnection { client in
                let refused = await client.connection.call(
                    Gate.put, on: entity("box"), Gate.PutRequest(limit: 0))
                #expect(
                    refused == .failure(.invalidRequest(path: "limit", problem: "is 0, less than the minimum 1")))
                // The next frame on the wire is the next call's: the refused
                // one sent nothing.
                async let next = client.connection.call(
                    ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
                let msgid = try await expectNextRequest(client, method: "box.get")
                try await client.channel.writeInbound(
                    responseFrame(msgid: msgid, result: BoxResponse(value: 1)))
                #expect(await next == .success(BoxResponse(value: 1)))
            }
        #endif
    }

    @Test("a request that keeps its constraints is sent")
    func unaryAccepted() async throws {
        _ = try await withRunningConnection { client in
            async let reply = client.connection.call(
                Gate.put, on: entity("box"), Gate.PutRequest(limit: 1))
            let msgid = try await expectNextRequest(client, method: "gate.put")
            try await client.channel.writeInbound(
                responseFrame(msgid: msgid, result: Gate.PutResponse(count: 1)))
            #expect(await reply == .success(Gate.PutResponse(count: 1)))
        }
    }

    @Test("a release client sends a violating request, and the server's answer names the field")
    func releaseSends() async throws {
        _ = try await withRunningConnection { client in
            async let reply = client.connection.call(
                releasePut, on: entity("box"), Gate.PutRequest(limit: 0))
            let msgid = try await expectNextRequest(client, method: "gate.put")
            let refusal = MMError(code: 3, message: "malformed params: limit: is 0, less than the minimum 1")
            try await client.channel.writeInbound(errorFrame(msgid: msgid, refusal))
            #expect(await reply == .failure(.malformedParams(refusal)))
        }
    }

    @Test("a debug client refuses to open a stream whose request breaks a constraint")
    func streamOpenRefused() async throws {
        #if DEBUG
            _ = try await withRunningConnection { client in
                let handle = await client.connection.call(
                    Gate.watch, on: entity("box"), Gate.WatchRequest(from: -1))
                #expect(
                    await handle.result()
                        == .failure(.invalidRequest(path: "from", problem: "is -1, less than the minimum 0")))
                var elements = 0
                for await _ in handle { elements += 1 }
                #expect(elements == 0)
                async let next = client.connection.call(
                    ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
                let msgid = try await expectNextRequest(client, method: "box.get")
                try await client.channel.writeInbound(
                    responseFrame(msgid: msgid, result: BoxResponse(value: 1)))
                _ = await next
            }
        #endif
    }

    @Test("a debug client refuses a violating element, ends the call naming the item, and cancels it")
    func elementRefused() async throws {
        #if DEBUG
            _ = try await withRunningConnection { client in
                let handle = await client.connection.call(
                    Gate.fill, on: entity("box"), Gate.FillRequest())
                let msgid = try await expectNextRequest(client, method: "gate.fill")
                #expect(await handle.send(Gate.FillRequestItem(text: "a")) == .sent)
                guard case .item(msgid, 0, _) = try await readOutboundEnvelope(client) else {
                    Issue.record("the first element did not reach the wire")
                    return
                }
                #expect(await handle.send(Gate.FillRequestItem(text: "")) == .callEnded)
                #expect(
                    await handle.result()
                        == .failure(
                            .invalidRequest(
                                path: "[1].text", problem: "has length 0, less than the minimum length 1")))
                // What follows on the wire is the CANCEL, not the element.
                #expect(try await readOutboundEnvelope(client) == .cancel(msgid: msgid))
                // Later sends find the call ended.
                #expect(await handle.send(Gate.FillRequestItem(text: "b")) == .callEnded)
            }
        #endif
    }
}

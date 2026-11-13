// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOConcurrencyHelpers
    import NIOCore
    import Testing

    @testable import MMServer

    /// A ``StreamControl`` whose request source the machine drives: the credit
    /// it holds and whether it has ended. The table only reads these; every
    /// effect it decides on is applied by the connection, so the rest are
    /// no-ops here.
    final class ModelStreamControl: StreamControl {
        struct Source {
            var credit: Int
            var terminated = false
        }

        let hasRequestStream: Bool
        let hasResponseStream: Bool
        private let source: NIOLockedValueBox<Source>

        init(request: Bool, response: Bool) {
            self.hasRequestStream = request
            self.hasResponseStream = response
            let window = request ? Int(MMStreamFlowControl.initialWindow) : 0
            self.source = NIOLockedValueBox(Source(credit: window))
        }

        var credit: Int { self.source.withLockedValue { $0.credit } }
        var terminated: Bool { self.source.withLockedValue { $0.terminated } }

        /// The consumer drained `count` items, so the source has room for them again.
        func grantRequest(_ count: Int) { self.source.withLockedValue { $0.credit += count } }
        /// The handler returned or stopped consuming its request stream.
        func terminateRequest() { self.source.withLockedValue { $0.terminated = true } }

        func requestHasCredit() -> Bool { self.hasRequestStream && self.credit > 0 }

        func requestSourceTerminated() -> Bool {
            guard self.hasRequestStream else { return true }
            return self.terminated
        }

        /// The source spends a credit on every item it takes.
        func deliver(_ item: ByteBuffer) -> Result<Void, MMWireError> {
            self.source.withLockedValue { $0.credit -= 1 }
            return .success(())
        }

        func clientEndRequest() {}
        func grantResponse(_ credits: UInt32) {}
        func clientStopResponse() {}
        func endStreams() {}
        func cancelHandler() {}
        func attachCancel(_ cancel: @escaping @Sendable () -> Void) {}
    }

    /// What the table decided, without the control it carries.
    enum RouteOutcome: Equatable {
        case deliver, end, violation, unaryViolation, drop
    }

    extension StreamTable.ItemDecision {
        var outcome: RouteOutcome {
            switch self {
                case .deliver: .deliver
                case .violation: .violation
                case .unaryViolation: .unaryViolation
                case .drop: .drop
            }
        }

        var control: (any StreamControl)? {
            switch self {
                case .deliver(let control, _), .violation(let control): control
                case .unaryViolation, .drop: nil
            }
        }
    }

    extension StreamTable.EndDecision {
        var outcome: RouteOutcome {
            switch self {
                case .end: .end
                case .violation: .violation
                case .unaryViolation: .unaryViolation
                case .drop: .drop
            }
        }

        var control: (any StreamControl)? {
            switch self {
                case .end(let control), .violation(let control): control
                case .unaryViolation, .drop: nil
            }
        }
    }

    /// Whether the table handed back this call's own control.
    func isControl(_ control: (any StreamControl)?, of call: StreamTableModel.StreamCall) -> Bool {
        (control as? ModelStreamControl) === call.control
    }

    /// A running handler. It outlives its call when a CANCEL or a violation
    /// answers the call first, and may return after the msgid holds a new one.
    struct RunningHandler: Sendable, CustomStringConvertible {
        let msgid: UInt32
        let call: StreamTable.CallIdentity
        let isStream: Bool

        var description: String {
            "\(isStream ? "stream" : "unary") handler on msgid \(msgid), \(call)"
        }
    }

    /// `StreamTable` and the calls it should hold, one per msgid at most.
    struct StreamTableModel {
        /// A live call on a msgid.
        enum Call {
            case unary(StreamTable.CallIdentity)
            case stream(StreamCall)

            var identity: StreamTable.CallIdentity {
                switch self {
                    case .unary(let call): call
                    case .stream(let stream): stream.call
                }
            }
        }

        struct StreamCall {
            let call: StreamTable.CallIdentity
            let control: ModelStreamControl
            var expectedSeq: UInt32 = 0
            var requestEnded = false
        }

        var table = StreamTable()
        /// The live call on each msgid; absent when the msgid is free.
        var calls: [UInt32: Call] = [:]
        /// Every handler that has not returned yet.
        let handlers: Pool<RunningHandler>
        /// The terminals the connection sent for each call.
        var terminals: [StreamTable.CallIdentity: Int] = [:]
        /// Every msgid a frame has named, live or not.
        var seen: Set<UInt32> = []

        init(handlers: Pool<RunningHandler>) {
            self.handlers = handlers
        }

        mutating func open(_ call: Call, on msgid: UInt32) throws {
            self.calls[msgid] = call
            self.terminals[call.identity] = 0
            let isStream = if case .stream = call { true } else { false }
            try self.handlers.add(
                RunningHandler(msgid: msgid, call: call.identity, isStream: isStream)
            )
        }

        /// The connection answers the live call on `msgid` and frees the msgid.
        /// A call is answered once, whatever ends it.
        mutating func answer(_ msgid: UInt32) {
            guard let call = self.calls.removeValue(forKey: msgid)?.identity else {
                Issue.record("msgid \(msgid) has no live call to answer")
                return
            }
            self.terminals[call, default: 0] += 1
            #expect(self.terminals[call, default: 0] == 1, "msgid \(msgid) answered twice")
        }

        /// A handler returns. Its terminal goes out only when its own call is
        /// still live; one a CANCEL or a violation answered already finds the
        /// msgid free, or holding a newer call it must leave alone.
        mutating func finish(_ handler: RunningHandler) {
            let live = self.calls[handler.msgid]?.identity == handler.call
            let sends =
                if handler.isStream {
                    self.table.retireStream(msgid: handler.msgid, call: handler.call)
                } else {
                    self.table.consumeUnaryTerminal(msgid: handler.msgid, call: handler.call)
                }
            #expect(sends == live, "\(handler)")
            if sends {
                self.answer(handler.msgid)
            }
        }

        func stream(_ msgid: UInt32) -> StreamCall? {
            guard case .stream(let call) = self.calls[msgid] else { return nil }
            return call
        }

        /// Any msgid, or often one a frame named before, so calls collide
        /// and reuse msgids.
        mutating func msgid(from tc: TestCase) throws -> UInt32 {
            let any = Gen<UInt32>.integer()
            let msgid = try tc.draw(
                self.seen.isEmpty ? any : .oneOf(.element(of: self.seen.sorted()), any),
                named: "msgid"
            )
            self.seen.insert(msgid)
            return msgid
        }

        /// One of the live streams with a request direction, for the rules
        /// that act on what the handler does with it.
        func requestStream(from tc: TestCase) throws -> StreamCall {
            let msgids = self.calls.keys.filter { self.stream($0)?.control.hasRequestStream == true }
            try tc.assume(!msgids.isEmpty)
            let msgid = try tc.draw(.element(of: msgids.sorted()), named: "msgid")
            return try #require(self.stream(msgid))
        }

        var streamCount: Int {
            self.calls.values.count(where: { if case .stream = $0 { true } else { false } })
        }
    }

    /// How far an item's seq is from the one expected: usually 0, sometimes a
    /// gap, a repeat (`UInt32.max` wraps to one behind), or anything.
    let seqOffsets: Gen<UInt32> = Gen { tc in
        try tc.draw(.bool(probability: 0.2)) ? tc.draw(.integer(in: 1...UInt32.max)) : 0
    }

    /// Frames from the client and handler returns, in any order, on any msgid,
    /// live or not. Handlers return late too: after their call was answered,
    /// and after the client reused its msgid.
    let streamTableMachine = StateMachine<StreamTableModel>(steps: 200)
        .rule("open stream", weight: 2) { s, tc in
            let msgid = try s.msgid(from: tc)
            let request = try #draw(.bool(probability: 0.7), from: tc)
            let response = try #draw(.bool(), from: tc)
            let control = ModelStreamControl(request: request, response: response)
            let entry = StreamTable.Entry(
                control: control,
                hasRequestStream: request,
                hasResponseStream: response
            )
            let call = s.table.registerStream(msgid: msgid, entry: entry)
            #expect((call != nil) == (s.calls[msgid] == nil))
            if let call {
                try s.open(.stream(StreamTableModel.StreamCall(call: call, control: control)), on: msgid)
            }
        }
        .rule("open unary") { s, tc in
            let msgid = try s.msgid(from: tc)
            let call = s.table.registerUnary(msgid: msgid)
            #expect((call != nil) == (s.calls[msgid] == nil))
            if let call {
                try s.open(.unary(call), on: msgid)
            }
        }
        .rule("item", weight: 4) { s, tc in
            let msgid = try s.msgid(from: tc)
            let offset = try #draw(seqOffsets, from: tc)
            switch s.calls[msgid] {
                case nil:
                    let decision = s.table.routeItem(msgid: msgid, seq: offset)
                    #expect(decision.outcome == .drop)
                case .unary:
                    let decision = s.table.routeItem(msgid: msgid, seq: offset)
                    #expect(decision.outcome == .unaryViolation)
                    s.answer(msgid)
                case .stream(var call):
                    let control = call.control
                    let expected: RouteOutcome =
                        if !control.hasRequestStream {
                            .violation
                        } else if call.requestEnded || control.terminated {
                            .drop
                        } else if offset != 0 || control.credit == 0 {
                            .violation
                        } else {
                            .deliver
                        }
                    let decision = s.table.routeItem(msgid: msgid, seq: call.expectedSeq &+ offset)
                    #expect(decision.outcome == expected)
                    switch decision {
                        case .deliver(let delivered, let identity):
                            #expect(isControl(delivered, of: call))
                            #expect(identity == call.call)
                            _ = control.deliver(ByteBuffer())
                            call.expectedSeq &+= 1
                            s.calls[msgid] = .stream(call)
                        case .violation(let violated):
                            #expect(isControl(violated, of: call))
                            s.answer(msgid)
                        case .unaryViolation, .drop:
                            break
                    }
            }
        }
        .rule("end request") { s, tc in
            let msgid = try s.msgid(from: tc)
            let decision = s.table.routeEnd(msgid: msgid)
            switch s.calls[msgid] {
                case nil:
                    #expect(decision.outcome == .drop)
                case .unary:
                    #expect(decision.outcome == .unaryViolation)
                    s.answer(msgid)
                case .stream(var call):
                    if !call.control.hasRequestStream {
                        #expect(decision.outcome == .violation)
                        #expect(isControl(decision.control, of: call))
                        s.answer(msgid)
                    } else if call.requestEnded {
                        #expect(decision.outcome == .drop)
                    } else {
                        #expect(decision.outcome == .end)
                        #expect(isControl(decision.control, of: call))
                        call.requestEnded = true
                        s.calls[msgid] = .stream(call)
                    }
            }
        }
        .rule("grant response credit") { s, tc in
            let msgid = try s.msgid(from: tc)
            let control = s.table.routeCredit(msgid: msgid)
            if let call = s.stream(msgid), call.control.hasResponseStream {
                #expect(isControl(control, of: call))
            } else {
                #expect(control == nil)
            }
        }
        .rule("stop response") { s, tc in
            let msgid = try s.msgid(from: tc)
            let control = s.table.routeStop(msgid: msgid)
            if let call = s.stream(msgid), call.control.hasResponseStream {
                #expect(isControl(control, of: call))
            } else {
                #expect(control == nil)
            }
        }
        .rule("cancel") { s, tc in
            let msgid = try s.msgid(from: tc)
            let control = s.table.routeCancel(msgid: msgid)
            if let call = s.stream(msgid) {
                #expect(isControl(control, of: call))
                s.answer(msgid)
            } else {
                // Unknown msgids drop, and unary calls answer for themselves.
                #expect(control == nil)
            }
        }
        .rule("consumer drains") { s, tc in
            let call = try s.requestStream(from: tc)
            // The table reads only whether credit is left, so a grant of any
            // size a UInt32 window holds.
            let count = try #draw(.int(in: 1...Int(UInt32.max)), from: tc)
            call.control.grantRequest(count)
        }
        .rule("handler stops consuming") { s, tc in
            try s.requestStream(from: tc).control.terminateRequest()
        }
        .rule("handler returns", weight: 2) { s, tc in
            let handler = try #draw(s.handlers.consumed, from: tc)
            s.finish(handler)
        }
        .invariant("the table holds the model's calls", everyStep: true) { s, _ in
            for msgid in s.seen {
                #expect(s.table.isStreamLive(msgid: msgid) == (s.stream(msgid) != nil), "msgid \(msgid)")
                #expect(s.table.isOwned(msgid: msgid) == (s.calls[msgid] != nil), "msgid \(msgid)")
            }
            #expect(s.table.openStreamCount == s.streamCount)
            #expect(s.table.liveControls().count == s.streamCount)
        }

    @Suite("Stream table properties", .hegel)
    struct StreamTableProperties {
        /// Never two terminals for one call, never an item past the credit
        /// window, a handler only ever retires its own call, and once every
        /// handler returns, every call has had exactly one terminal.
        @Test(.hegel(testCases: 300))
        func everyCallIsAnsweredOnce() throws {
            try property { tc in
                var s = try streamTableMachine.run(tc, from: StreamTableModel(handlers: tc.pool()))
                while !s.handlers.isEmpty {
                    s.finish(try tc.draw(s.handlers.consumed, named: "handler"))
                }
                for msgid in s.seen {
                    #expect(!s.table.isOwned(msgid: msgid), "msgid \(msgid)")
                }
                #expect(s.calls.isEmpty)
                #expect(s.terminals.values.allSatisfy { $0 == 1 }, "\(s.terminals)")
            }
        }
    }

#endif

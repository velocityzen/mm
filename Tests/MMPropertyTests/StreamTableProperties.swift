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
                case .deliver(let control), .violation(let control): control
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

    /// `StreamTable` and the calls it should hold, one per msgid at most.
    struct StreamTableModel {
        /// A live call on a msgid.
        enum Call {
            /// A unary call. `suppressed` once a stream frame hit it and the
            /// connection answered with a code-6 terminal for it.
            case unary(suppressed: Bool)
            case stream(StreamCall)
        }

        struct StreamCall {
            let control: ModelStreamControl
            var expectedSeq: UInt32 = 0
            var requestEnded = false
        }

        var table = StreamTable()
        /// The live call on each msgid; absent when the msgid is free.
        var calls: [UInt32: Call] = [:]
        /// The terminals the connection sent for the latest call on each msgid.
        var terminals: [UInt32: Int] = [:]

        mutating func open(_ call: Call, on msgid: UInt32) {
            self.calls[msgid] = call
            self.terminals[msgid] = 0
        }

        /// The connection sends a terminal for the call on `msgid`. A call is
        /// answered once, whatever ends it.
        mutating func sendTerminal(_ msgid: UInt32) {
            self.terminals[msgid, default: 0] += 1
            #expect(self.terminals[msgid, default: 0] == 1, "msgid \(msgid) answered twice")
        }

        func stream(_ msgid: UInt32) -> StreamCall? {
            guard case .stream(let call) = self.calls[msgid] else { return nil }
            return call
        }

        var streamCount: Int {
            self.calls.values.count(where: { if case .stream = $0 { true } else { false } })
        }
    }

    /// A few msgids, so calls collide and reuse them.
    let msgids: Gen<UInt32> = .integer(in: 1...3)

    /// How far an item's seq is from the one expected: usually 0, sometimes a
    /// gap, a repeat (`UInt32.max` wraps to one behind), or anything.
    let seqOffsets: Gen<UInt32> = Gen { tc in
        try tc.draw(.bool(probability: 0.2)) ? tc.draw(.integer(in: 1...UInt32.max)) : 0
    }

    /// Frames from the client and handler completions, in any order, on any
    /// msgid, live or not.
    let streamTableMachine = StateMachine<StreamTableModel>(steps: 200)
        .rule("open stream", weight: 2) { s, tc in
            let msgid = try #draw(msgids, from: tc)
            let request = try #draw(.bool(probability: 0.7), from: tc)
            let response = try #draw(.bool(), from: tc)
            let control = ModelStreamControl(request: request, response: response)
            let entry = StreamTable.Entry(
                control: control,
                hasRequestStream: request,
                hasResponseStream: response
            )
            let registered = s.table.registerStream(msgid: msgid, entry: entry)
            #expect(registered == (s.calls[msgid] == nil))
            if registered {
                s.open(.stream(StreamTableModel.StreamCall(control: control)), on: msgid)
            }
        }
        .rule("open unary") { s, tc in
            let msgid = try #draw(msgids, from: tc)
            let registered = s.table.registerUnary(msgid: msgid)
            #expect(registered == (s.calls[msgid] == nil))
            if registered {
                s.open(.unary(suppressed: false), on: msgid)
            }
        }
        .rule("item", weight: 4) { s, tc in
            let msgid = try #draw(msgids, from: tc)
            let offset = try #draw(seqOffsets, from: tc)
            switch s.calls[msgid] {
                case nil:
                    let decision = s.table.routeItem(msgid: msgid, seq: offset)
                    #expect(decision.outcome == .drop)
                case .unary(suppressed: false):
                    let decision = s.table.routeItem(msgid: msgid, seq: offset)
                    #expect(decision.outcome == .unaryViolation)
                    s.calls[msgid] = .unary(suppressed: true)
                    s.sendTerminal(msgid)
                case .unary(suppressed: true):
                    // Its code-6 terminal already answered the call.
                    let decision = s.table.routeItem(msgid: msgid, seq: offset)
                    #expect(decision.outcome == .drop)
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
                    switch expected {
                        case .deliver:
                            #expect(isControl(decision.control, of: call))
                            _ = control.deliver(ByteBuffer())
                            call.expectedSeq &+= 1
                            s.calls[msgid] = .stream(call)
                        case .violation:
                            #expect(isControl(decision.control, of: call))
                            s.calls[msgid] = nil
                            s.sendTerminal(msgid)
                        default:
                            break
                    }
            }
        }
        .rule("end request") { s, tc in
            let msgid = try #draw(msgids, from: tc)
            let decision = s.table.routeEnd(msgid: msgid)
            switch s.calls[msgid] {
                case nil:
                    #expect(decision.outcome == .drop)
                case .unary(suppressed: false):
                    #expect(decision.outcome == .unaryViolation)
                    s.calls[msgid] = .unary(suppressed: true)
                    s.sendTerminal(msgid)
                case .unary(suppressed: true):
                    #expect(decision.outcome == .drop)
                case .stream(var call):
                    if !call.control.hasRequestStream {
                        #expect(decision.outcome == .violation)
                        #expect(isControl(decision.control, of: call))
                        s.calls[msgid] = nil
                        s.sendTerminal(msgid)
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
            let msgid = try #draw(msgids, from: tc)
            let control = s.table.routeCredit(msgid: msgid)
            if let call = s.stream(msgid), call.control.hasResponseStream {
                #expect(isControl(control, of: call))
            } else {
                #expect(control == nil)
            }
        }
        .rule("stop response") { s, tc in
            let msgid = try #draw(msgids, from: tc)
            let control = s.table.routeStop(msgid: msgid)
            if let call = s.stream(msgid), call.control.hasResponseStream {
                #expect(isControl(control, of: call))
            } else {
                #expect(control == nil)
            }
        }
        .rule("cancel") { s, tc in
            let msgid = try #draw(msgids, from: tc)
            let control = s.table.routeCancel(msgid: msgid)
            if let call = s.stream(msgid) {
                #expect(isControl(control, of: call))
                s.calls[msgid] = nil
                s.sendTerminal(msgid)
            } else {
                // Unknown msgids drop, and unary calls answer for themselves.
                #expect(control == nil)
            }
        }
        .rule("consumer drains") { s, tc in
            let msgid = try #draw(msgids, from: tc)
            let call = s.stream(msgid)
            try tc.assume(call?.control.hasRequestStream == true)
            let count = try #draw(.int(in: 1...Int(MMStreamFlowControl.initialWindow)), from: tc)
            call?.control.grantRequest(count)
        }
        .rule("handler stops consuming") { s, tc in
            let msgid = try #draw(msgids, from: tc)
            let call = s.stream(msgid)
            try tc.assume(call?.control.hasRequestStream == true)
            call?.control.terminateRequest()
        }
        .rule("stream handler returns") { s, tc in
            // A handler whose call a CANCEL or a violation already answered
            // returns too: its retire finds nothing and its terminal is dropped.
            let msgid = try #draw(msgids, from: tc)
            let live = s.table.retireStream(msgid: msgid)
            #expect(live == (s.stream(msgid) != nil))
            if live {
                s.calls[msgid] = nil
                s.sendTerminal(msgid)
            }
        }
        .rule("unary handler returns") { s, tc in
            let msgid = try #draw(msgids, from: tc)
            guard case .unary(let suppressed) = s.calls[msgid] else {
                try tc.reject()
            }
            let send = s.table.consumeUnaryTerminal(msgid: msgid)
            #expect(send == !suppressed)
            s.calls[msgid] = nil
            if send {
                s.sendTerminal(msgid)
            }
        }
        .invariant("the table holds the model's calls", everyStep: true) { s, _ in
            for msgid: UInt32 in 1...3 {
                #expect(s.table.isStreamLive(msgid: msgid) == (s.stream(msgid) != nil), "msgid \(msgid)")
                #expect(s.table.isOwned(msgid: msgid) == (s.calls[msgid] != nil), "msgid \(msgid)")
            }
            #expect(s.table.openStreamCount == s.streamCount)
            #expect(s.table.liveControls().count == s.streamCount)
        }

    @Suite("Stream table properties", .hegel)
    struct StreamTableProperties {
        /// Never two terminals for one call, never an item past the credit
        /// window, and every call can still finish with exactly one terminal.
        @Test(.hegel(testCases: 300))
        func everyCallIsAnsweredOnce() throws {
            try property { tc in
                var s = try streamTableMachine.run(tc, from: StreamTableModel())
                for msgid: UInt32 in 1...3 {
                    switch s.calls[msgid] {
                        case .stream:
                            let live = s.table.retireStream(msgid: msgid)
                            #expect(live)
                            s.sendTerminal(msgid)
                        case .unary(let suppressed):
                            let send = s.table.consumeUnaryTerminal(msgid: msgid)
                            #expect(send == !suppressed)
                            if !suppressed {
                                s.sendTerminal(msgid)
                            }
                        case nil:
                            break
                    }
                    s.calls[msgid] = nil
                    #expect(!s.table.isOwned(msgid: msgid), "msgid \(msgid)")
                }
                #expect(s.terminals.values.allSatisfy { $0 == 1 }, "\(s.terminals)")
            }
        }
    }

#endif

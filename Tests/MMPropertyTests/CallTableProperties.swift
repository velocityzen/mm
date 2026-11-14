// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import Testing

    @testable import MMClient

    /// A stream control that is only an identity: the table stores, returns
    /// and drops controls, and never calls them.
    final class IdentityStreamControl: ClientStreamControl {
        let hasResponseStream = true
        let hasRequestStream = false
        func validateInboundItem(seq: UInt32) -> InboundItemValidation { .drop }
        func deliverInboundItem(_ item: ByteBuffer) -> InboundDeliveryOutcome { .dropped }
        func awaitInboundDemand() async {}
        func serverEndInbound() {}
        func grantOutbound(_ credits: UInt32) {}
        func serverStopOutbound() {}
        func resolveTerminal(_ slots: ResponseSlots) {}
        func failTerminal(_ reason: MMCallError) {}
        func cancelLocally() {}
    }

    /// A continuation's identity. A `CheckedContinuation` holds one
    /// reference, so two copies have the same bits exactly when they are the
    /// same continuation, as long as it is alive; every one a run makes
    /// stays alive in the run.
    func identity<Value>(of continuation: CheckedContinuation<Value, Never>) -> [UInt8] {
        withUnsafeBytes(of: continuation) { Array($0) }
    }

    /// A task suspended on a continuation it handed out, as a call is
    /// between `register` and its outcome. The task's value is what it was
    /// resumed with.
    struct SuspendedTask<Value: Sendable>: Sendable {
        let continuation: CheckedContinuation<Value, Never>
        let task: Task<Value, Never>

        static func start() async -> SuspendedTask {
            let (handOff, sink) = AsyncStream.makeStream(of: CheckedContinuation<Value, Never>.self)
            let task: Task<Value, Never> = Task {
                await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                    sink.yield(continuation)
                    sink.finish()
                }
            }
            var iterator = handOff.makeAsyncIterator()
            return SuspendedTask(continuation: await iterator.next()!, task: task)
        }
    }

    /// What a writer waiter is resumed with, comparable: the writer itself
    /// is not.
    enum WriterOutcome: Equatable, Sendable {
        case writer
        case failure(MMCallError)

        init(_ result: Result<CallTable.Writer, MMCallError>) {
            switch result {
                case .success: self = .writer
                case .failure(let reason): self = .failure(reason)
            }
        }
    }

    /// An entry as the model holds it, and as the table's entries are read
    /// for comparison: continuations and controls by identity.
    enum EntryForm: Equatable {
        case reserved
        case waiting([UInt8])
        case completed(CallTable.Outcome)
        case stream(ObjectIdentifier)
    }

    /// Where the connection is, comparable.
    enum PhaseForm: Equatable {
        case starting
        case running
        case closed(MMCallError)

        init(_ phase: CallTable.Phase) {
            switch phase {
                case .starting: self = .starting
                case .running: self = .running
                case .closed(let reason): self = .closed(reason)
            }
        }
    }

    /// One run of the state machine: the table, the model it is checked
    /// against, and the callers, writer waiters and stream controls the run
    /// made.
    struct CallTableRun: Sendable {
        var table = CallTable()
        let cap: Int
        let msgids: Pool<UInt32>
        let waiterIDs: Pool<UInt64>
        let writer: CallTable.Writer

        // The model.
        var next: UInt32
        var entries: [UInt32: EntryForm] = [:]
        var phase: PhaseForm = .starting
        var writerWaiters: [UInt64: Int] = [:]
        var cancelledWriterWaiters: Set<UInt64> = []
        var registeredWaiterIDs: Set<UInt64> = []
        var nextWriterWaiterID: UInt64 = 0

        // What the run made, and what each was resumed with.
        var callers: [SuspendedTask<CallTable.Outcome>] = []
        var callerOutcomes: [Int: CallTable.Outcome] = [:]
        var waiters: [SuspendedTask<Result<CallTable.Writer, MMCallError>>] = []
        var waiterOutcomes: [Int: WriterOutcome] = [:]
        var controls: [ObjectIdentifier: IdentityStreamControl] = [:]

        /// A msgid to act on: half the time one live in the table now, a
        /// quarter one the run reserved at some point, live or retired, and
        /// a quarter any msgid at all.
        func drawMsgid(_ tc: TestCase) throws -> UInt32 {
            let source = try tc.draw(Gen<Int>.int(in: 0...3))
            let live = entries.keys.sorted()
            if source >= 2, !live.isEmpty {
                return try tc.draw(Gen<UInt32>.element(of: live), named: "live msgid")
            }
            if source == 1, !msgids.isEmpty {
                return try tc.draw(msgids.reusable, named: "msgid")
            }
            return try tc.draw(Gen<UInt32>.integer(), named: "any msgid")
        }

        /// Resumes a continuation the table handed back, which must be the
        /// one `expected` suspended on. One handed back a second time is
        /// recorded, not resumed again.
        mutating func resumeCaller(
            _ continuation: CallTable.Continuation,
            expecting expected: [UInt8]?,
            with outcome: CallTable.Outcome
        ) {
            let bits = identity(of: continuation)
            #expect(bits == expected, "the table handed back another caller's continuation")
            guard let index = callers.firstIndex(where: { identity(of: $0.continuation) == bits })
            else {
                Issue.record("the table handed back a continuation no caller suspended on")
                return
            }
            guard callerOutcomes[index] == nil else {
                Issue.record("caller \(index) handed back a second time")
                return
            }
            callerOutcomes[index] = outcome
            continuation.resume(returning: outcome)
        }

        /// The same for a writer waiter.
        mutating func resumeWaiter(
            _ continuation: CallTable.WriterContinuation,
            expecting expected: Int?,
            with result: Result<CallTable.Writer, MMCallError>
        ) {
            let bits = identity(of: continuation)
            guard let index = waiters.firstIndex(where: { identity(of: $0.continuation) == bits })
            else {
                Issue.record("the table handed back a continuation no writer waiter suspended on")
                return
            }
            #expect(index == expected, "the table handed back another writer waiter")
            guard waiterOutcomes[index] == nil else {
                Issue.record("writer waiter \(index) handed back a second time")
                return
            }
            waiterOutcomes[index] = WriterOutcome(result)
            continuation.resume(returning: result)
        }

        /// Closes the table and checks what it hands back: every suspended
        /// caller and writer waiter, resumed with the reason, and every live
        /// stream's control; reservations park the reason for their callers.
        /// A second close hands back nothing.
        mutating func close(reason: MMCallError, _ tc: TestCase) throws {
            let (calls, waitersBack, streams) = table.close(reason: reason)
            guard !isClosed else {
                #expect(calls.isEmpty && waitersBack.isEmpty && streams.isEmpty)
                try tc.event("closed a second time")
                return
            }
            phase = .closed(reason)
            var expectedCalls: Set<[UInt8]> = []
            var expectedStreams: Set<ObjectIdentifier> = []
            for (msgid, entry) in entries {
                switch entry {
                    case .reserved: entries[msgid] = .completed(.failure(reason))
                    case .waiting(let bits):
                        expectedCalls.insert(bits)
                        entries[msgid] = nil
                    case .completed: break
                    case .stream(let control):
                        expectedStreams.insert(control)
                        entries[msgid] = nil
                }
            }
            if !expectedCalls.isEmpty { try tc.event("closed with callers suspended") }
            if !expectedStreams.isEmpty { try tc.event("closed with live streams") }
            if entries.values.contains(.completed(.failure(reason))) {
                try tc.event("closed with reservations parked")
            }
            #expect(Set(calls.map { identity(of: $0) }) == expectedCalls)
            #expect(calls.count == expectedCalls.count)
            #expect(Set(streams.map { ObjectIdentifier($0) }) == expectedStreams)
            #expect(streams.count == expectedStreams.count)
            for call in calls {
                let bits = identity(of: call)
                resumeCaller(
                    call,
                    expecting: expectedCalls.contains(bits) ? bits : nil,
                    with: .failure(reason)
                )
            }
            let expectedWaiters = writerWaiters
            writerWaiters = [:]
            cancelledWriterWaiters = []
            #expect(waitersBack.count == expectedWaiters.count)
            if !expectedWaiters.isEmpty { try tc.event("closed with writer waiters parked") }
            for waiter in waitersBack {
                let bits = identity(of: waiter)
                let index = waiters.firstIndex { identity(of: $0.continuation) == bits }
                let expected = index.flatMap { expectedWaiters.values.contains($0) ? $0 : nil }
                resumeWaiter(waiter, expecting: expected, with: .failure(reason))
            }
        }

        /// Reserves a msgid and checks the result: refused when closed or at
        /// the cap, otherwise the first id at or after the next one,
        /// wrapping, that is not live. The id, when there is one.
        mutating func reserve(_ tc: TestCase) throws -> UInt32? {
            let result = table.reserve(cap: cap)
            if case .closed(let reason) = phase {
                #expect(result == .failure(reason))
                try tc.event("reserve: refused, closed")
                return nil
            }
            guard entries.count < cap else {
                #expect(result == .failure(.tooManyInFlight))
                try tc.event("reserve: refused at the cap")
                return nil
            }
            // The live ids' distances from `next`, in order, run 0, 1, 2…
            // up to the first gap, which is the id to take.
            let distances = entries.keys.map { $0 &- next }.sorted()
            let skipped =
                distances.enumerated().first { $0.offset != Int($0.element) }?.offset
                ?? distances.count
            let expected = next &+ UInt32(skipped)
            #expect(result == .success(expected))
            if skipped > 0 { try tc.event("reserve: skipped live ids") }
            if expected < next { try tc.event("reserve: skipped across the wrap") }
            if expected == .max { try tc.event("reserve: took UInt32.max") }
            entries[expected] = .reserved
            next = expected &+ 1
            try msgids.add(expected)
            return expected
        }

        /// A new caller registers on `msgid`, which is not waiting or a
        /// stream: it suspends on a reservation, claims a parked outcome, or
        /// finds the reservation gone and is cancelled.
        mutating func register(
            msgid: UInt32,
            caller: SuspendedTask<CallTable.Outcome>,
            _ tc: TestCase
        ) throws {
            callers.append(caller)
            let bits = identity(of: caller.continuation)
            let immediate = table.register(msgid: msgid, continuation: caller.continuation)
            let expected: CallTable.Outcome?
            switch entries[msgid] {
                case nil:
                    expected = .failure(.cancelled)
                    try tc.event("register: cancelled before suspending")
                case .some(.completed(let outcome)):
                    expected = outcome
                    entries[msgid] = nil
                    try tc.event("register: claimed a parked outcome")
                default:
                    expected = nil
                    entries[msgid] = .waiting(bits)
                    try tc.event("register: suspended")
            }
            #expect(immediate == expected)
            // The caller resumes itself with an outcome handed straight back.
            if let immediate { resumeCaller(caller.continuation, expecting: bits, with: immediate) }
        }

        mutating func allocateWaiterID(_ tc: TestCase) throws -> UInt64 {
            let id = table.allocateWriterWaiterID()
            nextWriterWaiterID &+= 1
            #expect(id == nextWriterWaiterID)
            try waiterIDs.add(id)
            return id
        }

        /// A writer waiter registers under `id`: the writer or the close
        /// reason straight away once there is one, `.cancelled` when its
        /// cancellation ran first, and otherwise it parks.
        mutating func registerWaiter(
            id: UInt64,
            waiter: SuspendedTask<Result<CallTable.Writer, MMCallError>>,
            _ tc: TestCase
        ) throws {
            registeredWaiterIDs.insert(id)
            waiters.append(waiter)
            let index = waiters.count - 1
            let immediate = table.registerWriterWaiter(id: id, continuation: waiter.continuation)
            let expected: WriterOutcome?
            switch phase {
                case .running:
                    expected = .writer
                case .closed(let reason):
                    expected = .failure(reason)
                case .starting:
                    if cancelledWriterWaiters.remove(id) != nil {
                        expected = .failure(.cancelled)
                        try tc.event("writer waiter: cancelled before registering")
                    } else {
                        expected = nil
                        writerWaiters[id] = index
                        try tc.event("writer waiter: parked")
                    }
            }
            #expect(immediate.map(WriterOutcome.init) == expected)
            if let immediate {
                resumeWaiter(waiter.continuation, expecting: index, with: immediate)
            }
        }

        /// A writer waiter's cancellation: a parked waiter is handed back,
        /// and before the writer exists an id not yet parked is remembered.
        mutating func cancelWaiter(id: UInt64, _ tc: TestCase) throws {
            let continuation = table.cancelWriterWaiter(id: id)
            if let parked = writerWaiters.removeValue(forKey: id) {
                if let continuation {
                    resumeWaiter(continuation, expecting: parked, with: .failure(.cancelled))
                } else {
                    Issue.record("cancelWriterWaiter(\(id)) lost a parked waiter")
                }
                try tc.event("writer waiter: cancelled while parked")
                return
            }
            #expect(continuation == nil)
            if phase == .starting { cancelledWriterWaiters.insert(id) }
        }

        var isClosed: Bool {
            if case .closed = phase { return true }
            return false
        }

        /// The table's entries in the model's form.
        var tableEntries: [UInt32: EntryForm] {
            table.entries.mapValues { entry in
                switch entry {
                    case .reserved: .reserved
                    case .waiting(let continuation): .waiting(identity(of: continuation))
                    case .completed(let outcome): .completed(outcome)
                    case .stream(let control): .stream(ObjectIdentifier(control))
                }
            }
        }
    }

    enum CallTableGenerators {
        /// A result with a payload, empty or not, or one of the errors a
        /// call can end with.
        static let outcomes: Gen<CallTable.Outcome> = .oneOf(
            Gen<[UInt8]>.bytes(count: 0...4).map {
                .success(ResponseSlots(error: nil, result: ByteBuffer(bytes: $0)))
            },
            .just(.success(ResponseSlots(error: nil, result: nil))),
            reasons.map { .failure($0) }
        )

        /// Why a call fails or a connection closes.
        static let reasons: Gen<MMCallError> = .element(of: [
            .cancelled, .connectionClosed, .tooManyInFlight, .denied, .remoteInternal,
            .transport(description: "reset"),
        ])

        /// The run's starting point: the in-flight cap, the first msgid to
        /// try, and live streams around it and across the wrap, as
        /// long-lived streams leave behind.
        static func start(_ tc: TestCase) throws -> CallTableRun {
            let cap = try tc.draw(
                Gen<Int>.oneOf(.element(of: [1, 2, 3]), .int(in: 1...64)),
                named: "cap"
            )
            let next = try tc.draw(
                Gen<UInt32>.oneOf(.element(of: [0, .max, .max - 1, .max - 2]), .integer()),
                named: "next msgid"
            )
            let seeds = try tc.draw(
                Gen<[UInt32]>.array(
                    of: .oneOf(
                        Gen<UInt32>.integer(in: 0...7).map { next &+ $0 },
                        .element(of: [.max, 0, 1])
                    ),
                    count: 0...6
                ),
                named: "live streams"
            )
            var run = CallTableRun(
                cap: cap,
                msgids: try tc.pool(of: UInt32.self),
                waiterIDs: try tc.pool(of: UInt64.self),
                writer: NIOAsyncChannelOutboundWriter<ByteBuffer>.makeTestingWriter().0,
                next: next
            )
            run.table.nextMsgid = next
            for msgid in Set(seeds) {
                let control = IdentityStreamControl()
                run.controls[ObjectIdentifier(control)] = control
                run.table.entries[msgid] = .stream(control)
                run.entries[msgid] = .stream(ObjectIdentifier(control))
                try run.msgids.add(msgid)
            }
            return run
        }
    }

    /// The table driven through every operation it has, each checked
    /// against the model as it happens.
    let callTableMachine = StateMachine<CallTableRun>()
        .rule("reserve") { s, tc in
            _ = try s.reserve(tc)
        }
        .rule("start a call") { s, tc in
            // What a call does: reserve a msgid, write, then suspend on it.
            guard let msgid = try s.reserve(tc) else { return }
            let caller = await SuspendedTask<CallTable.Outcome>.start()
            try s.register(msgid: msgid, caller: caller, tc)
        }
        .rule("complete") { s, tc in
            let msgid = try s.drawMsgid(tc)
            let outcome = try tc.draw(CallTableGenerators.outcomes, named: "outcome")
            let action = s.table.complete(msgid: msgid, outcome: outcome)
            switch (s.entries[msgid], action) {
                case (nil, .dropped), (.some(.completed), .dropped):
                    try tc.event("complete: dropped")
                case (.some(.reserved), .parked):
                    s.entries[msgid] = .completed(outcome)
                    try tc.event("complete: parked")
                case (.some(.waiting(let bits)), .resume(let continuation)):
                    s.entries[msgid] = nil
                    s.resumeCaller(continuation, expecting: bits, with: outcome)
                    try tc.event("complete: resumed a caller")
                case (.some(.stream(let expected)), .stream(let control)):
                    #expect(ObjectIdentifier(control) == expected)
                    s.entries[msgid] = nil
                    try tc.event("complete: retired a stream")
                default:
                    Issue.record(
                        "complete(\(msgid)) on \(String(describing: s.entries[msgid])) gave \(action)"
                    )
            }
        }
        .rule("register") { s, tc in
            let msgid = try s.drawMsgid(tc)
            // Registering twice, or a unary register on a stream, traps.
            switch s.entries[msgid] {
                case .some(.waiting), .some(.stream): try tc.reject()
                default: break
            }
            let caller = await SuspendedTask<CallTable.Outcome>.start()
            try s.register(msgid: msgid, caller: caller, tc)
        }
        .rule("cancel") { s, tc in
            let msgid = try s.drawMsgid(tc)
            if case .some(.stream) = s.entries[msgid] { try tc.reject() }  // traps
            let continuation = s.table.cancel(msgid: msgid)
            switch s.entries[msgid] {
                case .some(.waiting(let bits)):
                    s.entries[msgid] = nil
                    if let continuation {
                        s.resumeCaller(continuation, expecting: bits, with: .failure(.cancelled))
                    } else {
                        Issue.record("cancel(\(msgid)) lost a suspended caller")
                    }
                    try tc.event("cancel: resumed a caller")
                case .some(.reserved):
                    #expect(continuation == nil)
                    s.entries[msgid] = nil
                    try tc.event("cancel: removed a reservation")
                default:
                    #expect(continuation == nil)
                    try tc.event("cancel: nothing to cancel")
            }
        }
        .rule("abandon") { s, tc in
            let msgid = try s.drawMsgid(tc)
            switch s.entries[msgid] {
                case .some(.waiting), .some(.stream): try tc.reject()  // traps
                default: break
            }
            let outcome = s.table.abandon(msgid: msgid)
            switch s.entries[msgid] {
                case nil:
                    #expect(outcome == .failure(.cancelled))
                case .some(.completed(let parked)):
                    #expect(outcome == parked)
                    s.entries[msgid] = nil
                    try tc.event("abandon: claimed a parked outcome")
                default:
                    #expect(outcome == nil)
                    s.entries[msgid] = nil
                    try tc.event("abandon: removed a reservation")
            }
        }
        .rule("install a stream") { s, tc in
            let msgid = try s.drawMsgid(tc)
            switch s.entries[msgid] {
                case .some(.waiting), .some(.stream): try tc.reject()  // traps
                default: break
            }
            let control = IdentityStreamControl()
            s.controls[ObjectIdentifier(control)] = control
            let outcome = s.table.installStream(msgid: msgid, control: control)
            switch s.entries[msgid] {
                case nil:
                    if case .closed(let reason) = s.phase {
                        #expect(outcome == .failure(reason))
                    } else {
                        #expect(outcome == .failure(.cancelled))
                    }
                case .some(.completed(let parked)):
                    #expect(outcome == parked)
                    s.entries[msgid] = nil
                    try tc.event("install a stream: claimed a parked terminal")
                default:
                    #expect(outcome == nil)
                    s.entries[msgid] = .stream(ObjectIdentifier(control))
                    try tc.event("install a stream: live")
            }
        }
        .rule("retire a stream for a cancel") { s, tc in
            let msgid = try s.drawMsgid(tc)
            let control = s.table.retireStreamForCancel(msgid: msgid)
            if case .some(.stream(let expected)) = s.entries[msgid] {
                #expect(control.map { ObjectIdentifier($0) } == expected)
                s.entries[msgid] = nil
                try tc.event("retire: retired a stream")
            } else {
                #expect(control == nil)
            }
        }
        .rule("look up") { s, tc in
            let msgid = try s.drawMsgid(tc)
            let entry = s.entries[msgid]
            if case .some(.stream(let expected)) = entry {
                #expect(
                    s.table.streamControl(msgid: msgid).map { ObjectIdentifier($0) } == expected
                )
            } else {
                #expect(s.table.streamControl(msgid: msgid) == nil)
            }
            let unary: Bool =
                switch entry {
                    case .some(.reserved), .some(.waiting), .some(.completed): true
                    default: false
                }
            #expect(s.table.isLiveUnary(msgid: msgid) == unary)
        }
        .rule("close", weight: 0.25) { s, tc in
            try s.close(reason: try tc.draw(CallTableGenerators.reasons, named: "reason"), tc)
        }
        .rule("install the writer") { s, tc in
            let resumed = s.table.installWriter(s.writer)
            guard s.phase == .starting else {
                #expect(resumed.isEmpty)
                return
            }
            s.phase = .running
            #expect(resumed.count == s.writerWaiters.count)
            if !s.writerWaiters.isEmpty { try tc.event("writer: installed with waiters parked") }
            let expected = s.writerWaiters
            s.writerWaiters = [:]
            for waiter in resumed {
                let bits = identity(of: waiter)
                let index = s.waiters.firstIndex { identity(of: $0.continuation) == bits }
                let parked = index.flatMap { expected.values.contains($0) ? $0 : nil }
                s.resumeWaiter(waiter, expecting: parked, with: .success(s.writer))
            }
        }
        .rule("allocate a writer waiter id") { s, tc in
            _ = try s.allocateWaiterID(tc)
        }
        .rule("register a writer waiter") { s, tc in
            let id = try tc.draw(s.waiterIDs.reusable, named: "waiter id")
            // Each waiter id is registered once, by the call that allocated it.
            try tc.assume(!s.registeredWaiterIDs.contains(id))
            let waiter = await SuspendedTask<Result<CallTable.Writer, MMCallError>>.start()
            try s.registerWaiter(id: id, waiter: waiter, tc)
        }
        .rule("cancel a writer waiter") { s, tc in
            try s.cancelWaiter(id: try tc.draw(s.waiterIDs.reusable, named: "waiter id"), tc)
        }
        .rule("wait for the writer") { s, tc in
            // What a call does before the writer exists: take an id, then wait.
            let id = try s.allocateWaiterID(tc)
            let waiter = await SuspendedTask<Result<CallTable.Writer, MMCallError>>.start()
            try s.registerWaiter(id: id, waiter: waiter, tc)
        }
        .rule("cancel racing a writer waiter") { s, tc in
            // The cancellation handler runs before the waiter registers.
            let id = try s.allocateWaiterID(tc)
            try s.cancelWaiter(id: id, tc)
            let waiter = await SuspendedTask<Result<CallTable.Writer, MMCallError>>.start()
            try s.registerWaiter(id: id, waiter: waiter, tc)
        }
        .invariant("the table is the model", everyStep: true) { s, _ in
            #expect(s.table.nextMsgid == s.next)
            #expect(s.tableEntries == s.entries)
            #expect(PhaseForm(s.table.phase) == s.phase)
            #expect(s.table.writerWaiters.keys.sorted() == s.writerWaiters.keys.sorted())
            #expect(s.table.cancelledWriterWaiters == s.cancelledWriterWaiters)
            #expect(s.table.nextWriterWaiterID == s.nextWriterWaiterID)
        }

    @Suite("CallTable properties", .hegel)
    struct CallTableProperties {
        /// Driven through any sequence of its operations, from any first
        /// msgid and in-flight cap and with live streams around it, the
        /// table agrees with a model at every step. `reserve` refuses when
        /// closed or at the cap, and otherwise takes the first id at or
        /// after the next one, wrapping past UInt32.max, that is not live.
        /// A response, a register, a cancel, an abandon and a stream install
        /// each end the way the documented race between them says. `close`
        /// hands back every suspended caller, writer waiter and live stream,
        /// parks its reason for reservations, and a second close hands back
        /// nothing. Closing what is left at the end resumes every caller and
        /// writer waiter the run suspended exactly once, each with the
        /// outcome the model says.
        ///
        /// Mutation check: allocation that takes a live id, the cap off by
        /// one, close dropping reservations instead of parking its reason,
        /// a resumed caller left in the table, a cancel that loses its
        /// caller, a second close that is not idempotent, or a writer waiter
        /// that ignores its earlier cancellation, fails here.
        @Test
        func tableAgreesWithItsModel() async throws {
            try await property(
                reaching: [
                    "cancel: nothing to cancel", "closed a second time",
                    "closed with callers suspended", "closed with live streams",
                    "closed with reservations parked", "complete: dropped",
                    "complete: retired a stream", "register: cancelled before suspending",
                    "register: suspended", "reserve: refused at the cap",
                    "reserve: refused, closed", "retire: retired a stream",
                    "writer waiter: cancelled before registering", "writer waiter: parked",
                ],
                reachingAfter: [
                    "abandon: claimed a parked outcome": 1_000,
                    "abandon: removed a reservation": 1_000, "cancel: removed a reservation": 1_000,
                    "cancel: resumed a caller": 1_000, "closed with writer waiters parked": 1_000,
                    "complete: parked": 1_000, "complete: resumed a caller": 1_000,
                    "install a stream: claimed a parked terminal": 1_000,
                    "install a stream: live": 1_000, "register: claimed a parked outcome": 1_000,
                    "reserve: skipped live ids": 1_000, "reserve: took UInt32.max": 1_000,
                    "writer waiter: cancelled while parked": 1_000,
                    "writer: installed with waiters parked": 1_000,
                ]
            ) { tc in
                let start = try CallTableGenerators.start(tc)
                var s = try await callTableMachine.run(tc, from: start)
                try s.close(reason: .connectionClosed, tc)
                #expect(s.callerOutcomes.count == s.callers.count, "a caller was never resumed")
                #expect(
                    s.waiterOutcomes.count == s.waiters.count,
                    "a writer waiter was never resumed"
                )
                // Awaiting a task never resumed would hang: only once all were.
                guard
                    s.callerOutcomes.count == s.callers.count,
                    s.waiterOutcomes.count == s.waiters.count
                else { return }
                for (index, caller) in s.callers.enumerated() {
                    #expect(await caller.task.value == s.callerOutcomes[index])
                }
                for (index, waiter) in s.waiters.enumerated() {
                    #expect(WriterOutcome(await waiter.task.value) == s.waiterOutcomes[index])
                }
            }
        }
    }

#endif

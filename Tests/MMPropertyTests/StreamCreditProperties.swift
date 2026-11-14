// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import Logging
    import MMWire
    import NIOConcurrencyHelpers
    import NIOCore
    import Testing

    @testable import MMClient
    @testable import MMServer

    /// The client stream both pipes run: `Int` items each way, and an `Int`
    /// response, which the client's state carries as `any Sendable`.
    typealias PipeClient = ClientStreamState

    /// A terminal handed to the client stream.
    typealias PipeTerminal = Result<Int, MMCallError>

    /// What a send returned, as one type for both sides: the client and the
    /// server each declare their own `StreamSendOutcome`.
    enum SendOutcome: Equatable, Sendable {
        case sent
        case peerStopped
        case callEnded
        case connectionClosed
    }

    /// One `Int` as both sides carry items and the terminal.
    func packed(_ value: Int) -> ByteBuffer {
        (try? MMPackEncoder().encode(value).get()) ?? ByteBuffer()
    }

    /// How long a pipe may go without a step of progress, or keep running
    /// once its task is cancelled, before the case fails as hung: `Stalled`
    /// or `StillRunning`, which Hegel shrinks with shorter limits. A case
    /// runs in well under a millisecond; a wakeup the code loses never comes.
    let hangLimit: Duration = .seconds(5)

    /// Kills a pipe's connection when its case ends before its tasks
    /// settled: the case failed on a hang, or threw out early. Hegel fails
    /// that case, yet its hung task stays hung, or spinning, for the rest of
    /// the run; a cancelled sender that re-parks spins. Enough spinning
    /// tasks fill the thread pool and starve Hegel's watchdog, which then
    /// takes every late wakeup for a starved run instead of a hang, so the
    /// run never ends. The connection's death ends each of those loops.
    func releaseUnsettled(_ settled: Bool, _ die: () -> Void) {
        if !settled {
            die()
        }
    }

    /// Opens once, and lets through every task that waits on it then or later.
    final class Gate: Sendable {
        private struct State {
            var open = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = NIOLockedValueBox(State())

        func open() {
            let waiters = self.state.withLockedValue { state in
                state.open = true
                let waiters = state.waiters
                state.waiters = []
                return waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let open = self.state.withLockedValue { state in
                    if !state.open {
                        state.waiters.append(continuation)
                    }
                    return state.open
                }
                if open {
                    continuation.resume()
                }
            }
        }
    }

    /// Everything that crossed one pipe, recorded under a lock by whichever
    /// task saw it and read once the case is over. Every effect is recorded
    /// before it is applied, so a check that one thing came before another
    /// never blames the code for a step the pipe had not taken yet.
    final class PipeRecord: Sendable {
        struct State {
            /// The credits the receiver granted beyond the initial window.
            var granted: UInt64 = 0
            /// Running grant totals that were more than the items received.
            var overGrants: [UInt64] = []
            /// The seq of every item that reached the receiver, in order.
            var arrivals: [UInt32] = []
            /// The items that arrived while the connection was alive.
            var accepted = 0
            /// Seqs that arrived past the initial window plus the grants.
            var pastTheWindow: [UInt32] = []
            /// Seqs the server's own credit check refused.
            var overruns: [UInt32] = []
            /// The items the server's request source took in.
            var delivered = 0
            /// For each item that left the server holding more unread items
            /// than the window allows: the seq, and how many it held.
            var unreadPastTheWindow: [(seq: UInt32, unread: Int)] = []
            /// Seqs the client's inbound check called a violation.
            var violations: [UInt32] = []
            /// The values the receiving side's reader took, in order.
            var consumed: [Int] = []
            /// What each send returned, in order.
            var outcomes: [SendOutcome] = []
            /// A STOP was handed to the sending side.
            var stopped = false
            /// The server's response sink was ended.
            var ended = false
            /// The connection died.
            var dead = false
            /// Every terminal handed to the client, in the order handed.
            var terminals: [PipeTerminal] = []
            /// The number of `result()` awaiters started.
            var awaiters = 0
            /// What each awaiter got.
            var results: [PipeTerminal] = []
            /// For each stop watcher that returned: whether a STOP, the end,
            /// the connection's death or its own cancellation explains it.
            var watchers: [Bool] = []
            /// A connection event the plan drew went off.
            var interrupted = false
            /// The sender's task, for an interruption that cancels it.
            var sender: Task<Void, Never>?
            /// That interruption cancelled the sender's task.
            var senderCancelled = false
            var tasks: [Task<Void, Never>] = []
            var events: Set<String> = []
            var cancellation: Cancellation?
        }

        private let state = NIOLockedValueBox(State())
        /// Opens once the sender has spent the initial window, so it is out
        /// of credit until a grant, or has stopped sending.
        let windowSpent = Gate()
        /// Opens once the sender has stopped sending, or the connection died.
        let senderHasStopped = Gate()

        var current: State { self.state.withLockedValue { $0 } }

        func update<Value>(_ body: (inout State) -> Value) -> Value {
            self.state.withLockedValue(body)
        }

        /// Notes, for the statistics report, a state the case reached.
        func event(_ label: String) {
            self.update { _ = $0.events.insert(label) }
        }

        /// Where the drawn cancellation counts its checkpoints; nil once the
        /// run it belongs to is over.
        func arm(_ cancellation: Cancellation?) {
            self.update { $0.cancellation = cancellation }
        }

        func checkpoint(_ label: String) {
            self.current.cancellation?.checkpoint(label)
        }

        /// The sender stopped sending, or the connection died.
        func senderStopped() {
            self.windowSpent.open()
            self.senderHasStopped.open()
        }

        /// Starts `body` in a task the case awaits before its checks.
        func spawn(_ body: @escaping @Sendable () async -> Void) {
            let task = Task { await body() }
            self.update { $0.tasks.append(task) }
        }

        /// Awaits every task spawned so far, and the ones they spawn, with a
        /// beat as each one finishes.
        func settle(_ heartbeat: Heartbeat) async {
            while true {
                let tasks = self.update { state in
                    let tasks = state.tasks
                    state.tasks = []
                    return tasks
                }
                if tasks.isEmpty {
                    return
                }
                for task in tasks {
                    await task.value
                    heartbeat.beat()
                }
            }
        }

        /// An item reached the receiver: records its seq, and whether more
        /// items are in than the initial window and the grants allow.
        /// Returns whether the connection is still alive to carry it.
        func arrive(_ seq: UInt32) -> Bool {
            let alive = self.update { state in
                state.arrivals.append(seq)
                let window = UInt64(MMStreamFlowControl.initialWindow)
                if UInt64(state.arrivals.count) > window + state.granted {
                    state.pastTheWindow.append(seq)
                }
                if UInt64(state.arrivals.count) > window {
                    state.events.insert("items went past the initial window")
                }
                if !state.dead {
                    state.accepted += 1
                }
                return !state.dead
            }
            if seq + 1 >= MMStreamFlowControl.initialWindow {
                self.windowSpent.open()
            }
            return alive
        }

        /// The receiver grants credits: counted before they reach the
        /// sender, so the window check never runs ahead of them.
        func grant(_ credits: UInt32) {
            self.update { state in
                let window = UInt64(MMStreamFlowControl.initialWindow)
                if UInt64(state.arrivals.count) == window + state.granted {
                    state.events.insert("a grant came with the sender out of credit")
                }
                state.granted += UInt64(credits)
                if state.granted > UInt64(state.arrivals.count) {
                    state.overGrants.append(state.granted)
                }
            }
        }

        /// A terminal is about to reach the client.
        func handTerminal(_ terminal: PipeTerminal) {
            self.update { $0.terminals.append(terminal) }
        }
    }

    /// The draws both pipes share.
    enum PipeGenerators {
        /// How many items a side sends: none, around one and two windows, or
        /// any small count.
        static let items: Gen<Int> = .oneOf(
            .just(0),
            .element(of: [1, 7, 8, 9, 15, 16, 17, 24]),
            .int(in: 0...40)
        )
        /// A count of items after which a side acts: at once, around the
        /// grant watermark and the window, any small count, or one inside
        /// the items the sender has, so the act lands mid-stream.
        static func limits(for items: Int) -> Gen<Int> {
            .oneOf(
                .just(0),
                .element(of: [1, 3, 4, 5, 7, 8, 9, 16]),
                .int(in: 0...40),
                .int(in: 0...items)
            )
        }
        /// The seq of an item to act at.
        static let positions: Gen<Int> = .oneOf(
            .just(0),
            .element(of: [7, 8, 9, 16]),
            .int(in: 0...40)
        )
        /// How many times a reader yields after each item: a fast reader
        /// leaves the sender credit, a slow one makes it wait.
        static let paces: Gen<Int> = .element(of: [0, 1, 8])
        /// Whether the reader waits for the sender to spend the initial
        /// window before it reads anything.
        static let lateReaders: Gen<Bool> = .bool()
        static let interruptionPoints: Gen<InterruptionPoint> = .oneOf(
            positions.map { .item($0) },
            .just(.windowSpent)
        )
        static let awaiters: Gen<Int> = .int(in: 0...2)
        static let terminalValues: Gen<Int> = .oneOf(.element(of: [0, .min, .max]), .int())
    }

    /// When a drawn connection event goes off: as the item with this seq
    /// reaches the receiver, which never happens when fewer items are sent,
    /// or once the sender has spent its initial window, when it is out of
    /// credit and about to park.
    enum InterruptionPoint: Sendable, Equatable {
        case item(Int)
        case windowSpent
    }

    // MARK: - Request direction

    /// What the server's handler does with the request stream: read it all,
    /// or once it has read `limit` items return its terminal, ask the client
    /// to STOP and read on, or have its own task cancelled.
    enum RequestHandling: Sendable, Equatable {
        case readsAll
        case returns
        case stops
        case isCancelled
    }

    /// What happens to the connection when the item with a drawn seq
    /// reaches the server.
    enum RequestInterruption: Sendable, Equatable {
        case none
        case connectionDies
        case clientCancels
        /// The sender's task is cancelled, at its point or once the window
        /// is spent, whichever comes first, and the handler reads nothing
        /// until the sender stops: a sender parked at zero credit has only
        /// its own cancellation to release it.
        case senderIsCancelled
    }

    struct RequestPlan: Sendable {
        var items: Int
        var sendsEnd: Bool
        var handling: RequestHandling
        var limit: Int
        var pace: Int
        var readsLate: Bool
        var interruption: RequestInterruption
        var interruptAt: InterruptionPoint
        var awaitersBefore: Int
        var awaiterAt: Int?
        var terminalValue: Int

        static func draw(_ tc: TestCase) throws -> RequestPlan {
            let items = try tc.draw(PipeGenerators.items, named: "items")
            return RequestPlan(
                items: items,
                sendsEnd: try tc.draw(.bool(), named: "sendsEnd"),
                handling: try tc.draw(
                    .element(of: [.readsAll, .returns, .stops, .isCancelled]),
                    named: "handling"
                ),
                limit: try tc.draw(PipeGenerators.limits(for: items), named: "limit"),
                pace: try tc.draw(PipeGenerators.paces, named: "pace"),
                readsLate: try tc.draw(PipeGenerators.lateReaders, named: "readsLate"),
                interruption: try tc.draw(
                    .element(of: [.none, .connectionDies, .clientCancels, .senderIsCancelled]),
                    named: "interruption"
                ),
                interruptAt: try tc.draw(
                    PipeGenerators.interruptionPoints,
                    named: "interruptAt"
                ),
                awaitersBefore: try tc.draw(PipeGenerators.awaiters, named: "awaitersBefore"),
                awaiterAt: try tc.draw(.optional(PipeGenerators.positions), named: "awaiterAt"),
                terminalValue: try tc.draw(PipeGenerators.terminalValues, named: "terminalValue")
            )
        }
    }

    /// The request direction end to end: a client stream's send gate feeds
    /// the server's request source through the server's own credit check,
    /// made the way the stream table makes it for every item, and the
    /// server's grants and STOP flow back to the client.
    final class RequestPipe: Sendable {
        let plan: RequestPlan
        let record = PipeRecord()
        let client: PipeClient
        /// The client's typed sending half, which encodes each value.
        let outbound: OutboundStreamHandle<Int, Never, Int>
        let server: MMRequestStreamSource
        let stream: MMRequestStream<Int>
        /// The pipe as its own closures see it, cleared by `detach()` so the
        /// client, the server and the pipe don't keep each other alive.
        private let link: NIOLockedValueBox<RequestPipe?>

        init(plan: RequestPlan) {
            let link = NIOLockedValueBox<RequestPipe?>(nil)
            let client = PipeClient.make(
                msgid: 1,
                hasResponseStream: false,
                hasRequestStream: true,
                inbound: Never.self,
                response: Int.self,
                sinks: ClientStreamSinks(
                    grantCredit: { _ in },
                    sendItem: { seq, item in
                        link.withLockedValue { $0 }?.serverReceives(seq: seq, item: item) ?? false
                    },
                    sendEnd: { link.withLockedValue { $0 }?.server.finishFromEnd() },
                    sendStop: {},
                    sendCancel: { link.withLockedValue { $0 }?.server.finishFromTerminal() }
                ),
                logger: Logger(label: "mm.property.request-pipe"),
                metrics: ClientMetrics()
            )
            let (server, stream) = MMRequestStream<Int>.make(
                msgid: 1,
                decoding: MMPackDecoder().decoding(Int.self),
                frameSink: { envelope in
                    link.withLockedValue { $0 }?.clientReceives(envelope) ?? false
                },
                metrics: MMStreamMetrics()
            )
            self.plan = plan
            self.client = client
            self.outbound = OutboundStreamHandle(state: client)
            self.server = server
            self.stream = stream
            self.link = link
            link.withLockedValue { $0 = self }
        }

        func detach() {
            self.link.withLockedValue { $0 = nil }
        }

        /// One item reaches the server, which checks it the way the stream
        /// table does: an item for a handler that stopped reading is dropped,
        /// and one past the client's credit is an overrun.
        func serverReceives(seq: UInt32, item: ByteBuffer) -> Bool {
            self.record.checkpoint("item \(seq) sent")
            guard self.record.arrive(seq) else { return false }
            defer { self.interrupt(at: seq) }
            if self.server.isTerminated() {
                self.record.event("an item reached a handler that stopped reading")
                return true
            }
            guard self.server.hasCreditForItem() else {
                self.record.update { $0.overruns.append(seq) }
                return true
            }
            _ = self.server.deliver(item)
            self.record.update { state in
                state.delivered += 1
                // The reader records an item just after it takes it, so the
                // count can run one ahead of what the source holds.
                let unread = state.delivered - state.consumed.count
                if unread > Int(MMStreamFlowControl.initialWindow) + 1 {
                    state.unreadPastTheWindow.append((seq, unread))
                }
            }
            return true
        }

        /// A frame from the server reaches the client.
        func clientReceives(_ envelope: MMEnvelope) -> Bool {
            switch envelope {
                case .credit(_, let credits):
                    if self.client.isSenderParked {
                        self.record.event("a grant reached a parked sender")
                    }
                    self.record.grant(credits)
                    self.record.checkpoint("grant of \(credits)")
                    self.client.grantOutbound(credits)
                case .stop:
                    self.record.update { $0.stopped = true }
                    self.client.serverStopOutbound()
                default:
                    break
            }
            return !self.record.current.dead
        }

        private func interrupt(at seq: UInt32) {
            if Int(seq) == self.plan.awaiterAt {
                self.startAwaiter()
            }
            if self.plan.interruptAt == .item(Int(seq)) {
                self.interrupt()
            }
        }

        /// Arms an interruption drawn for when the window is spent.
        func armInterruption() {
            guard
                self.plan.interruptAt == .windowSpent
                    || self.plan.interruption == .senderIsCancelled
            else { return }
            self.record.spawn {
                await self.record.windowSpent.wait()
                self.interrupt()
            }
        }

        /// Sets off the drawn connection event, once.
        private func interrupt() {
            guard self.plan.interruption != .none else { return }
            let first = self.record.update { state in
                let first = !state.interrupted
                state.interrupted = true
                return first
            }
            guard first else { return }
            switch self.plan.interruption {
                case .none:
                    return
                case .connectionDies:
                    self.record.spawn { self.die() }
                case .clientCancels:
                    self.record.event("the client cancelled the call")
                    self.record.spawn {
                        self.handTerminal(.failure(.cancelled))
                        await self.client.cancel()
                    }
                case .senderIsCancelled:
                    let sender = self.record.update { state in
                        state.senderCancelled = true
                        return state.sender
                    }
                    if self.client.isSenderParked {
                        self.record.event("a cancel reached a parked sender")
                    }
                    sender?.cancel()
            }
        }

        /// The connection dies: both sides end, and the client's terminal
        /// fails with it.
        func die() {
            self.record.update { $0.dead = true }
            self.record.event("the connection died")
            self.record.senderStopped()
            self.server.finishFromTerminal()
            self.handTerminal(.failure(.connectionClosed))
            self.client.failTerminal(.connectionClosed)
        }

        private func handTerminal(_ terminal: PipeTerminal) {
            if self.client.isSenderParked {
                self.record.event("a terminal reached a parked sender")
            }
            self.record.handTerminal(terminal)
        }

        func startAwaiter() {
            self.record.update { $0.awaiters += 1 }
            self.record.spawn {
                let result = await self.client.result(as: Int.self)
                self.record.update { $0.results.append(result) }
            }
        }

        /// The client's sender: one value per send, stopping at the first
        /// send that doesn't go out.
        func send() async {
            for value in 0..<self.plan.items {
                let sent = await self.outbound.send(value)
                let outcome: SendOutcome =
                    switch sent {
                        case .sent: .sent
                        case .peerStopped: .peerStopped
                        case .callEnded: .callEnded
                        case .connectionClosed: .connectionClosed
                    }
                self.record.update { $0.outcomes.append(outcome) }
                guard outcome == .sent else { break }
            }
            self.record.senderStopped()
            if self.plan.sendsEnd {
                await self.client.finish()
            }
        }

        /// The server's side of the call: the grant pump and the handler,
        /// whose terminal goes out once it stops reading, unless the
        /// connection is gone.
        func serve() async {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.server.runGrantPump() }
                group.addTask {
                    await self.handle()
                    self.server.finishFromTerminal()
                    guard !self.record.current.dead else { return }
                    self.handTerminal(.success(self.plan.terminalValue))
                    self.client.resolveTerminal(
                        ResponseSlots(error: nil, result: packed(self.plan.terminalValue))
                    )
                }
            }
        }

        private func handle() async {
            var iterator = self.stream.makeAsyncIterator()
            var read = 0
            while true {
                if read == 0, self.plan.interruption == .senderIsCancelled {
                    await self.record.senderHasStopped.wait()
                } else if read == 0, self.plan.readsLate {
                    await self.record.windowSpent.wait()
                }
                if read == self.plan.limit {
                    switch self.plan.handling {
                        case .readsAll:
                            break
                        case .returns:
                            return
                        case .stops:
                            await self.stream.stop()
                        case .isCancelled:
                            withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                guard let value = await iterator.next() else { return }
                self.record.update { $0.consumed.append(value) }
                self.record.checkpoint("item \(read) read")
                if self.client.isSenderParked {
                    self.record.event("the client parked at zero credit")
                }
                read += 1
                for _ in 0..<self.plan.pace {
                    await Task.yield()
                }
            }
        }
    }

    // MARK: - Response direction

    /// What the client does with the response stream: read it all, or once
    /// it has read `limit` items ask the server to STOP and read on, cancel
    /// the call, or stop reading as its task is cancelled and then cancel the
    /// call, the way the handle's documentation says to abandon one.
    enum ResponseReading: Sendable, Equatable {
        case readsAll
        case stops
        case cancelsTheCall
        case isCancelled
    }

    struct ResponsePlan: Sendable {
        var items: Int
        var reading: ResponseReading
        var limit: Int
        var pace: Int
        var readsLate: Bool
        var watchers: Int
        var connectionDiesAt: InterruptionPoint?
        var awaitersBefore: Int
        var awaiterAt: Int?
        var terminalValue: Int

        static func draw(_ tc: TestCase) throws -> ResponsePlan {
            let items = try tc.draw(PipeGenerators.items, named: "items")
            return ResponsePlan(
                items: items,
                reading: try tc.draw(
                    .element(of: [.readsAll, .stops, .cancelsTheCall, .isCancelled]),
                    named: "reading"
                ),
                limit: try tc.draw(PipeGenerators.limits(for: items), named: "limit"),
                pace: try tc.draw(PipeGenerators.paces, named: "pace"),
                readsLate: try tc.draw(PipeGenerators.lateReaders, named: "readsLate"),
                watchers: try tc.draw(.int(in: 0...3), named: "watchers"),
                connectionDiesAt: try tc.draw(
                    .optional(PipeGenerators.interruptionPoints),
                    named: "connectionDiesAt"
                ),
                awaitersBefore: try tc.draw(PipeGenerators.awaiters, named: "awaitersBefore"),
                awaiterAt: try tc.draw(.optional(PipeGenerators.positions), named: "awaiterAt"),
                terminalValue: try tc.draw(PipeGenerators.terminalValues, named: "terminalValue")
            )
        }
    }

    /// The response direction end to end: the server's credit-gated sink
    /// feeds a client stream's inbound side the way the client's inbound
    /// loop does, parking on its demand when the buffer fills, and the
    /// client's reader grants credit back.
    final class ResponsePipe: Sendable {
        let plan: ResponsePlan
        let record = PipeRecord()
        let client: PipeClient
        let server: MMResponseSinkState
        let sink: MMResponseSink<Int>
        private let link: NIOLockedValueBox<ResponsePipe?>

        init(plan: ResponsePlan) {
            let link = NIOLockedValueBox<ResponsePipe?>(nil)
            let client = PipeClient.make(
                msgid: 1,
                hasResponseStream: true,
                hasRequestStream: false,
                inbound: Int.self,
                response: Int.self,
                sinks: ClientStreamSinks(
                    grantCredit: { credits in link.withLockedValue { $0 }?.serverGranted(credits) },
                    sendItem: { _, _ in false },
                    sendEnd: {},
                    sendStop: { link.withLockedValue { $0 }?.serverStopped() },
                    sendCancel: { link.withLockedValue { $0 }?.serverEnded() }
                ),
                logger: Logger(label: "mm.property.response-pipe"),
                metrics: ClientMetrics()
            )
            let server = MMResponseSinkState(
                msgid: 1,
                itemSink: { seq, item in
                    await link.withLockedValue { $0 }?.clientReceives(seq: seq, item: item) ?? false
                },
                metrics: MMStreamMetrics()
            )
            self.plan = plan
            self.client = client
            self.server = server
            self.sink = MMResponseSink(state: server, encode: MMPackEncoder().encoding(Int.self))
            self.link = link
            link.withLockedValue { $0 = self }
        }

        func detach() {
            self.link.withLockedValue { $0 = nil }
        }

        /// One item reaches the client's inbound loop: it validates the seq,
        /// buffers the item, and waits for its reader when the buffer is full.
        func clientReceives(seq: UInt32, item: ByteBuffer) async -> Bool {
            self.record.checkpoint("item \(seq) sent")
            guard self.record.arrive(seq) else { return false }
            switch self.client.validateInboundItem(seq: seq) {
                case .violation:
                    self.record.update { $0.violations.append(seq) }
                case .drop:
                    self.record.event("an item reached a client that stopped reading")
                case .deliver:
                    if case .stopProducing = self.client.deliverInboundItem(item) {
                        self.record.event("the client's buffer filled")
                        await self.client.awaitInboundDemand()
                    }
            }
            self.interrupt(at: seq)
            return true
        }

        func serverGranted(_ credits: UInt32) {
            self.record.grant(credits)
            self.record.checkpoint("grant of \(credits)")
            self.server.grant(credits)
        }

        func serverStopped() {
            self.record.update { $0.stopped = true }
            self.server.peerStop()
        }

        /// The server's sink ends: the handler returned, the client
        /// cancelled, or the connection died.
        func serverEnded() {
            self.record.update { $0.ended = true }
            self.server.end()
        }

        private func interrupt(at seq: UInt32) {
            if Int(seq) == self.plan.awaiterAt {
                self.startAwaiter()
            }
            if self.plan.connectionDiesAt == .item(Int(seq)) {
                self.record.update { $0.interrupted = true }
                self.record.spawn { self.die() }
            }
        }

        /// Arms a death drawn for when the window is spent.
        func armInterruption() {
            guard self.plan.connectionDiesAt == .windowSpent else { return }
            self.record.spawn {
                await self.record.windowSpent.wait()
                self.record.update { $0.interrupted = true }
                self.die()
            }
        }

        func die() {
            self.record.update { $0.dead = true }
            self.record.event("the connection died")
            self.record.senderStopped()
            self.serverEnded()
            self.record.handTerminal(.failure(.connectionClosed))
            self.client.failTerminal(.connectionClosed)
        }

        func startAwaiter() {
            self.record.update { $0.awaiters += 1 }
            self.record.spawn {
                let result = await self.client.result(as: Int.self)
                self.record.update { $0.results.append(result) }
            }
        }

        private func cancelCall() async {
            self.record.handTerminal(.failure(.cancelled))
            await self.client.cancel()
        }

        /// The client's reader.
        func read() async {
            var iterator = InboundStreamHandle<Int, Int, Int>(state: self.client)
                .makeAsyncIterator()
            var read = 0
            var cancelled = false
            while true {
                if read == 0, self.plan.readsLate {
                    await self.record.windowSpent.wait()
                }
                if read == self.plan.limit {
                    switch self.plan.reading {
                        case .readsAll:
                            break
                        case .stops:
                            await self.client.stop()
                        case .cancelsTheCall:
                            await self.cancelCall()
                            return
                        case .isCancelled:
                            cancelled = true
                            withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                guard let value = await iterator.next() else { break }
                self.record.update { $0.consumed.append(value) }
                self.record.checkpoint("item \(read) read")
                read += 1
                for _ in 0..<self.plan.pace {
                    await Task.yield()
                }
            }
            if cancelled {
                await self.cancelCall()
            }
        }

        /// The server's handler: stop watchers beside a sender that stops at
        /// the first send that doesn't go out. After a STOP, or once its
        /// task is cancelled, it waits for every watcher before it returns,
        /// as a handler relaying a quiet source does; then its sink ends and
        /// its terminal goes out, unless the connection is gone.
        func handle() async {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<self.plan.watchers {
                    group.addTask { await self.watchForStop() }
                }
                var last = SendOutcome.sent
                for value in 0..<self.plan.items {
                    let sent = await self.sink.send(value)
                    last =
                        switch sent {
                            case .sent: .sent
                            case .peerStopped: .peerStopped
                            case .callEnded: .callEnded
                        }
                    self.record.update { [last] in $0.outcomes.append(last) }
                    guard last == .sent else { break }
                }
                self.record.senderStopped()
                if last == .peerStopped || Task.isCancelled {
                    await group.waitForAll()
                }
                self.serverEnded()
                guard !self.record.current.dead else { return }
                self.record.handTerminal(.success(self.plan.terminalValue))
                self.client.resolveTerminal(
                    ResponseSlots(error: nil, result: packed(self.plan.terminalValue))
                )
            }
        }

        private func watchForStop() async {
            await self.server.stopRequested()
            let cancelled = Task.isCancelled
            self.record.update { state in
                // A sink whose item write fails ends itself, before the pipe
                // gets to end it, so the connection's death counts too.
                let released = state.stopped || state.ended || state.dead
                state.watchers.append(released || cancelled)
                if cancelled && !released {
                    state.events.insert("a watcher returned on its own cancellation")
                } else if state.stopped && !state.ended {
                    state.events.insert("a STOP released a watcher")
                }
            }
        }
    }

    // MARK: - Checks

    /// The terminal resolved once: every awaiter got the same one, and it
    /// is one the client was handed.
    func expectOneTerminal(_ record: PipeRecord.State) {
        #expect(record.results.count == record.awaiters, "an awaiter never got the terminal")
        #expect(!record.terminals.isEmpty, "the case ended with no terminal handed")
        guard let first = record.results.first else { return }
        #expect(
            record.results.allSatisfy { $0 == first },
            "awaiters got different terminals: \(record.results)"
        )
        #expect(
            record.terminals.contains(first),
            "the terminal \(first) is none of \(record.terminals)"
        )
    }

    /// What every pipe holds to whatever the run did: no item past the
    /// window, no grant for items never received, seqs and values in order,
    /// and one `.sent` for every item the receiver took.
    func expectInsideTheWindow(_ record: PipeRecord.State) {
        #expect(
            record.pastTheWindow.isEmpty,
            "items past the initial window plus the grants: seqs \(record.pastTheWindow)"
        )
        #expect(
            record.overGrants.isEmpty,
            "grants for items never received: totals \(record.overGrants)"
        )
        #expect(
            record.arrivals == (0..<record.arrivals.count).map { UInt32($0) },
            "seqs not stamped 0, 1, 2 and on: \(record.arrivals)"
        )
        #expect(
            record.consumed == Array(0..<record.consumed.count),
            "the reader got items out of order: \(record.consumed)"
        )
        #expect(record.outcomes.filter { $0 == .sent }.count == record.accepted)
    }

    @Suite("Stream credit properties", .hegel)
    struct StreamCreditProperties {
        /// A client's request stream, sending into a server handler that
        /// reads all of it, returns early, asks it to STOP or is cancelled,
        /// reading at once or only once the client has spent its window,
        /// with the connection dying, the client cancelling or the sender's
        /// task cancelled at a drawn point, and the sender's task also
        /// cancelled at a random checkpoint, never sends past its credit:
        /// the server's own credit check refuses no item, and no more items
        /// arrive than the initial window plus the grants so far. The server
        /// grants only for items it received, and never holds more than the
        /// window unread, however slowly its handler reads. Seqs run 0, 1, 2
        /// on, and a send that doesn't go out says why: a STOP, a dead
        /// connection, or the call's end or its own cancellation. A sender
        /// parked at zero credit with nothing else to release it exits on its
        /// own cancellation. With nothing in the way, every send goes out, so
        /// no grant is lost. The terminal resolves once, the same for every
        /// awaiter, whichever of the server's terminal, a cancel and the
        /// connection's death reaches the client first.
        ///
        /// Mutation check: a client send gate that ignores zero credit, a
        /// grant or a cancellation that leaves the sender parked, a second
        /// terminal that overwrites the first, a death that reads as the
        /// call's end, a server grant that ignores the unread items (the bug
        /// this property found) or grants one too many, fails here.
        @Test
        func requestStreamStaysInsideTheServersCredit() async throws {
            try await property(
                reaching: ["a send ended callEnded"],
                reachingAfter: [
                    "a cancel reached a parked sender": 1_000,
                    "a grant came with the sender out of credit": 1_000,
                    "a grant reached a parked sender": 1_000,
                    "a send ended connectionClosed": 1_000, "a send ended peerStopped": 1_000,
                    "a terminal reached a parked sender": 1_000,
                    "an item reached a handler that stopped reading": 1_000,
                    "items went past the initial window": 1_000,
                    "several terminals were handed": 1_000, "the client cancelled the call": 1_000,
                    "the client parked at zero credit": 1_000, "the connection died": 1_000,
                    "the sender's own cancellation ended a send": 1_000,
                    "the sender's task was cancelled": 1_000,
                ]
            ) { tc in
                let plan = try RequestPlan.draw(tc)
                let pipe = RequestPipe(plan: plan)
                // See `releaseUnsettled`.
                var settled = false
                defer {
                    releaseUnsettled(settled, pipe.die)
                    pipe.detach()
                }
                for _ in 0..<plan.awaitersBefore {
                    pipe.startAwaiter()
                }
                // A send that never returns fails the case as `Stalled`, or
                // as `StillRunning` once its task is cancelled.
                let run = try await tc.withRandomCancellation(
                    checkpoints: 0...(2 * plan.items + plan.items / 4 + 2),
                    endsWithin: hangLimit,
                    stallsAfter: hangLimit
                ) { cancellation in
                    pipe.record.arm(cancellation)
                    pipe.armInterruption()
                    pipe.record.spawn { await pipe.serve() }
                    // The sender waits until its task is on record, so an
                    // interruption can always find it to cancel.
                    let recorded = Gate()
                    let sender = Task {
                        await recorded.wait()
                        await pipe.send()
                    }
                    pipe.record.update { $0.sender = sender }
                    recorded.open()
                    await withTaskCancellationHandler {
                        await sender.value
                    } onCancel: {
                        sender.cancel()
                    }
                }
                pipe.record.arm(nil)
                // The server or an awaiter that hangs fails the case as
                // `Stalled`.
                try await tc.withStallDetection(after: hangLimit) { heartbeat in
                    // The client's END, when its sender didn't send one.
                    await pipe.client.finish()
                    await pipe.record.settle(heartbeat)
                }
                pipe.startAwaiter()
                try await tc.withStallDetection(after: hangLimit) { heartbeat in
                    await pipe.record.settle(heartbeat)
                }
                settled = true

                let record = pipe.record.current
                #expect(
                    record.overruns.isEmpty,
                    "the server's credit check refused seqs \(record.overruns)"
                )
                #expect(
                    record.unreadPastTheWindow.isEmpty,
                    "the server held more unread items than the window: \(record.unreadPastTheWindow)"
                )
                expectInsideTheWindow(record)
                switch record.outcomes.last {
                    case .peerStopped:
                        #expect(record.stopped, "a send stopped with no STOP")
                    case .connectionClosed:
                        #expect(record.dead, "a send found the connection closed while alive")
                    case .callEnded:
                        #expect(
                            run.cancelledAt != nil || record.senderCancelled
                                || record.terminals.contains { $0 != .failure(.connectionClosed) },
                            "a send found the call ended with no end and no cancellation"
                        )
                    case .sent, nil:
                        break
                }
                if !record.interrupted, run.cancelledAt == nil,
                    plan.handling == .readsAll || plan.limit >= plan.items
                {
                    #expect(
                        record.outcomes == Array(repeating: .sent, count: plan.items),
                        "with nothing in the way, sends stopped: \(record.outcomes)"
                    )
                }
                expectOneTerminal(record)

                for label in record.events.sorted() {
                    try tc.event(label)
                }
                if run.cancelledAt != nil {
                    try tc.event("the sender's task was cancelled")
                }
                if record.senderCancelled, record.outcomes.last == .callEnded {
                    try tc.event("the sender's own cancellation ended a send")
                }
                if let last = record.outcomes.last, last != .sent {
                    try tc.event("a send ended \(last)")
                }
                if record.terminals.count > 1 {
                    try tc.event("several terminals were handed")
                }
            }
        }

        /// A server's response sink, sending to a client that reads all of
        /// it, asks it to STOP, cancels the call or stops reading as its task
        /// is cancelled, reading at once or only once the server has spent
        /// its window, with the connection dying at a drawn point and the
        /// handler's task cancelled at a random checkpoint, never sends more
        /// items than the initial window plus the client's grants so far,
        /// and the client grants only for items it received. The client's
        /// inbound check finds every seq in order. A send that doesn't go out
        /// says why: a STOP or the sink's end. With nothing in the way, every
        /// send goes out. Every `stopRequested()` watcher returns exactly
        /// once, explained by a STOP, the end, the connection's death or its
        /// own cancellation; after a STOP or a cancellation they all return
        /// before the sink ends. The client's terminal resolves once, the
        /// same for every awaiter.
        ///
        /// Mutation check: a sink gate that ignores zero credit, a grant or
        /// the end that leaves the sender parked, a STOP that leaves the stop
        /// watchers waiting, a watcher that ignores its earlier cancellation,
        /// a parked send that reuses its seq, a client that grants one too
        /// many, or a second terminal that overwrites the first, fails here.
        @Test
        func responseSinkStaysInsideTheClientsGrants() async throws {
            try await property(
                reaching: ["several terminals were handed", "the handler's task was cancelled"],
                reachingAfter: [
                    "a STOP released a watcher": 1_000,
                    "a grant came with the sender out of credit": 1_000,
                    "a send ended callEnded": 1_000, "a send ended peerStopped": 1_000,
                    "a watcher returned on its own cancellation": 1_000,
                    "an item reached a client that stopped reading": 1_000,
                    "items went past the initial window": 1_000,
                    "the client's buffer filled": 1_000, "the connection died": 1_000,
                ]
            ) { tc in
                let plan = try ResponsePlan.draw(tc)
                let pipe = ResponsePipe(plan: plan)
                // See `releaseUnsettled`.
                var settled = false
                defer {
                    releaseUnsettled(settled, pipe.die)
                    pipe.detach()
                }
                for _ in 0..<plan.awaitersBefore {
                    pipe.startAwaiter()
                }
                // A handler that never returns fails the case as `Stalled`,
                // or as `StillRunning` once its task is cancelled.
                let run = try await tc.withRandomCancellation(
                    checkpoints: 0...(2 * plan.items + plan.items / 8 + 2),
                    endsWithin: hangLimit,
                    stallsAfter: hangLimit
                ) { cancellation in
                    pipe.record.arm(cancellation)
                    pipe.armInterruption()
                    pipe.record.spawn { await pipe.read() }
                    let handler = Task { await pipe.handle() }
                    await withTaskCancellationHandler {
                        await handler.value
                    } onCancel: {
                        handler.cancel()
                    }
                }
                pipe.record.arm(nil)
                // The reader or an awaiter that hangs fails the case as
                // `Stalled`.
                try await tc.withStallDetection(after: hangLimit) { heartbeat in
                    await pipe.record.settle(heartbeat)
                }
                pipe.startAwaiter()
                try await tc.withStallDetection(after: hangLimit) { heartbeat in
                    await pipe.record.settle(heartbeat)
                }
                settled = true

                let record = pipe.record.current
                #expect(
                    record.violations.isEmpty,
                    "the client's inbound check refused seqs \(record.violations)"
                )
                expectInsideTheWindow(record)
                switch record.outcomes.last {
                    case .peerStopped:
                        #expect(record.stopped, "a send stopped with no STOP")
                    case .callEnded:
                        #expect(
                            record.ended || record.dead,
                            "a send found the call ended before its end"
                        )
                    case .connectionClosed:
                        Issue.record("the server's sink reported a closed connection")
                    case .sent, nil:
                        break
                }
                if !record.interrupted, plan.reading == .readsAll || plan.limit >= plan.items {
                    #expect(
                        record.outcomes == Array(repeating: .sent, count: plan.items),
                        "with nothing in the way, sends stopped: \(record.outcomes)"
                    )
                }
                #expect(record.watchers.count == plan.watchers, "a stop watcher never returned")
                #expect(
                    record.watchers.allSatisfy { $0 },
                    "a stop watcher returned with no STOP, no end and no cancellation"
                )
                expectOneTerminal(record)

                for label in record.events.sorted() {
                    try tc.event(label)
                }
                if run.cancelledAt != nil {
                    try tc.event("the handler's task was cancelled")
                }
                if let last = record.outcomes.last, last != .sent {
                    try tc.event("a send ended \(last)")
                }
                if record.terminals.count > 1 {
                    try tc.event("several terminals were handed")
                }
            }
        }
    }

#endif

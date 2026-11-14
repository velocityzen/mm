// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import Synchronization
    import Testing

    /// One frame the batching writer property sends: the sender that sent
    /// it, and its place among that sender's frames.
    struct FrameTag: Hashable, Sendable, CustomStringConvertible {
        var sender: Int
        var index: Int

        /// The frame the test sends once every sender has returned.
        static let probe = FrameTag(sender: 200, index: 0)
        /// The frame the test sends once the stand-by task has ended.
        static let late = FrameTag(sender: 201, index: 0)

        init(sender: Int, index: Int) {
            self.sender = sender
            self.index = index
        }

        init(_ frame: ByteBuffer) {
            let bytes = Array(frame.readableBytesView)
            self.init(sender: Int(bytes[0]), index: Int(bytes[1]))
        }

        var frame: ByteBuffer {
            ByteBuffer(bytes: [UInt8(self.sender), UInt8(self.index)])
        }

        var description: String { "\(self.sender).\(self.index)" }
    }

    /// The task that calls the scripted channel: a sender, the writer's
    /// stand-by task, or the test itself. The channel's plan cancels only a
    /// sender: the stand-by task is cancelled only when its connection
    /// ends.
    enum FrameWritingTask: Sendable, Equatable {
        case test
        case sender(Int)
        case standBy

        @TaskLocal static var current: FrameWritingTask = .test
    }

    /// How a send ended, comparable: `.success` means written or queued.
    enum FrameSendOutcome: Sendable, Equatable {
        case success
        case cancelled
        case channelClosed

        init(_ result: Result<Void, BatchingFrameWriter.Failure>) {
            switch result {
                case .success: self = .success
                case .failure(.cancelled): self = .cancelled
                case .failure(.channelClosed): self = .channelClosed
            }
        }
    }

    /// What one sender does: sends `frames` frames, cancels its own task
    /// before the frame at `cancelledBefore`, if any, and yields `pace`
    /// times after each send, so other senders get between its frames.
    struct FrameSenderPlan: Sendable {
        var frames: Int
        var cancelledBefore: Int?
        var pace: Int

        static let plans: Gen<FrameSenderPlan> = Gen { tc in
            FrameSenderPlan(
                frames: try tc.draw(.int(in: 0...6)),
                cancelledBefore: try tc.draw(.optional(.int(in: 0...5))),
                pace: try tc.draw(.int(in: 0...2))
            )
        }
    }

    /// A channel that writes batches as its plan says. Each write call
    /// yields a drawn number of times first, as a write waiting for a busy
    /// channel does, so other senders queue meanwhile. At drawn calls it
    /// cancels the sender writing and throws `CancellationError`, having
    /// written nothing, as the outbound writer does for a cancelled task.
    /// At a drawn call it dies, and throws from then on.
    final class ScriptedChannel: Sendable {
        struct Plan: Sendable {
            /// How many times write call `n` yields; calls past the end
            /// don't.
            var pauses: [Int]
            /// The write calls at which a sender writing is cancelled.
            /// Batching keeps the calls few, so the calls drawn are early.
            var cancellations: Set<Int>
            /// The write call at which the channel dies.
            var death: Int?

            static let plans: Gen<Plan> = Gen { tc in
                Plan(
                    pauses: try tc.draw(.array(of: .int(in: 0...3), count: 0...12)),
                    cancellations: try tc.draw(.set(of: .int(in: 0...11), count: 0...4)),
                    death: try tc.draw(.optional(.int(in: 0...11)))
                )
            }
        }

        struct Record: Sendable {
            var calls = 0
            var batches: [[FrameTag]] = []
            /// Write calls in progress.
            var writing = 0
            /// Two write calls were in progress at once.
            var overlapped = false
            var dead = false
            /// Write calls made once the channel was dead.
            var callsWhileDead = 0
            var healed = false
            var events: Set<String> = []
        }

        struct Gone: Error {}

        private let plan: Plan
        private let record = Mutex(Record())

        init(plan: Plan) {
            self.plan = plan
        }

        var current: Record { self.record.withLock { $0 } }

        /// Whether `tag` has been written.
        func hasWritten(_ tag: FrameTag) -> Bool {
            self.record.withLock { record in
                record.batches.contains { $0.contains(tag) }
            }
        }

        /// Ends the plan's faults: later calls neither cancel nor die. A
        /// dead channel stays dead.
        func heal() {
            self.record.withLock { $0.healed = true }
        }

        func write(_ batch: [ByteBuffer]) async throws {
            let task = FrameWritingTask.current
            let (call, healed) = self.record.withLock { record in
                defer { record.calls += 1 }
                record.writing += 1
                if record.writing > 1 { record.overlapped = true }
                if record.dead { record.callsWhileDead += 1 }
                return (record.calls, record.healed)
            }
            defer { self.record.withLock { $0.writing -= 1 } }
            if !healed, case .sender = task, self.plan.cancellations.contains(call) {
                withUnsafeCurrentTask { $0?.cancel() }
                self.record.withLock { _ = $0.events.insert("a writer was cancelled mid-write") }
            }
            for _ in 0..<(call < self.plan.pauses.count ? self.plan.pauses[call] : 0) {
                await Task.yield()
            }
            if Task.isCancelled { throw CancellationError() }
            try self.record.withLock { (record: inout Record) throws(Gone) -> Void in
                if record.dead || (!healed && call == self.plan.death) {
                    record.dead = true
                    record.events.insert("the channel died")
                    throw Gone()
                }
                record.batches.append(batch.map(FrameTag.init))
                if batch.count > 1 { record.events.insert("a batch of several frames") }
                if task == .standBy { record.events.insert("the stand-by wrote frames") }
            }
        }
    }

    /// What the senders saw: each send's frame and outcome, in the order
    /// the sends returned, and whether its task was cancelled before it.
    final class FrameSendRecord: Sendable {
        struct Send: Sendable {
            var tag: FrameTag
            var outcome: FrameSendOutcome
            var wasCancelled: Bool
        }

        struct Sends: Sendable {
            var sends: [Send] = []
            var events: Set<String> = []
        }

        private let state = Mutex(Sends())

        var current: Sends { self.state.withLock { $0 } }

        func sent(_ send: Send, queued: Bool) {
            self.state.withLock { state in
                state.sends.append(send)
                if send.wasCancelled { state.events.insert("a cancelled sender was refused") }
                if queued { state.events.insert("a sender queued behind a writer") }
            }
        }
    }

    /// Sends `plan`'s frames as sender `sender`, one after another.
    func sendFrames(
        _ plan: FrameSenderPlan,
        as sender: Int,
        through writer: BatchingFrameWriter,
        to channel: ScriptedChannel,
        recordingIn record: FrameSendRecord,
        heartbeat: Heartbeat
    ) async {
        for index in 0..<plan.frames {
            if index == plan.cancelledBefore {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let tag = FrameTag(sender: sender, index: index)
            let wasCancelled = Task.isCancelled
            let outcome = FrameSendOutcome(await writer.write(tag.frame))
            record.sent(
                FrameSendRecord.Send(tag: tag, outcome: outcome, wasCancelled: wasCancelled),
                queued: outcome == .success && !channel.hasWritten(tag)
            )
            heartbeat.beat()
            for _ in 0..<plan.pace {
                await Task.yield()
            }
        }
    }

    @Suite("Batching frame writer properties", .hegel)
    struct BatchingFrameWriterProperties {
        /// One to four senders send up to six frames each through one
        /// batching writer, over a channel that pauses, cancels the sender
        /// writing at drawn calls, and dies at a drawn call, while the
        /// writer's stand-by task runs beside them. Then the test sends one
        /// frame of its own, ends the stand-by task, and sends one more.
        ///
        /// Two writes never run at once, and none carries an empty batch.
        /// No frame is written twice, and none whose send failed is written.
        /// Each sender's frames go out in the order it sent them. A send
        /// from a cancelled task fails with `.cancelled`, and once a sender's
        /// send fails, none of its later sends succeeds. Nothing writes to
        /// a dead channel, and once it has died the test's frame is not
        /// written: its send fails, or it queued behind the write the
        /// channel died under and was dropped. Otherwise every frame whose
        /// send succeeded is written, a cancelled writer's included, and
        /// the test's frame, sent last, goes out last. Once the stand-by
        /// task has ended, a send fails with `.channelClosed`.
        ///
        /// Mutation check, three runs each: a writer that drops the frames
        /// it held when cancelled, a hand-on that never wakes the stand-by
        /// task, frames handed back to the end of the queue, a cancelled
        /// writer's own frame handed back too, a missing closed latch, the
        /// writing ended while the writer still holds a batch, a stand-by
        /// task that leaves the writer open, and a writer that fails its own
        /// send for a later batch's cancellation each fail here every time,
        /// and pass the server, client and integration tests. A writer that
        /// skips the entry check for a cancelled task fails here too, and
        /// hangs those tests. A stand-by task that takes the queue and ends
        /// the writing in two steps, leaving a frame queued between them
        /// stranded, passes: no suspension falls in that window for the
        /// pauses to widen, so only the single step guards it.
        @Test
        func everySentFrameIsWrittenOnceAndInOrder() async throws {
            try await property(
                reaching: [
                    "a batch of several frames", "a sender queued behind a writer",
                    "a writer was cancelled mid-write", "the stand-by wrote frames",
                    "a cancelled sender was refused", "the channel died",
                ]
            ) { tc in
                let senders = try #draw(.array(of: FrameSenderPlan.plans, count: 1...4), from: tc)
                let channel = ScriptedChannel(plan: try #draw(ScriptedChannel.Plan.plans, from: tc))
                let writer = BatchingFrameWriter { batch in try await channel.write(batch) }
                let record = FrameSendRecord()
                // See `releaseUnsettled`.
                var settled = false
                defer { releaseUnsettled(settled, writer.finish) }

                // A writer that never ends, or a stand-by task that never
                // returns, fails the case as `Stalled`.
                let (probe, late) = try await tc.withStallDetection(after: hangLimit) { heartbeat in
                    let probe = await withTaskGroup(
                        of: Void.self,
                        returning: FrameSendOutcome.self
                    ) { group in
                        group.addTask {
                            await FrameWritingTask.$current.withValue(.standBy) {
                                await writer.standBy()
                            }
                        }
                        await withTaskGroup(of: Void.self) { senderGroup in
                            for (sender, plan) in senders.enumerated() {
                                senderGroup.addTask {
                                    await FrameWritingTask.$current.withValue(.sender(sender)) {
                                        await sendFrames(
                                            plan,
                                            as: sender,
                                            through: writer,
                                            to: channel,
                                            recordingIn: record,
                                            heartbeat: heartbeat
                                        )
                                    }
                                }
                            }
                        }
                        // Every sender has returned; the stand-by task may
                        // still be writing what a cancelled writer left.
                        channel.heal()
                        let probe = FrameSendOutcome(await writer.write(FrameTag.probe.frame))
                        writer.finish()
                        return probe
                    }
                    heartbeat.beat()
                    return (probe, FrameSendOutcome(await writer.write(FrameTag.late.frame)))
                }
                settled = true

                let sends = record.current
                let channelRecord = channel.current
                for label in sends.events.union(channelRecord.events).sorted() {
                    try tc.event(label)
                }

                #expect(!channelRecord.overlapped, "two writes ran at once")
                #expect(
                    !channelRecord.batches.contains { $0.isEmpty },
                    "an empty batch was written: \(channelRecord.batches)"
                )
                let written = channelRecord.batches.flatMap { $0 }
                #expect(
                    Set(written).count == written.count,
                    "a frame was written twice: \(written)"
                )
                let sentWritten = written.filter { $0 != .probe && $0 != .late }
                let succeeded = Set(sends.sends.filter { $0.outcome == .success }.map(\.tag))
                let failedButWritten = Set(sentWritten).subtracting(succeeded)
                #expect(
                    failedButWritten.isEmpty,
                    "frames whose sends failed were written: \(failedButWritten)"
                )
                for send in sends.sends where send.wasCancelled {
                    #expect(
                        send.outcome == .cancelled,
                        "frame \(send.tag), sent from a cancelled task, ended \(send.outcome)"
                    )
                }
                for sender in senders.indices {
                    let order = sentWritten.filter { $0.sender == sender }.map(\.index)
                    #expect(
                        order == order.sorted(),
                        "sender \(sender)'s frames went out as \(order)"
                    )
                    let outcomes = sends.sends.filter { $0.tag.sender == sender }.map(\.outcome)
                    if let failure = outcomes.firstIndex(where: { $0 != .success }) {
                        #expect(
                            !outcomes[failure...].contains(.success),
                            "sender \(sender) succeeded after a failure: \(outcomes)"
                        )
                    }
                }
                #expect(channelRecord.callsWhileDead == 0, "a dead channel was written to")
                if channelRecord.dead {
                    // A write the stand-by task began before the heal may
                    // still die after it, with the test's frame queued
                    // behind it: that send succeeded, and its frame dropped.
                    #expect(
                        probe != .cancelled,
                        "the test's frame ended \(probe) on a dead channel"
                    )
                    #expect(
                        !written.contains(.probe),
                        "the test's frame was written to a dead channel"
                    )
                } else {
                    let unwritten = succeeded.subtracting(sentWritten)
                    #expect(
                        unwritten.isEmpty,
                        "frames whose sends succeeded were never written: \(unwritten)"
                    )
                    #expect(probe == .success, "the test's frame ended \(probe)")
                    #expect(written.last == .probe, "the test's frame was not last: \(written)")
                }
                #expect(late == .channelClosed, "a send after the stand-by task ended went \(late)")
            }
        }
    }

#endif

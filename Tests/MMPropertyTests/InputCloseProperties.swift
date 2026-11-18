// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMTestSupport
    import Testing

    @testable import MMCLI

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif

    /// How a consumer leaves a read it no longer waits for.
    enum AbandonedReadEnding: String, CaseIterable, Sendable {
        case interrupt = "an interrupt"
        case cancel = "a cancel"
    }

    /// Reads `input` until its first read is waiting, ends that read the way
    /// `ending` says, and returns what the reading delivered.
    func abandonFirstRead(
        of input: MMCLIInput,
        by ending: AbandonedReadEnding
    ) async -> [MMCLIInput.Element] {
        await withTaskGroup(of: [MMCLIInput.Element].self) { tasks in
            tasks.addTask {
                var delivered: [MMCLIInput.Element] = []
                for await element in input {
                    delivered.append(element)
                }
                return delivered
            }
            while input.reader.hasParkedRead == false {
                await Task.yield()
            }
            switch ending {
                case .interrupt:
                    input.interrupt()
                case .cancel:
                    tasks.cancelAll()
            }
            return await tasks.next() ?? []
        }
    }

    @Suite("Closing a descriptor input", .hegel)
    struct InputCloseProperties {
        /// An input whose read was abandoned, by an interrupt or a cancel,
        /// closes its descriptor only after that read has run. While the
        /// read still waits on a busy pool, `close()` waits for it, and the
        /// read takes the bytes written behind it from the pipe, so none is
        /// left for whatever reuses the descriptor number. With a free pool
        /// the read may already be waiting in `read(2)`, and it takes what
        /// arrives first: the pipe keeps only the rest of the bytes.
        ///
        /// The pool is held in half the cases, each ending is half, and the
        /// write end stays open during the close in half. One byte and the
        /// most a case writes come up in about a sixth each, and a release
        /// before `close()` gets to run in about a ninth, so those are judged
        /// once 1,000 cases have passed.
        @Test
        func closingWaitsForTheAbandonedRead() async throws {
            try await property(
                reaching: [
                    "a held pool", "a free pool", "an interrupt", "a cancel",
                    "the write end open during the close",
                ],
                reachingAfter: [
                    "one byte": 1_000, "the most bytes": 1_000,
                    "a held pool and a cancel": 1_000, "a release at once": 1_000,
                ]
            ) { tc in
                let held = try #draw(.bool(), from: tc)
                let ending = try #draw(.element(of: AbandonedReadEnding.allCases), from: tc)
                // One byte, a pipe's atomic write on Darwin and a page are
                // the sizes a read may split at; about half the counts are
                // one of them.
                let count = try #draw(
                    .oneOf(.element(of: [1, 512, 4096]), .int(in: 1...4096)),
                    from: tc
                )
                let writeEndOpen = try #draw(.bool(), from: tc)
                let yieldsBeforeRelease = try #draw(.int(in: 0...8), from: tc)
                try tc.event(held ? "a held pool" : "a free pool")
                try tc.event(ending.rawValue)
                if held && ending == .cancel { try tc.event("a held pool and a cancel") }
                if writeEndOpen { try tc.event("the write end open during the close") }
                if count == 1 { try tc.event("one byte") }
                if count == 4096 { try tc.event("the most bytes") }
                if yieldsBeforeRelease == 0 { try tc.event("a release at once") }

                try await withHeldThreadPool { pool in
                    if !held { pool.release() }
                    var descriptors: [CInt] = [0, 0]
                    try #require(pipe(&descriptors) == 0)
                    let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
                    // A second descriptor on the pipe shows what the read
                    // left once the input's own descriptor is closed.
                    let witness = dup(readEnd)
                    defer { _ = close(witness) }
                    let input = MMCLIInput(descriptor: readEnd, name: "pipe", pool: pool.pool)

                    let delivered = await abandonFirstRead(of: input, by: ending)
                    #expect(delivered.isEmpty)

                    let written = (0..<count).map { UInt8(truncatingIfNeeded: $0) }
                    #expect(write(writeEnd, written, written.count) == written.count)
                    if !writeEndOpen { _ = close(writeEnd) }
                    let closed = CompletionFlag()
                    await withTaskGroup(of: Void.self) { tasks in
                        tasks.addTask {
                            await input.close()
                            closed.finish()
                        }
                        for _ in 0..<yieldsBeforeRelease {
                            await Task.yield()
                        }
                        if held {
                            #expect(!closed.isFinished, "close() returned under a queued read")
                        }
                        pool.release()
                    }
                    if writeEndOpen { _ = close(writeEnd) }

                    let left = unreadBytes(in: witness)
                    if held {
                        #expect(left.isEmpty, "the read ran after the close")
                    } else {
                        #expect(written.suffix(left.count).elementsEqual(left))
                    }
                }
            }
        }
    }

#endif

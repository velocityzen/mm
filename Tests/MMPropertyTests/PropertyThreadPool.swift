// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import NIOCore
    import NIOPosix
    import Testing

    /// Runs each test of a suite on threads of its own, not the cooperative
    /// pool. A synchronous property blocks its thread for its whole run,
    /// minutes under the nightly profile, and the cooperative pool is only
    /// as wide as the machine has cores. With every one of those threads
    /// held by a synchronous property, the async properties' tasks, and
    /// Swift Testing's own event reporting, wait until one finishes, and
    /// Hegel's TooSlow check fails the async properties: two valid inputs
    /// in 100 seconds where alone they make 10,000 in two.
    ///
    /// Each test runs under a task executor preference for
    /// `PropertyThreadPool.shared`, so its task, task-local values and all,
    /// runs there. It is for suites whose properties are all synchronous:
    /// an async property's tasks belong on the cooperative pool, which this
    /// keeps free for them.
    struct OffTheCooperativePool: SuiteTrait, TestTrait, TestScoping {
        var isRecursive: Bool { true }

        /// A scope around each test case, the one that calls the test.
        func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
            testCase == nil ? nil : self
        }

        func provideScope(
            for test: Test,
            testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            try await withTaskExecutorPreference(PropertyThreadPool.shared) {
                try await function()
            }
        }
    }

    extension Trait where Self == OffTheCooperativePool {
        /// Runs the suite's tests on `PropertyThreadPool`; see
        /// `OffTheCooperativePool`.
        static var offTheCooperativePool: Self { Self() }
    }

    /// A task executor on a `NIOThreadPool` of its own, as wide as the
    /// machine has cores, for tasks that block their thread. It lives as
    /// long as the test process and is never shut down, so every job it
    /// takes runs.
    final class PropertyThreadPool: TaskExecutor {
        static let shared = PropertyThreadPool()

        private let pool: NIOThreadPool

        private init() {
            self.pool = NIOThreadPool(numberOfThreads: System.coreCount)
            self.pool.start()
        }

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            // `submit`, not `runIfActive`: an executor hands a job on
            // without waiting for it.
            self.pool.submit { _ in
                job.runSynchronously(on: self.asUnownedTaskExecutor())
            }
        }
    }

#endif

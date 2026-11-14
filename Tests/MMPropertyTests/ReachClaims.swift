// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import Foundation

    /// The reach claims a property passes to `property(reaching:)`: the
    /// states it must visit for its checks to mean anything.
    ///
    /// A 100-case run reaches a state in a share of its cases that varies
    /// far more from run to run than the average suggests. In one run Hegel
    /// may make no case at all down a branch it takes a quarter of the time
    /// on average, and a claim on a state behind that branch then fails with
    /// nothing wrong. So `everyRun` holds only the states that every one of
    /// nine 100-case statistics runs reached in a fifth of its cases or
    /// more, and every 1,000-case run in a tenth or more. `deepRuns` holds
    /// the states every one of four 1,000-case statistics runs reached in
    /// 3% of its cases or more, the rare boundary states among them. They
    /// are claimed only when the run makes 1,000 cases or more: the nightly
    /// profile's 10,000, or a `HEGEL_TEST_CASES` run. Rarer events are
    /// recorded for the statistics but not claimed.
    func reachClaims(everyRun: [String], deepRuns: [String] = []) -> [String] {
        isDeepRun ? everyRun + deepRuns : everyRun
    }

    /// Whether this run makes 1,000 cases or more. `HEGEL_TEST_CASES` says
    /// so when it is set, since it wins over every profile; otherwise the
    /// nightly profile does (see `hegel.toml`).
    let isDeepRun: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if let testCases = environment["HEGEL_TEST_CASES"] {
            return (Int(testCases) ?? 0) >= 1_000
        }
        return environment["HEGEL_DEFAULT_PROFILE"] == "nightly"
    }()

#endif

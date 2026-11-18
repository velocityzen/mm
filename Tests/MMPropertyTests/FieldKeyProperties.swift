// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import Testing

    /// Keys at and next to the edges of `Int`, and around zero.
    let edgeKeys: [Int] = [.min, .min + 1, -1, 0, 1, .max - 1, .max]

    /// Which of the two edges of `Int` a fields list holds as keys.
    enum EdgeKeyChoice: String, CaseIterable, Sendable {
        case neither = "neither edge"
        case smallest = "Int.min alone"
        case largest = "Int.max alone"
        case both = "both edges"

        var keys: [Int] {
            switch self {
                case .neither: []
                case .smallest: [.min]
                case .largest: [.max]
                case .both: [.min, .max]
            }
        }
    }

    /// The two helpers that add a field unlike every field of a list.
    enum FreshFieldHelper: String, CaseIterable, Sendable {
        case compatibility = "the compatibility helper"
        case lock = "the lock helper"
    }

    @Suite("Unused field keys", .hegel, .offTheCooperativePool)
    struct FieldKeyProperties {
        /// `unusedKey(from:avoiding:)` returns the first key none of the
        /// taken ones is, counting up from the start and on from `Int.min`
        /// after `Int.max`: the key is free, and every key it passed over is
        /// taken.
        ///
        /// The start comes from the edges and zero about half the time, and
        /// a run of up to four taken keys follows it, so the start is taken
        /// in most cases and free in about an eighth. A free start, a run
        /// that crosses `Int.max`, and a set that holds both edges each come
        /// up in about a tenth of the cases, so those are judged once 1,000
        /// cases have passed.
        @Test
        func anUnusedKeyIsTheFirstFreeOneCountingUp() throws {
            try property(
                reaching: ["the start taken"],
                reachingAfter: [
                    "the start free": 1_000, "a count past Int.max": 1_000,
                    "both edges taken": 1_000,
                ]
            ) { tc in
                let start = try #draw(.oneOf(.element(of: edgeKeys), .int()), from: tc)
                let run = try #draw(.int(in: 0...4), from: tc)
                let others = try #draw(
                    .array(of: .oneOf(.element(of: edgeKeys), .int()), count: 0...3),
                    from: tc
                )
                let taken = Set((0..<run).map { start &+ $0 } + others)
                try tc.event(taken.contains(start) ? "the start taken" : "the start free")
                if taken.contains(.min) && taken.contains(.max) { try tc.event("both edges taken") }

                let key = FingerprintGenerators.unusedKey(from: start, avoiding: taken)
                #expect(!taken.contains(key), "the key is taken")
                if key < start { try tc.event("a count past Int.max") }
                // Walking up from the start, every key before the result is
                // taken; a set of n keys holds the walk to n steps.
                var passed = start
                var free: [Int] = []
                while passed != key && free.isEmpty && passed &- start <= taken.count {
                    if !taken.contains(passed) { free.append(passed) }
                    passed &+= 1
                }
                #expect(free.isEmpty, "a free key before the result")
                #expect(passed == key, "the result is not the next key up")
            }
        }

        /// Either helper's fresh field is unlike every field of the list,
        /// whatever keys the list holds, both edges of `Int` among them: its
        /// name is none of theirs, and its key, when it has one, none of
        /// theirs. The compatibility helper keys it exactly when the list is
        /// keyed.
        ///
        /// Each helper is half the cases, and a keyed list about two thirds.
        /// A keyed list holding both edges and a compatibility key that
        /// counts past `Int.max` each come up in about a fifth of the cases,
        /// and an empty list in about a sixteenth, so those are judged once
        /// 1,000 cases have passed.
        @Test
        func aFreshFieldIsUnlikeEveryField() throws {
            try property(
                reaching: [
                    "the compatibility helper", "the lock helper", "a keyed list",
                ],
                reachingAfter: [
                    "a keyed list holding both edges": 1_000,
                    "a compatibility key past Int.max": 1_000,
                    "an empty list": 1_000,
                ]
            ) { tc in
                let helper = try #draw(.element(of: FreshFieldHelper.allCases), from: tc)
                let edges = try #draw(.element(of: EdgeKeyChoice.allCases), from: tc)
                // The shortest list is weighted: no fields at all, and the
                // edges with nothing beside them.
                let shortest = edges.keys.count
                let count = try #draw(
                    .oneOf(.element(of: [shortest]), .int(in: shortest...4)),
                    from: tc
                )
                let keyed = try #draw(.bool(probability: 0.75), from: tc)
                var keys = edges.keys
                while keys.count < count {
                    let key = try #draw(.oneOf(.element(of: edgeKeys), .int()), from: tc)
                    if !keys.contains(key) { keys.append(key) }
                }
                var names: [String] = []
                for _ in 0..<count {
                    var name = try #draw(FingerprintGenerators.names, from: tc)
                    while names.contains(name) { name += "'" }
                    names.append(name)
                }
                let fields = zip(names, keys).map { name, key in
                    TypeSchema.Field(key: keyed ? key : nil, name: name, type: .int)
                }
                try tc.event(helper.rawValue)
                if fields.isEmpty { try tc.event("an empty list") }
                if keyed && !fields.isEmpty {
                    try tc.event("a keyed list")
                    if edges == .both { try tc.event("a keyed list holding both edges") }
                }

                let field: TypeSchema.Field
                switch helper {
                    case .compatibility:
                        field = try CompatibilityGenerators.freshField(
                            tc,
                            among: fields,
                            type: .string
                        )
                        if !fields.isEmpty {
                            #expect((field.key != nil) == keyed, "keyed unlike its list")
                        }
                        if let key = field.key, let largest = fields.compactMap(\.key).max(),
                            key < largest
                        {
                            try tc.event("a compatibility key past Int.max")
                        }
                    case .lock:
                        field = try LockGenerators.freshField(tc, among: fields, type: .string)
                }
                #expect(!fields.contains { $0.name == field.name }, "a name the list has")
                if let key = field.key {
                    #expect(!fields.contains { $0.key == key }, "a key the list has")
                }
            }
        }
    }

#endif

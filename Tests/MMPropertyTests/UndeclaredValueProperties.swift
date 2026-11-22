// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    /// A contract as a peer built from it sees it.
    enum Earlier: MethodNamespace {
        #schema("evolving") {
            Enum("Mood") {
                Case("calm")
                Case("busy")
            }
            Union("Signal") {
                Case("idle")
                Case("ping") {
                    Field("count", .uint)
                }
                Case("nest") {
                    Field("inner", .array(.reference("Signal")))
                    Field("mood", "Mood")
                }
            }
            Call("put") {
                Access { .write }
                Request {
                    Field("mood", "Mood")
                    Field("moods", .array(.optional(.reference("Mood"))))
                    Field("signal", "Signal")
                    Field("signals", .optional(.array(.reference("Signal"))))
                }
            }
        }
    }

    /// The same contract a version later: two more enum values and two more
    /// union cases, one of them with fields.
    enum Later: MethodNamespace {
        #schema("evolving") {
            Enum("Mood") {
                Case("calm")
                Case("busy")
                Case("elated")
                Case("weary")
            }
            Union("Signal") {
                Case("idle")
                Case("ping") {
                    Field("count", .uint)
                }
                Case("nest") {
                    Field("inner", .array(.reference("Signal")))
                    Field("mood", "Mood")
                }
                Case("burst") {
                    Field("sizes", .array(.uint))
                    Field(4, "note", .optional(.string))
                    Field("mood", "Mood")
                    Field("echoes", .array(.reference("Signal")))
                }
                Case("halt")
            }
            Call("put") {
                Access { .write }
                Request {
                    Field("mood", "Mood")
                    Field("moods", .array(.optional(.reference("Mood"))))
                    Field("signal", "Signal")
                    Field("signals", .optional(.array(.reference("Signal"))))
                }
            }
        }
    }

    enum EvolvingContractGenerators {
        /// A later request whose enum values and union cases are ones the
        /// earlier contract does not declare at a rate drawn for the case,
        /// from never to almost always.
        static let laterRequests: Gen<Later.PutRequest> = Gen { tc in
            let rate = try tc.draw(.element(of: [0.0, 0.3, 0.6, 0.9]))
            let moods = Self.moods(undeclaredRate: rate)
            let signals = Self.signals(undeclaredRate: rate)
            return try Later.PutRequest(
                mood: tc.draw(moods),
                moods: tc.draw(.array(of: .optional(moods), count: 0...4)),
                signal: tc.draw(signals),
                signals: tc.draw(.optional(.array(of: signals, count: 0...4)))
            )
        }

        static func moods(undeclaredRate: Double) -> Gen<Later.Mood> {
            Gen<Bool>.bool(probability: undeclaredRate).flatMap {
                $0 ? .element(of: [.elated, .weary]) : .element(of: [.calm, .busy])
            }
        }

        static func signals(undeclaredRate: Double) -> Gen<Later.Signal> {
            let moods = Self.moods(undeclaredRate: undeclaredRate)
            let declaredLeaves: Gen<Later.Signal> = .oneOf(
                .just(.idle),
                Gen<UInt64>.integer().map { .ping(count: $0) }
            )
            let undeclaredLeaves: Gen<Later.Signal> = .oneOf(
                .just(.halt),
                Gen { tc in
                    try .burst(
                        sizes: tc.draw(.array(of: Gen<UInt64>.integer(), count: 0...3)),
                        note: tc.draw(.optional(.string())),
                        mood: tc.draw(moods),
                        echoes: tc.draw(.array(of: declaredLeaves, count: 0...2))
                    )
                }
            )
            return .recursive(
                maxDepth: 3,
                leaf: Gen<Bool>.bool(probability: undeclaredRate).flatMap {
                    $0 ? undeclaredLeaves : declaredLeaves
                },
                branch: { inner in
                    Gen { tc in
                        try .nest(
                            inner: tc.draw(.array(of: inner, count: 0...3)),
                            mood: tc.draw(moods)
                        )
                    }
                }
            )
        }

        /// Text for an enum value or a union case name: the names either
        /// contract declares, the empty string, any string, and strings at
        /// the lengths where a fixstr and a str8 run out.
        static let texts: Gen<String> = .oneOf(
            .element(of: ["calm", "busy", "elated", "unknown", "", "idle", "ping", "nest", "halt"]),
            .string(),
            .string(of: .ascii, count: 31...32),
            .string(of: .ascii, count: 255...256)
        )

        /// Nesting limits for a decode: the default, and more often ones a
        /// level or two deep that a union's fields cross.
        static let nestingLimits: Gen<Int> = .oneOf(.just(128), .int(in: 1...3), .int(in: 1...3))
    }

    /// What an earlier peer makes of a later request: the enum values and
    /// union cases it declares as themselves, and the rest in `unknown` —
    /// an undeclared case with the bytes of its fields, as the later
    /// contract writes them.
    func earlierReading(_ request: Later.PutRequest) throws -> Earlier.PutRequest {
        Earlier.PutRequest(
            mood: earlierReading(request.mood),
            moods: request.moods.map { $0.map(earlierReading) },
            signal: try earlierReading(request.signal),
            signals: try request.signals.map { try $0.map(earlierReading) }
        )
    }

    func earlierReading(_ mood: Later.Mood) -> Earlier.Mood {
        switch mood {
            case .calm: .calm
            case .busy: .busy
            case .elated: .unknown("elated")
            case .weary: .unknown("weary")
            case .unknown(let raw): .unknown(raw)
        }
    }

    func earlierReading(_ signal: Later.Signal) throws -> Earlier.Signal {
        switch signal {
            case .idle: return .idle
            case .ping(let count): return .ping(count: count)
            case .nest(let inner, let mood):
                return .nest(inner: try inner.map(earlierReading), mood: earlierReading(mood))
            case .burst:
                // {0: "burst", 1: fields}: a fixmap header, the key 0, the
                // name in a fixstr, then the key 1.
                let bytes = Array(try MMPackEncoder().encode(signal).get().readableBytesView)
                let prefix = [0x82, 0x00, 0xa5] + Array("burst".utf8) + [0x01]
                guard bytes.starts(with: prefix) else {
                    throw GeneratorFault(description: "burst wrote \(bytes)")
                }
                return .unknown(tag: "burst", fields: MMPackRawValue(bytes.dropFirst(prefix.count)))
            case .halt: return .unknown(tag: "halt", fields: nil)
            case .unknown(let tag, let fields): return .unknown(tag: tag, fields: fields)
        }
    }

    /// A value as Swift describes it, which names each enum case, where a
    /// generated enum's `==` compares only the text it writes.
    func described<Value>(_ value: Value) -> String {
        String(reflecting: value)
    }

    /// Where a later request holds what an earlier contract does not
    /// declare, outside the fields of an undeclared case, which an earlier
    /// peer never reads.
    struct Undeclared {
        var enumValue = false
        var caseWithFields = false
        var caseWithoutFields = false
        var insideDeclaredCase = false

        var nothing: Bool {
            !self.enumValue && !self.caseWithFields && !self.caseWithoutFields
        }

        init(_ request: Later.PutRequest) {
            self.visit(request.mood, insideCase: false)
            for mood in request.moods {
                if let mood { self.visit(mood, insideCase: false) }
            }
            self.visit(request.signal, insideCase: false)
            for signal in request.signals ?? [] {
                self.visit(signal, insideCase: false)
            }
        }

        private mutating func visit(_ mood: Later.Mood, insideCase: Bool) {
            guard mood == .elated || mood == .weary else { return }
            self.enumValue = true
            if insideCase { self.insideDeclaredCase = true }
        }

        private mutating func visit(_ signal: Later.Signal, insideCase: Bool) {
            switch signal {
                case .idle, .ping, .unknown: return
                case .nest(let inner, let mood):
                    self.visit(mood, insideCase: true)
                    for signal in inner { self.visit(signal, insideCase: true) }
                    return
                case .burst: self.caseWithFields = true
                case .halt: self.caseWithoutFields = true
            }
            if insideCase { self.insideDeclaredCase = true }
        }
    }

    /// The ways a union's map can be written: as generated code writes it,
    /// and five others a decoder accepts as the same value.
    enum UnionLayout: CaseIterable {
        case generated
        case byName
        case fieldsFirst
        case extraKey
        case repeatedKeys
        case keysAndNames

        /// The map for case `tag` with `fields`, a value's bytes or none.
        func bytes(tag: String, fields: [UInt8]?) throws -> [UInt8] {
            let name = Array(try MMPackEncoder().encode(tag).get().readableBytesView)
            let caseKey: [UInt8] = self == .byName ? [0xa4] + Array("case".utf8) : [0x00]
            let fieldsKey: [UInt8] = self == .byName ? [0xa6] + Array("fields".utf8) : [0x01]
            var entries: [[UInt8]] = [caseKey + name]
            if let fields { entries.append(fieldsKey + fields) }
            switch self {
                case .generated, .byName: break
                case .fieldsFirst: entries.reverse()
                case .extraKey: entries.append([0x07, 0xc3])
                case .repeatedKeys:
                    // The first occurrence of a key wins.
                    entries.append([0x00, 0xa1, 0x78])
                    if fields != nil { entries.append([0x01, 0xc0]) }
                case .keysAndNames:
                    // A slot's integer key wins over its name.
                    entries.append([0xa4] + Array("case".utf8) + [0xa1, 0x78])
                    if fields != nil { entries.append([0xa6] + Array("fields".utf8) + [0xc0]) }
            }
            return [0x80 | UInt8(entries.count)] + entries.joined()
        }
    }

    /// A raw value held through a single-value container, as a hand-written
    /// wrapper would hold one.
    struct WrappedRawValue: Codable, Equatable {
        var raw: MMPackRawValue

        init(_ raw: MMPackRawValue) {
            self.raw = raw
        }

        init(from decoder: any Decoder) throws {
            self.raw = try decoder.singleValueContainer().decode(MMPackRawValue.self)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.raw)
        }
    }

    /// Where a raw value sits in what the coders read: alone, as an array's
    /// element, through a wrapper in an array, or under a map key. Each
    /// reaches the raw read by its own path: the decoder's top-level read,
    /// an array's element, a single-value container, a map's index.
    enum RawValuePosition: CaseIterable {
        case alone
        case arrayElement
        case wrappedInArray
        case mapValue

        /// The raw value's depth: its container's plus one, or 0 alone.
        var depth: Int { self == .alone ? 0 : 1 }

        /// The bytes before the value: a one-element array, or a one-entry
        /// map under the key "k".
        var prefix: [UInt8] {
            switch self {
                case .alone: []
                case .arrayElement, .wrappedInArray: [0x91]
                case .mapValue: [0x81, 0xa1, 0x6b]
            }
        }

        /// The raw value read from `bytes` through the coders.
        func read(_ bytes: ByteBuffer, maxDepth: Int) -> Result<MMPackRawValue?, MMWireError> {
            switch self {
                case .alone:
                    decodedThroughCodable(MMPackRawValue.self, from: bytes, maxDepth: maxDepth)
                        .map { $0 }
                case .arrayElement:
                    decodedThroughCodable([MMPackRawValue].self, from: bytes, maxDepth: maxDepth)
                        .map(\.first)
                case .wrappedInArray:
                    decodedThroughCodable([WrappedRawValue].self, from: bytes, maxDepth: maxDepth)
                        .map { $0.first?.raw }
                case .mapValue:
                    decodedThroughCodable(
                        [String: MMPackRawValue].self,
                        from: bytes,
                        maxDepth: maxDepth
                    )
                    .map { $0["k"] }
            }
        }

        /// `raw` written here through the coders.
        func write(_ raw: MMPackRawValue) -> Result<ByteBuffer, MMWireError> {
            switch self {
                case .alone: encodedThroughCodable(raw)
                case .arrayElement: encodedThroughCodable([raw])
                case .wrappedInArray: encodedThroughCodable([WrappedRawValue(raw)])
                case .mapValue: encodedThroughCodable(["k": raw])
            }
        }
    }

    @Suite("Values a contract does not declare", .hegel)
    struct UndeclaredValueProperties {
        /// A peer built from an earlier contract reads what a later one
        /// writes and writes it back unchanged: enum values and union cases
        /// it declares read as themselves, and the rest as `unknown`, an
        /// enum value with its text and a union case with its name and its
        /// fields' bytes, wherever they sit. Its generated code and its
        /// `Codable` read the same value, and both write the bytes they
        /// read.
        @Test
        func valuesALaterContractAddsComeBackUnchanged() throws {
            try property(
                reaching: [
                    "an undeclared enum value", "an undeclared case with fields",
                    "an undeclared case without fields",
                    "an undeclared value inside a declared case",
                ],
                reachingAfter: ["nothing undeclared": 1_000]
            ) { tc in
                let later = try #draw(EvolvingContractGenerators.laterRequests, from: tc)
                let undeclared = Undeclared(later)
                if undeclared.enumValue { try tc.event("an undeclared enum value") }
                if undeclared.caseWithFields { try tc.event("an undeclared case with fields") }
                if undeclared.caseWithoutFields {
                    try tc.event("an undeclared case without fields")
                }
                if undeclared.insideDeclaredCase {
                    try tc.event("an undeclared value inside a declared case")
                }
                if undeclared.nothing { try tc.event("nothing undeclared") }

                let bytes = try encodedThroughGeneratedCode(later).get()
                let expected = try earlierReading(later)
                // Enum values compare by their text, so `.unknown("busy")`
                // equals `.busy`; their descriptions tell the cases apart.
                #expect(
                    decodedThroughGeneratedCode(Earlier.PutRequest.self, from: bytes).map(described)
                        == .success(described(expected)),
                    "\(hex(bytes))"
                )
                #expect(
                    decodedThroughCodable(Earlier.PutRequest.self, from: bytes).map(described)
                        == .success(described(expected)),
                    "\(hex(bytes))"
                )
                #expect(encodedThroughGeneratedCode(expected) == .success(bytes), "\(hex(bytes))")
                #expect(encodedThroughCodable(expected) == .success(bytes), "\(hex(bytes))")
            }
        }

        /// Any text where an enum value belongs reads as the case it names,
        /// or as `unknown` with the text, through generated code and through
        /// `Codable`, and both write back the bytes they read.
        @Test
        func anyEnumValueComesBackUnchanged() throws {
            try property(
                reaching: ["an enum value it declares", "an enum value it does not declare"],
                reachingAfter: ["text a str8 holds": 1_000]
            ) { tc in
                let text = try #draw(
                    .oneOf(.element(of: ["calm", "busy"]), EvolvingContractGenerators.texts),
                    from: tc
                )
                if text.utf8.count > 31 { try tc.event("text a str8 holds") }
                let bytes = try encodedThroughCodable(text).get()
                let expected: Earlier.Mood
                switch text {
                    case "calm": expected = .calm
                    case "busy": expected = .busy
                    default: expected = .unknown(text)
                }
                if case .unknown = expected {
                    try tc.event("an enum value it does not declare")
                } else {
                    try tc.event("an enum value it declares")
                }
                #expect(
                    decodedThroughGeneratedCode(Earlier.Mood.self, from: bytes).map(described)
                        == .success(described(expected)),
                    "\(hex(bytes))"
                )
                #expect(
                    decodedThroughCodable(Earlier.Mood.self, from: bytes).map(described)
                        == .success(described(expected)),
                    "\(hex(bytes))"
                )
                #expect(encodedThroughGeneratedCode(expected) == .success(bytes), "\(hex(bytes))")
                #expect(encodedThroughCodable(expected) == .success(bytes), "\(hex(bytes))")
            }
        }

        /// Two enum values are equal exactly when they write the same text,
        /// an `unknown` holding a declared case's name and that case
        /// included, and equal values hash alike, so a set, or a map's keys,
        /// holds one of them.
        @Test
        func enumValuesAreEqualExactlyWhenTheyWriteTheSameText() throws {
            try property(reaching: ["equal", "unequal", "an unknown holding a declared name"]) {
                tc in
                let values: Gen<Earlier.Mood> = .oneOf(
                    .element(of: [.calm, .busy]),
                    Gen<String>.oneOf(
                        .element(of: ["calm", "busy", "elated"]),
                        .element(of: ["calm", "busy", "elated"]),
                        .string()
                    )
                    .map { .unknown($0) }
                )
                let first = try #draw(values, from: tc)
                let second = try #draw(values, from: tc)
                for value in [first, second] {
                    if case .unknown(let text) = value, ["calm", "busy"].contains(text) {
                        try tc.event("an unknown holding a declared name")
                    }
                }
                let firstBytes = try encodedThroughGeneratedCode(first).get()
                let secondBytes = try encodedThroughGeneratedCode(second).get()
                try tc.event(firstBytes == secondBytes ? "equal" : "unequal")
                #expect((first == second) == (firstBytes == secondBytes))
                if first == second {
                    #expect(Set([first, second]).count == 1)
                }
            }
        }

        /// Any case name a union does not declare, with no fields or any
        /// value as its fields, reads as `unknown` with the name and the
        /// fields' exact bytes, however its map is laid out. Generated code
        /// and `Codable` read the same, failing alike when the fields nest
        /// past the decode's limit, and both write the map as generated code
        /// lays it out: for that layout, the bytes they read.
        @Test
        func anyUndeclaredCaseComesBackUnchanged() throws {
            try property(
                reaching: [
                    "fields", "no fields", "laid out as generated code writes it",
                    "laid out another way",
                ],
                reachingAfter: [
                    "fields nested past the limit": 1_000, "a name a str8 holds": 1_000,
                    "laid out byName": 1_000, "laid out fieldsFirst": 1_000,
                    "laid out extraKey": 1_000, "laid out repeatedKeys": 1_000,
                    "laid out keysAndNames": 1_000,
                ]
            ) { tc in
                let limit = try #draw(EvolvingContractGenerators.nestingLimits, from: tc)
                let name = try #draw(EvolvingContractGenerators.texts, from: tc)
                let tag = ["idle", "ping", "nest"].contains(name) ? name + "+" : name
                if tag.utf8.count > 31 { try tc.event("a name a str8 holds") }
                let fields =
                    try #draw(.bool(), from: tc)
                    ? try #draw(PackGenerators.values(of: PackGenerators.scalarFamilies), from: tc)
                    : nil
                try tc.event(fields == nil ? "no fields" : "fields")
                let layout = try #draw(
                    .oneOf(.just(UnionLayout.generated), .element(of: UnionLayout.allCases)),
                    from: tc
                )
                if layout == .generated {
                    try tc.event("laid out as generated code writes it")
                } else {
                    try tc.event("laid out another way")
                    try tc.event("laid out \(layout)")
                }
                let bytes = ByteBuffer(bytes: try layout.bytes(tag: tag, fields: fields))
                let generated = ByteBuffer(
                    bytes: try UnionLayout.generated.bytes(tag: tag, fields: fields)
                )

                // The union's map sits at depth 0 and its fields at 1.
                var fit = ByteBuffer(bytes: fields ?? [])
                let fits =
                    fields == nil
                    || (try? fit.skipByReads(currentDepth: 1, cap: limit).get()) != nil
                let expected: Result<Earlier.Signal, MMWireError>
                if fits {
                    expected = .success(.unknown(tag: tag, fields: fields.map(MMPackRawValue.init)))
                } else {
                    try tc.event("fields nested past the limit")
                    expected = .failure(.nestingTooDeep(limit: limit))
                }
                #expect(
                    decodedThroughGeneratedCode(Earlier.Signal.self, from: bytes, maxDepth: limit)
                        == expected,
                    "\(hex(bytes))"
                )
                #expect(
                    decodedThroughCodable(Earlier.Signal.self, from: bytes, maxDepth: limit)
                        == expected,
                    "\(hex(bytes))"
                )
                guard case .success(let value) = expected else { return }
                #expect(encodedThroughGeneratedCode(value) == .success(generated), "\(hex(bytes))")
                #expect(encodedThroughCodable(value) == .success(generated), "\(hex(bytes))")
            }
        }

        /// Through the coders, an ``MMPackRawValue`` reads exactly one
        /// value's bytes wherever it sits, failing with `nestingTooDeep`
        /// exactly when skipping the value at its depth would, and writes the
        /// bytes back as they are.
        ///
        /// Mutation-checked: a raw value written as a `bin`, or read as its
        /// first byte only, fails this. A raw read that ignores its depth
        /// can't fail it, here or in a union: each container slices its
        /// elements with the depth-checked skip before decoding them, and
        /// generated union code walks its map the same way first.
        @Test
        func aRawValueReadsOneValueWhereverItSits() throws {
            try property(
                reaching: ["read"],
                reachingAfter: [
                    "nested past the limit": 1_000, "alone": 1_000, "arrayElement": 1_000,
                    "wrappedInArray": 1_000, "mapValue": 1_000,
                ]
            ) { tc in
                let limit = try #draw(EvolvingContractGenerators.nestingLimits, from: tc)
                let value = try #draw(
                    PackGenerators.values(of: PackGenerators.scalarFamilies),
                    from: tc
                )
                let position = try #draw(.element(of: RawValuePosition.allCases), from: tc)
                try tc.event("\(position)")
                let bytes = ByteBuffer(bytes: position.prefix + value)

                var fit = ByteBuffer(bytes: value)
                let expected: Result<MMPackRawValue?, MMWireError>
                if case .success = fit.skipByReads(currentDepth: position.depth, cap: limit) {
                    try tc.event("read")
                    expected = .success(MMPackRawValue(value))
                } else {
                    try tc.event("nested past the limit")
                    expected = .failure(.nestingTooDeep(limit: limit))
                }
                #expect(position.read(bytes, maxDepth: limit) == expected, "\(hex(bytes))")
                #expect(position.write(MMPackRawValue(value)) == .success(bytes), "\(hex(bytes))")
            }
        }
    }

#endif

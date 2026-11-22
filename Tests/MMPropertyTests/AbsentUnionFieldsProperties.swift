// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMCLI
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    /// A union and declared errors whose cases gained fields after a writer
    /// whose cases had none, which leaves key 1 out: cases whose fields are
    /// all optional or have a default, with a default of each kind, and
    /// cases that still need a field, among them one whose required field
    /// is a structure of optional fields.
    enum Absence: MethodNamespace {
        #schema("absence") {
            Enum("Level") {
                Case("low")
                Case("high")
            }
            Type("Room") {
                Field("seats", .optional(.int))
                Field("name", .string, default: "hall")
            }
            Type("Desk") {
                Field("row", .int)
            }
            Error("Late", exitCode: 15) {
                Field("since", .optional(.date))
            }
            Error("Gone", exitCode: 16) {
                Field("at", .timestamp)
            }
            Union("Move") {
                Case("moved") {
                    Field("to", .optional(.string))
                }
                Case("bumped") {
                    Field("by", .int, default: 1)
                    Field("note", .optional(.string))
                }
                Case("weighed") {
                    Field("grams", .double, default: 0.5)
                    Field(5, "on", .bool, default: true)
                    Field("level", "Level", default: "high")
                    Field(
                        "pace",
                        .enumeration(cases: [.init(name: "fast"), .init(name: "slow")]),
                        default: "slow"
                    )
                    Field("label", .string, default: "none")
                    Field("count", .uint, default: 7)
                }
                Case("nested") {
                    Field("again", .optional(.reference("Move")))
                    Field("rooms", .optional(.array(.reference("Room"))))
                }
                Case("placed") {
                    Field("at", .string)
                }
                Case("mixed") {
                    Field("to", .optional(.string))
                    Field("at", .string)
                }
                Case("boxed") {
                    Field("box") {
                        Field("label", .optional(.string))
                    }
                }
                Case("kept")
            }
            Call("shift") {
                Access { .write }
                Request {
                    Field("move", "Move")
                }
                Errors {
                    Case(.reference("Late"))
                    Case(.reference("Gone"))
                    Case("busy", exitCode: 10) {
                        Field("retryAfter", .optional(.duration))
                        Field("tries", .int, default: 3)
                    }
                    Case("crowded", .reference("Room"), exitCode: 11)
                    Case("blocked", .reference("Desk"), exitCode: 12)
                    Case("pinned", exitCode: 13) {
                        Field("by", .string)
                    }
                }
            }
        }
    }

    /// One union value as a tag and the entries a newer writer may add:
    /// two maps, one without key 1 and one with an empty map there, which
    /// is what the first must read as.
    struct AbsentFieldsValue: Sendable {
        /// The map without key 1.
        var absent: ByteBuffer
        /// The same map with `{}` under key 1, or under its name.
        var empty: ByteBuffer
        var tagUnderName: Bool
        var fieldsUnderName: Bool
        var extraEntries: Int

        /// A value whose tag is drawn from `tags`.
        static func drawn(tags: Gen<String>, from tc: TestCase) throws -> Self {
            let tag = try #draw(tags, from: tc)
            let tagUnderName = try #draw(.bool(), from: tc)
            let fieldsUnderName = try #draw(.bool(), from: tc)
            let extras = try #draw(
                Gen<[(UnknownKey, [UInt8])]>.oneOf(
                    .just([]),
                    .array(of: Hegel.zip(unknownKeys, unknownValues), count: 1...3)
                ),
                from: tc
            )
            let tagPosition = try #draw(position, from: tc)
            let fieldsPosition = try #draw(position, from: tc)

            // Keys that name nothing: never 0 or 1, never "case" or "fields".
            var entries = extras.map { key, value in
                switch key {
                    case .integer(let integer):
                        MapEntry(
                            key: encodedBytes(
                                integer == 0 || integer == 1 ? -1 - integer : integer
                            ),
                            value: value
                        )
                    case .string(let string):
                        MapEntry(
                            key: encodedBytes(
                                string == "case" || string == "fields"
                                    ? string + " unknown" : string
                            ),
                            value: value
                        )
                    case .unusable(let bytes):
                        MapEntry(key: bytes, value: value)
                }
            }
            let tagEntry = MapEntry(
                key: tagUnderName ? encodedBytes("case") : encodedBytes(0),
                value: encodedBytes(tag)
            )
            entries.insert(tagEntry, at: tagPosition % (entries.count + 1))
            var withFields = entries
            withFields.insert(
                MapEntry(
                    key: fieldsUnderName ? encodedBytes("fields") : encodedBytes(1),
                    value: [0x80]
                ),
                at: fieldsPosition % (entries.count + 1)
            )
            return Self(
                absent: ByteBuffer(bytes: mapBytes(entries)),
                empty: ByteBuffer(bytes: mapBytes(withFields)),
                tagUnderName: tagUnderName,
                fieldsUnderName: fieldsUnderName,
                extraEntries: extras.count
            )
        }

        func recordShape(in tc: TestCase) throws {
            if self.tagUnderName { try tc.event("the case under its name") }
            if self.fieldsUnderName { try tc.event("the fields map under its name") }
            if self.extraEntries > 0 { try tc.event("keys naming nothing") }
        }
    }

    /// Any string but the given names.
    func undeclared(_ names: [String]) -> Gen<String> {
        Gen<String>.string().map { names.contains($0) ? $0 + " unknown" : $0 }
    }

    /// The request `{move: union}` read by the dynamic decoder, rendered as
    /// JSON; nil when it does not read.
    func dynamicallyDecoded(move union: ByteBuffer) -> String? {
        var bytes = ByteBuffer(bytes: [0x81, 0x00])
        var union = union
        bytes.writeBuffer(&union)
        guard let schema = try? Absence.shift.signature().get().request,
            let response = try? MMCLIDynamicResponse.$schema.withValue(
                (schema, Absence.types),
                operation: {
                    try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
                }
            )
        else { return nil }
        return MMCLIDynamicJSONText(response.tree, pretty: false)
    }

    @Suite("A union case without its fields map", .hegel)
    struct AbsentUnionFieldsProperties {
        /// Cases whose fields may all be absent.
        static let absentable = ["moved", "bumped", "weighed", "nested"]
        /// Cases with a required field.
        static let required = ["placed", "mixed", "boxed"]

        /// A union value without key 1 reads as the same value with an
        /// empty map there, on both of the generated code's paths and in
        /// the dynamic decoder: the case's fields absent, each optional one
        /// nil and each defaulted one its default, or, for a case with a
        /// required field, a failure naming key 1. An undeclared case keeps
        /// its tag and no fields.
        @Test
        func aMissingFieldsMapReadsAsAnEmptyOne() throws {
            try property(
                reaching: [
                    "read with every field absent", "failed: a field is required",
                    "the case under its name", "the fields map under its name",
                    "keys naming nothing",
                ],
                reachingAfter: ["a case with no fields": 1_000, "an undeclared case": 1_000]
            ) { tc in
                let names = Self.absentable + Self.required + ["kept"]
                // Two in five each for the cases with fields: at one in
                // three, either came up in as few as 20 cases in 100.
                let tags: Gen<String> = .oneOf(
                    .element(of: Self.absentable),
                    .element(of: Self.required),
                    .element(of: Self.absentable),
                    .element(of: Self.required),
                    .oneOf(.just("kept"), undeclared(names))
                )
                let value = try AbsentFieldsValue.drawn(tags: tags, from: tc)
                try value.recordShape(in: tc)

                let absent = decodedThroughGeneratedCode(Absence.Move.self, from: value.absent)
                let empty = decodedThroughGeneratedCode(Absence.Move.self, from: value.empty)
                #expect(
                    absent == decodedThroughCodable(Absence.Move.self, from: value.absent),
                    "\(hex(value.absent))"
                )
                switch (absent, empty) {
                    case (.success(.unknown(let tag, let fields)), _):
                        try tc.event("an undeclared case")
                        #expect(!names.contains(tag) && fields == nil, "\(hex(value.absent))")
                    case (.success(let read), .success(let model)):
                        try tc.event(
                            read == .kept ? "a case with no fields" : "read with every field absent"
                        )
                        #expect(read == model, "\(hex(value.absent))")
                    case (.failure(let error), .failure):
                        try tc.event("failed: a field is required")
                        #expect(error == .keyNotFound(key: "1"), "\(hex(value.absent))")
                    default:
                        Issue.record(
                            "without key 1: \(absent); with {}: \(empty); \(hex(value.absent))"
                        )
                }
                #expect(
                    dynamicallyDecoded(move: value.absent) == dynamicallyDecoded(move: value.empty),
                    "\(hex(value.absent))"
                )
            }
        }

        /// The same for a declared error: a case without key 1 reads as the
        /// same case with an empty map there, whether its fields are inline
        /// or a type's, and a case with a required field is not read.
        @Test
        func aDeclaredErrorWithoutItsFieldsReadsAsOneWithNone() throws {
            try property(
                reaching: [
                    "read with every field absent", "not read: a field is required",
                    "the case under its name", "the fields map under its name",
                    "keys naming nothing",
                ],
                reachingAfter: ["an undeclared case": 1_000]
            ) { tc in
                let absentable = ["late", "busy", "crowded"]
                let required = ["gone", "blocked", "pinned"]
                // Two in five each for the declared cases: at one in three,
                // either came up in as few as 18 cases in 100.
                let tags: Gen<String> = .oneOf(
                    .element(of: absentable),
                    .element(of: required),
                    .element(of: absentable),
                    .element(of: required),
                    undeclared(absentable + required)
                )
                let value = try AbsentFieldsValue.drawn(tags: tags, from: tc)
                try value.recordShape(in: tc)

                func declared(_ payload: ByteBuffer) -> Absence.ShiftError? {
                    MMError(code: MMError.declaredErrorCode, message: "x", payload: payload)
                        .declared(as: Absence.ShiftError.self)
                }
                let absent = declared(value.absent)
                switch absent {
                    case .unknown?: try tc.event("an undeclared case")
                    case _?: try tc.event("read with every field absent")
                    case nil: try tc.event("not read: a field is required")
                }
                #expect(absent == declared(value.empty), "\(hex(value.absent))")
            }
        }
    }

#endif

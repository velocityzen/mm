import Foundation
import MMSchema
import MMWire
import NIOCore
import Testing

/// Durations with ranges and defaults: on a field, on a nested type's
/// fields, on a named scalar, and on an optional field whose default is a
/// CLI default.
enum Timer: MethodNamespace {
    #schema("timer") {
        Alias("Timeout", .duration, constraints: .range(.seconds(1)...(.seconds(300))))
        Type("Plan") {
            Field("grace", .duration, constraints: .range(...(.seconds(10))), default: "PT2S")
            Field("timeout", .reference("Timeout"), default: "PT30S")
        }
        Call("start") {
            Access { .write }
            Request {
                Field("wait", .duration, constraints: .range(.milliseconds(500)...))
                Field("delay", .optional(.duration), default: "PT1M")
                Field("plan", .reference("Plan"))
            }
            Response {
                Field("ok", .bool)
            }
        }
    }
}

private func decodedThroughCodable<T: Decodable>(
    _ type: T.Type,
    from buffer: ByteBuffer
) -> Result<T, MMWireError> {
    MMPackDecoder().decode(type, from: buffer)
}

private func decodedThroughGeneratedCode<T: MMPackDecodable>(
    _ type: T.Type,
    from buffer: ByteBuffer
) -> Result<T, MMWireError> {
    MMPackDecoder().decode(type, from: buffer)
}

private func duration(_ value: Duration) -> MMDuration { MMDuration(value) }

@Suite("Duration ranges and defaults")
struct DurationRuleTests {
    @Test("the generated types honor the re-emitted contract")
    func contractFidelity() {
        #expect(Timer.contract.verify(against: Timer.self) == .success([]))
    }

    @Test("the contract holds duration bounds and defaults, fitted through a named scalar")
    func contract() throws {
        let plan = try #require(Timer.types.first { $0.name == "timer.Plan" })
        guard case .structure(let fields) = plan.schema else {
            Issue.record("Plan is \(plan.schema)")
            return
        }
        #expect(fields[0].type == .optional(.duration))
        #expect(
            fields[0].constraints
                == TypeSchema.Constraints(maximum: .duration(duration(.seconds(10))))
        )
        #expect(fields[0].defaultValue == .duration(duration(.seconds(2))))
        #expect(fields[1].type == .optional(.reference("timer.Timeout")))
        #expect(fields[1].defaultValue == .duration(duration(.seconds(30))))
        let timeout = try #require(Timer.types.first { $0.name == "timer.Timeout" })
        #expect(
            timeout.constraints
                == TypeSchema.Constraints(
                    minimum: .duration(duration(.seconds(1))),
                    maximum: .duration(duration(.seconds(300)))
                )
        )
        guard case .structure(let request) = try Timer.start.signature().get().request else {
            Issue.record("the request is not a structure")
            return
        }
        #expect(
            request[0].constraints
                == TypeSchema.Constraints(minimum: .duration(duration(.milliseconds(500))))
        )
        // An optional field's default is the CLI's, never the wire's.
        #expect(request[1].type == .optional(.duration))
        #expect(request[1].defaultValue == nil)
    }

    @Test("an absent key reads the duration default on both paths")
    func absentKeyReadsDefault() throws {
        let expected = Timer.Plan(
            grace: duration(.seconds(2)),
            timeout: Timer.Timeout(duration(.seconds(30)))
        )
        #expect(
            try decodedThroughGeneratedCode(Timer.Plan.self, from: mpBytes("80")).get() == expected
        )
        #expect(try decodedThroughCodable(Timer.Plan.self, from: mpBytes("80")).get() == expected)
    }

    @Test("the generated checks name a duration past its bounds")
    func generatedChecks() {
        let plan = Timer.Plan(
            grace: duration(.seconds(10)),
            timeout: Timer.Timeout(duration(.seconds(1)))
        )
        func request(wait: Duration, plan: Timer.Plan = plan) -> Timer.StartRequest {
            Timer.StartRequest(wait: duration(wait), delay: nil, plan: plan)
        }
        #expect(request(wait: .milliseconds(500)).constraintViolation(at: "") == nil)
        #expect(
            request(wait: .milliseconds(499)).constraintViolation(at: "")
                == SchemaValueError(
                    path: "wait",
                    problem: "is PT0.499S, less than the minimum PT0.5S"
                )
        )
        #expect(
            request(
                wait: .seconds(1),
                plan: Timer.Plan(
                    grace: duration(.seconds(11)),
                    timeout: Timer.Timeout(duration(.seconds(1)))
                )
            ).constraintViolation(at: "")
                == SchemaValueError(
                    path: "plan.grace",
                    problem: "is PT11S, more than the maximum PT10S"
                )
        )
        #expect(
            request(
                wait: .seconds(1),
                plan: Timer.Plan(grace: .zero, timeout: Timer.Timeout(duration(.seconds(301))))
            ).constraintViolation(at: "")
                == SchemaValueError(
                    path: "plan.timeout",
                    problem: "is PT5M1S, more than the maximum PT5M"
                )
        )
    }

    @Test("validating a value checks its durations against their bounds")
    func validatedValue() throws {
        let schema = try Timer.start.signature().get().request
        let resolver = TypeResolver(Timer.types)
        func validated(wait: String, timeout: String) -> Result<SchemaValue, SchemaValueError> {
            SchemaValue.object([
                .init("wait", .string(wait)),
                .init(
                    "plan",
                    .object([.init("grace", .string("PT1S")), .init("timeout", .string(timeout))])
                ),
            ]).validated(against: schema, resolver: resolver, checkingConstraints: true)
        }
        #expect(throws: Never.self) { try validated(wait: "PT1S", timeout: "PT1S").get() }
        #expect(
            validated(wait: "PT0.4S", timeout: "PT1S")
                == .failure(
                    SchemaValueError(
                        path: "wait",
                        problem: "is PT0.4S, less than the minimum PT0.5S"
                    )
                )
        )
        #expect(
            validated(wait: "PT1S", timeout: "PT0.999S")
                == .failure(
                    SchemaValueError(
                        path: "plan.timeout",
                        problem: "is PT0.999S, less than the minimum PT1S"
                    )
                )
        )
    }

    @Test("a duration bound is a bin of the duration's binary form, and JSON text")
    func boundOnTheWire() throws {
        let constraints = TypeSchema.Constraints(
            minimum: .duration(duration(.milliseconds(-500))),
            maximum: .duration(duration(.seconds(300)))
        )
        let packed = try MMPackEncoder().encode(constraints).get()
        // {0: bin 9001f4, 1: bin 02012c}: -0.5 s is 500 ms, negative; 300 s
        // is two bytes of seconds.
        #expect(mpHex(packed) == "82" + "00c4039001f4" + "01c40302012c")
        #expect(
            try MMPackDecoder().decode(TypeSchema.Constraints.self, from: packed).get()
                == constraints
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(constraints)
        #expect(String(decoding: json, as: UTF8.self) == #"{"maximum":"PT5M","minimum":"-PT0.5S"}"#)
        #expect(try JSONDecoder().decode(TypeSchema.Constraints.self, from: json) == constraints)
    }

    /// A bound as a peer from before duration bounds reads it: an integer,
    /// else a finite floating number, else a failure.
    struct OlderBound: Decodable, Equatable {
        var value: Double

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let integer = try? container.decode(Int64.self) {
                self.value = Double(integer)
            } else {
                self.value = try container.decode(Double.self)
            }
        }
    }

    /// Constraints as a peer from before duration bounds reads them: a
    /// bound it cannot read is absent.
    struct OlderConstraints: Decodable, Equatable {
        var minimum: OlderBound?
        var maximum: OlderBound?

        enum CodingKeys: Int, CodingKey {
            case minimum = 0
            case maximum = 1
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.minimum =
                (try? container.decodeIfPresent(OlderBound.self, forKey: .minimum)) ?? nil
            self.maximum =
                (try? container.decodeIfPresent(OlderBound.self, forKey: .maximum)) ?? nil
        }
    }

    @Test("an older peer skips a duration bound it cannot read")
    func olderPeerSkipsTheBound() throws {
        let packed = try MMPackEncoder().encode(
            TypeSchema.Constraints(minimum: .duration(duration(.seconds(1))))
        ).get()
        let older = try MMPackDecoder().decode(OlderConstraints.self, from: packed).get()
        #expect(older.minimum == nil)
        #expect(older.maximum == nil)
    }

    @Test("a duration default travels as its canonical text, and its field's kind reads it back")
    func defaultOnTheWire() throws {
        let field = TypeSchema.Field(
            key: 0,
            name: "t",
            type: .optional(.duration),
            defaultValue: .duration(duration(.seconds(90)))
        )
        let packed = try MMPackEncoder().encode(field).get()
        // The default is a fixstr of the canonical text: a7 "PT1M30S".
        #expect(mpHex(packed).hasSuffix("a7" + "50543" + "14d333053"))
        #expect(try MMPackDecoder().decode(TypeSchema.Field.self, from: packed).get() == field)
        let json = try JSONEncoder().encode(field)
        #expect(String(decoding: json, as: UTF8.self).contains(#""PT1M30S""#))
        #expect(try JSONDecoder().decode(TypeSchema.Field.self, from: json) == field)
        // A field of a named type cannot see the kind: the text stays text.
        let named = TypeSchema.Field(
            key: 0,
            name: "t",
            type: .optional(.reference("a.T")),
            defaultValue: .duration(duration(.seconds(90)))
        )
        let packedNamed = try MMPackEncoder().encode(named).get()
        #expect(
            try MMPackDecoder().decode(TypeSchema.Field.self, from: packedNamed).get().defaultValue
                == .string("PT1M30S")
        )
    }

    @Test(
        "discovery reads a named duration's default back as a duration, on MessagePack and in JSON"
    )
    func discovery() throws {
        let signature = try Timer.start.signature().get()
        let response = SchemaResponse(
            fingerprint: SchemaFingerprint.compute([signature], types: Timer.types),
            methods: [signature],
            types: Timer.types
        )
        let packed = try MMPackEncoder().encode(response).get()
        #expect(try MMPackDecoder().decode(SchemaResponse.self, from: packed).get() == response)
        #expect(
            try JSONDecoder().decode(SchemaResponse.self, from: JSONEncoder().encode(response))
                == response
        )
    }

    @Test("duration bounds and defaults are hashed apart from numbers and strings")
    func fingerprintKinds() {
        func signature(_ field: TypeSchema.Field) -> MethodSignature {
            MethodSignature(
                name: "a.put",
                access: .write,
                request: .structure(fields: [field]),
                response: .structure(fields: [])
            )
        }
        let durationDefault = SchemaFingerprint.compute([
            signature(
                .init(
                    key: 0,
                    name: "t",
                    type: .optional(.duration),
                    defaultValue: .duration(duration(.seconds(1)))
                )
            )
        ])
        let textDefault = SchemaFingerprint.compute([
            signature(
                .init(key: 0, name: "t", type: .optional(.duration), defaultValue: .string("PT1S"))
            )
        ])
        let durationBound = SchemaFingerprint.compute([
            signature(
                .init(
                    key: 0,
                    name: "t",
                    type: .duration,
                    constraints: TypeSchema.Constraints(minimum: .duration(duration(.seconds(1))))
                )
            )
        ])
        let otherDurationBound = SchemaFingerprint.compute([
            signature(
                .init(
                    key: 0,
                    name: "t",
                    type: .duration,
                    constraints: TypeSchema.Constraints(
                        minimum: .duration(duration(.nanoseconds(1)))
                    )
                )
            )
        ])
        let integerBound = SchemaFingerprint.compute([
            signature(
                .init(
                    key: 0,
                    name: "t",
                    type: .duration,
                    constraints: TypeSchema.Constraints(minimum: .integer(1))
                )
            )
        ])
        #expect(
            Set([durationDefault, textDefault, durationBound, otherDurationBound, integerBound])
                .count == 5
        )
    }

    @Test("the duration set of the wire spec's conformance vectors")
    func conformanceVector() {
        let signature = MethodSignature(
            name: "timer.start",
            access: .write,
            request: .structure(fields: [
                .init(
                    key: 0,
                    name: "wait",
                    type: .duration,
                    constraints: TypeSchema.Constraints(
                        minimum: .duration(duration(.milliseconds(500)))
                    )
                ),
                .init(
                    key: 1,
                    name: "grace",
                    type: .optional(.duration),
                    constraints: TypeSchema.Constraints(maximum: .duration(duration(.seconds(10)))),
                    defaultValue: .duration(duration(.seconds(2)))
                ),
                .init(
                    key: 2,
                    name: "timeout",
                    type: .optional(.reference("timer.Timeout")),
                    defaultValue: .duration(duration(.seconds(30)))
                ),
            ]),
            response: .structure(fields: [.init(key: 0, name: "ok", type: .bool)])
        )
        let timeout = TypeDefinition(
            name: "timer.Timeout",
            schema: .duration,
            constraints: TypeSchema.Constraints(
                minimum: .duration(duration(.seconds(1))),
                maximum: .duration(duration(.seconds(300)))
            )
        )
        #expect(SchemaFingerprint.compute([signature], types: [timeout]) == 0x1618_eeb2_4390_93fd)
    }
}

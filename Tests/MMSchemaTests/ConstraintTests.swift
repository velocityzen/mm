import Foundation
import Testing

@testable import MMSchema

/// A `#schema` with constraints and named scalars, compiled into this test
/// target: constraints on fields of every kind that takes them, on nested
/// blocks' fields, on union cases' fields and on a request stream's
/// element, and named scalars with and without constraints.
private enum Shelf: MethodNamespace {
    #schema("shelf") {
        Alias(
            "Slug", .string, constraints: .length(1...8), .pattern("[a-z0-9-]+"),
            description: "A short lowercase name")
        Alias("Percent", .double, constraints: .range(0...100))
        Alias("Count", .uint)
        Type("Line") {
            Field("text", .string, constraints: .nonEmpty)
            Field("tags", .array(.string), constraints: .length(...3))
        }
        Union("Event") {
            Case("note") {
                Field("line", .reference("Line"))
            }
            Case("scored") {
                Field("score", .int, constraints: .range(-5...5))
                Field("by", .optional(.reference("Slug")))
            }
            Case("cleared")
        }
        Call("put") {
            Access { .write }
            Request {
                Field("slug", .reference("Slug"))
                Field("limit", .optional(.int), constraints: .range(1...1000))
                Field("ratio", .float, constraints: .range(0.0...1.0))
                Field("lines", .array(.reference("Line")))
                Field("shares", .map(key: .string, value: .reference("Percent")))
                Field("event", .reference("Event"))
                Field("owner") {
                    Field("name", .string, constraints: .length(1...))
                }
            }
            Response {
                Field("count", .reference("Count"))
            }
        }
        Call("fill") {
            Access { .write }
            RequestStream {
                Field("text", .string, constraints: .nonEmpty)
            }
            Response {
                Field("filled", .uint)
            }
        }
        Call("look") {
            Access { .read }
            Request {
                Field("slug", .string)
            }
            Response {
                Field("found", .bool)
            }
        }
    }
}

/// A request that keeps every constraint.
private func validPut() -> Shelf.PutRequest {
    Shelf.PutRequest(
        slug: "box-1",
        limit: 10,
        ratio: 0.5,
        lines: [Shelf.Line(text: "a", tags: ["x"]), Shelf.Line(text: "b", tags: [])],
        shares: ["a": 10, "b": 100],
        event: .scored(score: 5, by: "ann"),
        owner: Shelf.PutRequest.Owner(name: "ann")
    )
}

@Suite("Constraints and named scalars")
struct ConstraintTests {
    @Test("the generated types honor the re-emitted contract (macro fidelity)")
    func contractFidelity() throws {
        let breaks = try Shelf.contract.verify(against: Shelf.self).get()
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
        #expect(Shelf.types == Shelf.contract.types)
    }

    @Test("constraints reach the signature, and named scalars the type table")
    func discovery() throws {
        let put = try Shelf.put.signature().get()
        guard case .structure(let fields) = put.request else {
            Issue.record("the request is not a structure: \(put.request)")
            return
        }
        let constraints = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.constraints) })
        #expect(
            constraints["limit"]
                == .some(TypeSchema.Constraints(minimum: .integer(1), maximum: .integer(1000))))
        #expect(
            constraints["ratio"]
                == .some(TypeSchema.Constraints(minimum: .floating(0), maximum: .floating(1))))
        #expect(constraints["slug"] == .some(nil))
        let slug = Shelf.contract.types.first { $0.name == "shelf.Slug" }
        #expect(
            slug
                == TypeDefinition(
                    name: "shelf.Slug",
                    schema: .string,
                    description: "A short lowercase name",
                    constraints: TypeSchema.Constraints(
                        minimumLength: 1, maximumLength: 8, pattern: "[a-z0-9-]+")
                ))
        // Integer bounds on a double become floating ones.
        let percent = Shelf.contract.types.first { $0.name == "shelf.Percent" }
        #expect(
            percent?.constraints
                == TypeSchema.Constraints(minimum: .floating(0), maximum: .floating(100)))
        let count = Shelf.contract.types.first { $0.name == "shelf.Count" }
        #expect(count == TypeDefinition(name: "shelf.Count", schema: .uint))
    }

    @Test("a call carries a check exactly for the parts the client sends that hold a constraint")
    func descriptorChecks() {
        #expect(Shelf.put.requestCheck != nil)
        #expect(Shelf.fill.requestCheck == nil)
        #expect(Shelf.fill.elementCheck != nil)
        #expect(Shelf.look.requestCheck == nil)
    }

    @Test("the client checks before sending in debug builds of the declaring module only")
    func checksBeforeSendingInDebug() {
        #if DEBUG
            #expect(Shelf.checksConstraintsBeforeSending)
        #else
            #expect(!Shelf.checksConstraintsBeforeSending)
        #endif
        #expect(Shelf.put.requestCheck?.beforeSending == Shelf.checksConstraintsBeforeSending)
    }

    @Test("a request that keeps every constraint has no violation")
    func validRequest() {
        #expect(validPut().constraintViolation(at: "") == nil)
        #expect(Shelf.put.requestCheck?.violation(of: validPut()) == nil)
    }

    @Test("the first violation names the value's path and the rule it broke")
    func violation() {
        let cases: [(breaking: (inout Shelf.PutRequest) -> Void, path: String, problem: String)] = [
            (
                { request in request.slug = "" },
                "slug", "has length 0, less than the minimum length 1"
            ),
            (
                { request in request.slug = "Box" },
                "slug", "does not match the pattern [a-z0-9-]+"
            ),
            (
                { request in request.limit = 0 },
                "limit", "is 0, less than the minimum 1"
            ),
            (
                { request in request.ratio = 1.5 },
                "ratio", "is 1.5, more than the maximum 1.0"
            ),
            (
                { request in request.lines[1].text = "" },
                "lines[1].text", "has length 0, less than the minimum length 1"
            ),
            (
                { request in request.lines[0].tags = ["a", "b", "c", "d"] },
                "lines[0].tags", "has length 4, more than the maximum length 3"
            ),
            (
                // Of the entries that break a constraint, the one whose key
                // sorts first.
                { request in request.shares = ["z": 101, "m": -1, "a": 1] },
                "shares.m", "is -1.0, less than the minimum 0.0"
            ),
            (
                { request in request.event = .scored(score: 6, by: nil) },
                "event.fields.score", "is 6, more than the maximum 5"
            ),
            (
                { request in request.event = .scored(score: 0, by: "") },
                "event.fields.by", "has length 0, less than the minimum length 1"
            ),
            (
                { request in request.event = .note(line: Shelf.Line(text: "", tags: [])) },
                "event.fields.line.text", "has length 0, less than the minimum length 1"
            ),
            (
                { request in request.owner.name = "" },
                "owner.name", "has length 0, less than the minimum length 1"
            ),
            (
                // Fields are checked in declaration order.
                { request in
                    request.owner.name = ""
                    request.limit = 2000
                },
                "limit", "is 2000, more than the maximum 1000"
            ),
        ]
        for (index, (breaking, path, problem)) in cases.enumerated() {
            var request = validPut()
            breaking(&request)
            let expected = SchemaValueError(path: path, problem: problem)
            #expect(request.constraintViolation(at: "") == expected, "case \(index)")
            #expect(Shelf.put.requestCheck?.violation(of: request) == expected, "case \(index)")
        }
    }

    @Test("the generated checks name what validating the value against the contract names")
    func generatedChecksMatchTheContract() throws {
        var request = validPut()
        request.lines[1].text = ""
        let value: SchemaValue = .object([
            .init("slug", .string(request.slug.rawValue)),
            .init("limit", .int(Int64(request.limit ?? 0))),
            .init("ratio", .double(Double(request.ratio))),
            .init(
                "lines",
                .array(
                    request.lines.map { line in
                        .object([
                            .init("text", .string(line.text)),
                            .init("tags", .array(line.tags.map { .string($0) })),
                        ])
                    })),
            .init("shares", .object([.init("a", .double(10)), .init("b", .double(100))])),
            .init(
                "event",
                .object([
                    .init("case", .string("scored")),
                    .init("fields", .object([.init("score", .int(5)), .init("by", .string("ann"))])),
                ])),
            .init("owner", .object([.init("name", .string("ann"))])),
        ])
        let schema = try Shelf.put.signature().get().request
        let validated = value.validated(
            against: schema, resolver: TypeResolver(Shelf.types), checkingConstraints: true)
        #expect(validated.failure == request.constraintViolation(at: ""))
        #expect(validated.failure == SchemaValueError(path: "lines[1].text", problem: "has length 0, less than the minimum length 1"))
    }

    @Test("a stream element's check names the path inside the element")
    func elementCheck() {
        let check = Shelf.fill.elementCheck
        #expect(check?.violation(of: Shelf.FillRequestItem(text: "x")) == nil)
        #expect(
            check?.violation(of: Shelf.FillRequestItem(text: ""))
                == SchemaValueError(path: "text", problem: "has length 0, less than the minimum length 1"))
    }

    @Test("a named scalar is coded as its bare scalar and described as its reference")
    func aliasCoding() throws {
        let slug: Shelf.Slug = "box-1"
        #expect(slug.rawValue == "box-1")
        #expect(Shelf.Slug.schema == .reference("shelf.Slug"))
        let json = try JSONEncoder().encode(slug)
        #expect(String(decoding: json, as: UTF8.self) == #""box-1""#)
        #expect(try JSONDecoder().decode(Shelf.Slug.self, from: json) == slug)
        let percent: Shelf.Percent = 12
        #expect(percent.rawValue == 12.0)
        #expect(try JSONEncoder().encode(percent) == JSONEncoder().encode(12.0))
        #expect(Shelf.Count(rawValue: 3).constraintViolation(at: "count") == nil)
    }

    @Test("a named scalar checks its own constraints under the path it is given")
    func aliasCheck() {
        #expect(Shelf.Slug("ok").constraintViolation(at: "x") == nil)
        #expect(
            Shelf.Slug("way-too-long").constraintViolation(at: "x")
                == SchemaValueError(path: "x", problem: "has length 12, more than the maximum length 8"))
        #expect(
            Shelf.Percent(-0.5).constraintViolation(at: "")
                == SchemaValueError(path: "", problem: "is -0.5, less than the minimum 0.0"))
        #expect(
            Shelf.Percent(.nan).constraintViolation(at: "p")
                == SchemaValueError(path: "p", problem: "is not a number, outside every range"))
    }

    @Test("the runtime DSL declares what the macro generates")
    func runtimeDeclaration() {
        let declaration = Schema("shelf") {
            Alias("Slug", .string, constraints: .length(1...8), .pattern("[a-z0-9-]+"))
            Call("look") {
                Access { .read }
                Request {
                    Field("slug", "Slug")
                    Field("limit", .int, constraints: .range(1...))
                    Field("tags", .array(.string), constraints: .nonEmpty)
                }
            }
        }
        #expect(
            declaration.types == [
                TypeDefinition(
                    name: "shelf.Slug", schema: .string,
                    constraints: TypeSchema.Constraints(
                        minimumLength: 1, maximumLength: 8, pattern: "[a-z0-9-]+"))
            ])
        guard case .structure(let fields) = declaration.signatures.first?.request else {
            Issue.record("no request structure")
            return
        }
        #expect(fields.map(\.constraints) == [
            nil,
            TypeSchema.Constraints(minimum: .integer(1)),
            TypeSchema.Constraints(minimumLength: 1),
        ])
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}

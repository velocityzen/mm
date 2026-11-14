// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import ArgumentParser
    import Foundation
    import HegelTesting
    import Synchronization
    import Testing

    @testable import MMCLI

    @Suite("JSON syntax properties", .hegel, .offTheCooperativePool)
    struct JSONSyntaxProperties {
        /// `JSONSyntaxError` finds no error in exactly the text `JSONDecoder`
        /// decodes all the way down, but for nesting past the cap, which
        /// `JSONDecoder` allows up to 512. Text that is JSON throughout and
        /// still does not decode holds a number too large for a double:
        /// replacing those with 0 makes it decode.
        ///
        /// A NUL among the first four bytes makes `JSONDecoder` read the
        /// text as UTF-16 or UTF-32, so it may decode text the locator
        /// refuses; there only the refusal is checked. `--params` comes from
        /// argv, which cannot carry a NUL.
        ///
        /// Mutation check: refusing a trailing comma, accepting a lone low
        /// surrogate, or pairing a high surrogate with any `\u` escape fails
        /// here.
        @Test
        func locatorAgreesWithJSONDecoder() throws {
            try property(
                reaching: ["refused by both"],
                reachingAfter: [
                    "decoded": 1_000, "nested past the cap, which JSONDecoder allows": 1_000,
                    "expected a value": 1_000, "an unpaired high surrogate": 1_000,
                    "an unpaired low surrogate": 1_000, "a control character in a string": 10_000,
                    "a leading zero": 10_000, "an invalid escape": 10_000,
                    "expected a digit": 1_000,
                    "expected a hexadecimal digit in a '\\u' escape": 1_000,
                    "refused for a number too large for a double": 10_000,
                ]
            ) { tc in
                let text = try #draw(NearJSON.texts, from: tc)
                let error = JSONSyntaxError.first(in: text)
                try recordReach(of: error, in: tc)
                if error?.problem == .tooDeep {
                    try tc.event("nested past the cap, which JSONDecoder allows")
                    return
                }
                let decodes = decodesThroughout(text)
                switch (error, decodes) {
                    case (nil, true):
                        try tc.event("decoded")
                    case (.some, false):
                        try tc.event("refused by both")
                    case (let error?, true):
                        if text.utf8.prefix(4).contains(0) {
                            try tc.event("decoded with a NUL in the first four bytes")
                        } else {
                            Issue.record("JSONDecoder decodes text the locator refuses: \(error)")
                        }
                    case (nil, false):
                        try tc.event("refused for a number too large for a double")
                        let tamed = replacingNumbersTooLargeForADouble(in: text)
                        #expect(
                            decodesThroughout(tamed),
                            "still refused with its numbers too large for a double 0: \(tamed.debugDescription)"
                        )
                }
            }
        }

        /// `parse` refuses text with the locator's error, in its words, and
        /// text the locator accepts only for a number too large for a double.
        ///
        /// Mutation check: asking the locator only once `JSONDecoder` has
        /// failed, which lets nesting past the cap through, fails here.
        @Test
        func parseRefusesWithTheLocatorsError() throws {
            try property(
                reaching: ["refused with the locator's error"],
                reachingAfter: [
                    "parsed": 1_000, "nested too deep": 1_000,
                    "refused for a number too large for a double": 10_000,
                ]
            ) { tc in
                let text = try #draw(NearJSON.texts, from: tc)
                let error = JSONSyntaxError.first(in: text)
                try recordReach(of: error, in: tc)
                do {
                    _ = try MMCLIDynamicTree.parse(jsonText: text)
                    try tc.event("parsed")
                    #expect(
                        error == nil,
                        "parsed text the locator refuses: \(error.map(\.description) ?? "")"
                    )
                } catch let refusal as ValidationError {
                    if let error {
                        try tc.event("refused with the locator's error")
                        #expect(refusal.message == error.description)
                    } else {
                        try tc.event("refused for a number too large for a double")
                        #expect(
                            refusal.message.hasSuffix("is too large for a double."),
                            "\(refusal.message)"
                        )
                    }
                }
            }
        }

        /// Arrays and objects nest at most `JSONSyntaxError.maximumDepth`
        /// deep. With brackets counted apart from the locator, text with a
        /// bracket past the cap is refused at that bracket, or at an error
        /// before it, and text with none is never refused for nesting.
        ///
        /// Mutation check: letting arrays and objects nest one level past the
        /// cap fails here.
        @Test
        func nestingPastTheCapIsRefused() throws {
            try property(
                reaching: ["a bracket past the cap"],
                reachingAfter: [
                    "nested too deep": 1_000, "JSON nested exactly to the cap": 1_000,
                    "an error before the cap": 1_000,
                ]
            ) { tc in
                let text = try #draw(NearJSON.texts, from: tc)
                let error = JSONSyntaxError.first(in: text)
                try recordReach(of: error, in: tc)
                let nesting = bracketNesting(in: text)
                guard let pastTheCap = nesting.firstPastTheCap else {
                    if error == nil && nesting.deepest == JSONSyntaxError.maximumDepth {
                        try tc.event("JSON nested exactly to the cap")
                    }
                    #expect(error?.problem != .tooDeep, "\(error.map(\.description) ?? "")")
                    return
                }
                try tc.event("a bracket past the cap")
                guard let error else {
                    Issue.record("accepted with a bracket past the cap at offset \(pastTheCap)")
                    return
                }
                if error.problem == .tooDeep {
                    #expect(error.offset == pastTheCap)
                } else {
                    try tc.event("an error before the cap")
                    #expect(error.offset <= pastTheCap, "\(error)")
                }
            }
        }

        /// An error's position is a scalar boundary in the text, or its end,
        /// at the line and column counted over the scalars before it. The
        /// scalar there is the one the problem names: the scalar found, the
        /// control character, the opening quote, the escape's backslash, the
        /// zero, or the bracket.
        ///
        /// Mutation check: counting columns in bytes, not ending a line at a
        /// lone CR, or placing an unterminated string at the end of the text
        /// fails here.
        @Test
        func errorsSayWhereTheyAre() throws {
            try property(
                reaching: ["an error on a line after the first"],
                reachingAfter: [
                    "found something else": 1_000, "found the end of the text": 1_000,
                    "nested too deep": 1_000, "an unpaired high surrogate": 1_000,
                    "an unpaired low surrogate": 1_000, "an unterminated string": 10_000,
                    "an invalid escape": 10_000, "a control character in a string": 10_000,
                    "a leading zero": 10_000,
                ]
            ) { tc in
                let text = try #draw(NearJSON.texts, from: tc)
                let error = JSONSyntaxError.first(in: text)
                try recordReach(of: error, in: tc)
                guard let error else { return }
                let bytes = Array(text.utf8)
                guard (0...bytes.count).contains(error.offset),
                    error.offset == bytes.count || bytes[error.offset] & 0xC0 != 0x80
                else {
                    Issue.record(
                        "offset \(error.offset) is not a scalar boundary in \(bytes.count) bytes"
                    )
                    return
                }
                let scalars = Array(text.unicodeScalars)
                let position = String(decoding: bytes[..<error.offset], as: UTF8.self)
                    .unicodeScalars.count
                var line = 1
                var column = 1
                for index in 0..<position {
                    let isLineEnd =
                        scalars[index] == "\n"
                        || (scalars[index] == "\r"
                            && (index + 1 == scalars.count || scalars[index + 1] != "\n"))
                    if isLineEnd {
                        line += 1
                        column = 1
                    } else {
                        column += 1
                    }
                }
                if line > 1 { try tc.event("an error on a line after the first") }
                #expect(error.line == line)
                #expect(error.column == column)
                #expect(error.description.hasSuffix(" at line \(line), column \(column)."))
                let here = position < scalars.count ? scalars[position] : nil
                let next = position + 1 < scalars.count ? scalars[position + 1] : nil
                switch error.problem {
                    case .unexpected(_, let found):
                        #expect(found == here)
                    case .unterminatedString:
                        #expect(here == "\"")
                    case .invalidEscape(let escaped):
                        #expect(here == "\\" && next == escaped)
                    case .unpairedHighSurrogate, .unpairedLowSurrogate:
                        #expect(here == "\\" && next == "u")
                    case .controlCharacter(let control):
                        #expect(here == control && control.value < 0x20)
                    case .leadingZero:
                        #expect(here == "0")
                    case .tooDeep:
                        #expect(here == "[" || here == "{")
                }
            }
        }

        /// The error is the first: the text before its position has no error
        /// but one of ending too soon. An error that is not about the end of
        /// the text stays the same whatever text follows it.
        @Test
        func theErrorIsTheFirst() throws {
            try property(
                reaching: [
                    "an error more text cannot mend",
                    "the text before the error only ends too soon",
                ],
                reachingAfter: [
                    "the text before the error is JSON": 1_000
                ]
            ) { tc in
                let text = try #draw(NearJSON.texts, from: tc)
                let error = JSONSyntaxError.first(in: text)
                try recordReach(of: error, in: tc)
                guard let error else { return }
                let before = String(decoding: Array(text.utf8)[..<error.offset], as: UTF8.self)
                if let earlier = JSONSyntaxError.first(in: before) {
                    try tc.event("the text before the error only ends too soon")
                    #expect(
                        earlier.problem.isEndOfText,
                        "\(error) has \(earlier) before it"
                    )
                } else {
                    try tc.event("the text before the error is JSON")
                }
                guard !error.problem.isEndOfText else { return }
                try tc.event("an error more text cannot mend")
                let more = try #draw(NearJSON.texts, from: tc)
                #expect(JSONSyntaxError.first(in: text + more) == error)
            }
        }
    }

    /// Records which problem a text has, and what it expected, for reach
    /// claims.
    private func recordReach(of error: JSONSyntaxError?, in tc: TestCase) throws {
        guard let error else {
            try tc.event("JSON throughout")
            return
        }
        switch error.problem {
            case .unexpected(let expected, let found):
                try tc.event("expected \(expected)")
                try tc.event(found == nil ? "found the end of the text" : "found something else")
            case .unterminatedString:
                try tc.event("an unterminated string")
            case .invalidEscape:
                try tc.event("an invalid escape")
            case .unpairedHighSurrogate:
                try tc.event("an unpaired high surrogate")
            case .unpairedLowSurrogate:
                try tc.event("an unpaired low surrogate")
            case .controlCharacter:
                try tc.event("a control character in a string")
            case .leadingZero:
                try tc.event("a leading zero")
            case .tooDeep:
                try tc.event("nested too deep")
        }
    }

    /// Whether `JSONDecoder` decodes `text` all the way down, as `parse`
    /// decodes a `JSONTree`: every value, which is where it checks a string's
    /// escapes and a number's digits. Each key is made distinct, since
    /// `JSONDecoder` keeps the first of equal keys and never decodes the
    /// values of the others.
    private func decodesThroughout(_ text: String) -> Bool {
        let decoder = JSONDecoder()
        let keys = KeyCounter()
        decoder.keyDecodingStrategy = .custom { path in
            MemberKey(stringValue: "\(keys.next()) \(path.last?.stringValue ?? "")")
        }
        return (try? decoder.decode(EveryValue.self, from: Data(text.utf8))) != nil
    }

    /// Counts the keys `JSONDecoder` reads, to make each one distinct.
    private final class KeyCounter: Sendable {
        private let count = Mutex(0)

        func next() -> Int {
            count.withLock { count in
                count += 1
                return count
            }
        }
    }

    private struct MemberKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// A JSON value decoded all the way down, kept nowhere.
    private struct EveryValue: Decodable {
        init(from decoder: any Decoder) throws {
            if let object = try? decoder.container(keyedBy: MemberKey.self) {
                for key in object.allKeys {
                    _ = try object.decode(EveryValue.self, forKey: key)
                }
            } else if var items = try? decoder.unkeyedContainer() {
                while !items.isAtEnd {
                    _ = try items.decode(EveryValue.self)
                }
            } else {
                let value = try decoder.singleValueContainer()
                if value.decodeNil() || (try? value.decode(Bool.self)) != nil
                    || (try? value.decode(String.self)) != nil
                {
                    return
                }
                _ = try value.decode(Double.self)
            }
        }
    }

    /// How deeply the brackets outside strings nest, up to the cap, and the
    /// UTF-8 offset of the first `[` or `{` that opens a level past
    /// `JSONSyntaxError.maximumDepth`, or nil where none does. Every bracket
    /// outside a string counts, so this is where the nesting goes past the
    /// cap wherever the text is JSON up to there.
    private func bracketNesting(in text: String) -> (deepest: Int, firstPastTheCap: Int?) {
        var deepest = 0
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, byte) in text.utf8.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                    if depth > JSONSyntaxError.maximumDepth { return (deepest, offset) }
                    deepest = max(deepest, depth)
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                default:
                    break
            }
        }
        return (deepest, nil)
    }

    /// `text` with each run of number characters that is a JSON number too
    /// large for a double replaced by 0. Runs inside strings are replaced
    /// too, which leaves those strings strings.
    private func replacingNumbersTooLargeForADouble(in text: String) -> String {
        let numberCharacters = Set("0123456789+-.eE".unicodeScalars)
        var result = String.UnicodeScalarView()
        var run = String.UnicodeScalarView()
        func flush() {
            let token = String(run)
            // JSON's number grammar, from RFC 8259.
            if token.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil,
                Double(token)?.isInfinite == true
            {
                result.append("0")
            } else {
                result.append(contentsOf: run)
            }
            run = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if numberCharacters.contains(scalar) {
                run.append(scalar)
            } else {
                flush()
                result.append(scalar)
            }
        }
        flush()
        return String(result)
    }

    /// Text near JSON, for checking `JSONSyntaxError` against `JSONDecoder`.
    ///
    /// Most texts are JSON documents built from every kind of value, with
    /// what `JSONDecoder` allows beyond RFC 8259 (trailing commas, a byte
    /// order mark), with nesting on either side of the cap, and with drawn
    /// whitespace between tokens. Then a few edits at drawn places (a scalar inserted,
    /// replaced or removed, or the text cut short) make many of them not
    /// JSON, in every way the locator reports. The rest is any text at all.
    enum NearJSON {
        /// Whitespace between tokens: none most often, each JSON whitespace
        /// character, a CRLF, and a run.
        static let whitespace = Gen<String>.element(
            of: ["", "", "", " ", "\n", "\t", "\r", "\r\n", " \n  "]
        )

        /// Number tokens: any integer, any double as Swift writes it (`inf`
        /// and `nan` included, which are not JSON), and the grammar's edges
        /// and numbers too large for a double.
        static let numbers = Gen<String>.oneOf(
            Gen<Int64>.integer().map { "\($0)" },
            Gen<UInt64>.integer().map { "\($0)" },
            Gen<Double>.double().map { "\($0)" },
            .element(of: [
                "0", "-0", "0.0", "-0.0e-0", "1e5", "1E+05", "0.5e-3", "5e-324",
                "1.7976931348623157e308", "1e309", "-1e400", "2e308", "-1E999", "1e+400",
                "123456789012345678901234567890",
            ])
        )

        /// One piece of a string's content: any text, escaped where JSON
        /// needs it; a short escape; or a `\u` escape of any UTF-16 unit
        /// (a surrogate alone included) or of a surrogate pair, in either
        /// case.
        static let stringPieces = Gen<String>.oneOf(
            Gen<String>.string(count: 0...4).map(escaped),
            .element(of: ["\\\"", "\\\\", "\\/", "\\b", "\\f", "\\n", "\\r", "\\t"]),
            Gen { tc in
                let unit = try tc.draw(
                    Gen<UInt16>.oneOf(
                        .integer(),
                        .integer(in: 0xD800...0xDFFF),
                        .element(of: [0, 0x1F, 0x7F, 0xFFFF])
                    )
                )
                return unicodeEscape(unit, uppercase: try tc.draw(Gen<Bool>.bool()))
            },
            Gen { tc in
                let value = try tc.draw(Gen<UInt32>.integer(in: 0x10000...0x10FFFF))
                let uppercase = try tc.draw(Gen<Bool>.bool())
                let scalar = Unicode.Scalar(value) ?? "\u{10000}"
                return String(scalar).utf16.map { unicodeEscape($0, uppercase: uppercase) }
                    .joined()
            }
        )

        static let strings = Gen<[String]>.array(of: stringPieces, count: 0...5)
            .map { "\"" + $0.joined() + "\"" }

        /// Leaves that look like JSON and are not: numbers with a leading
        /// zero, a missing digit or a sign or form JSON lacks, and strings
        /// with an invalid escape, a short `\u` escape, a control character
        /// unescaped or no closing quote. `JSONDecoder` checks many of these
        /// only when it decodes them.
        static let flawedLeaves = Gen<String>.element(of: [
            "01", "-00", "1.", "-", "1e", "1.e5", ".5", "+1", "0x1F", "Infinity", "NaN",
            #""\q""#, #""\x41""#, #""\U0041""#, #""\'""#, #""\u12""#, "\"\u{0}\"", "\"a\nb\"",
            "\"\u{1F}\"", "\"ab",
        ])

        /// A literal, a number or a string, and one leaf in twenty flawed.
        static let leaves = Gen<String> { tc in
            if try tc.draw(Gen<Bool>.bool(probability: 0.05)) {
                return try tc.draw(flawedLeaves)
            }
            return try tc.draw(
                Gen<String>.oneOf(.element(of: ["true", "false", "null"]), numbers, strings)
            )
        }

        /// Arrays and objects of any depth, some empty, some with a trailing
        /// comma, with whitespace between their tokens.
        static let values = Gen<String>.recursive(maxDepth: 5, maxLeaves: 24, leaf: leaves) {
            subtree in
            Gen { tc in
                let isArray = try tc.draw(Gen<Bool>.bool())
                let count = try tc.draw(Gen<Int>.int(in: 0...4))
                var text = isArray ? "[" : "{"
                for index in 0..<count {
                    text += try tc.draw(whitespace)
                    if index > 0 {
                        text += "," + (try tc.draw(whitespace))
                    }
                    if !isArray {
                        text += try tc.draw(strings) + (try tc.draw(whitespace)) + ":"
                        text += try tc.draw(whitespace)
                    }
                    text += try tc.draw(subtree)
                }
                if count > 0, try tc.draw(Gen<Bool>.bool(probability: 0.2)) {
                    text += (try tc.draw(whitespace)) + ","
                }
                return text + (try tc.draw(whitespace)) + (isArray ? "]" : "}")
            }
        }

        /// A document: a value, sometimes inside about 128 arrays or objects
        /// so the whole nests on either side of the cap, with whitespace
        /// around it and sometimes a byte order mark before it.
        static let documents = Gen<String> { tc in
            var value = try tc.draw(values)
            let cap = JSONSyntaxError.maximumDepth
            let depth = try tc.draw(
                Gen<Int>.element(of: [0, 0, 0, cap - 1, cap, cap + 1])
            )
            if try tc.draw(Gen<Bool>.bool()) {
                value =
                    String(repeating: "[", count: depth) + value
                    + String(repeating: "]", count: depth)
            } else {
                value =
                    String(repeating: "{\"\":", count: depth) + value
                    + String(repeating: "}", count: depth)
            }
            let byteOrderMark = try tc.draw(Gen<Bool>.bool(probability: 0.1)) ? "\u{FEFF}" : ""
            return byteOrderMark + (try tc.draw(whitespace)) + value + (try tc.draw(whitespace))
        }

        /// What an edit inserts or writes over: what JSON is made of and what
        /// it refuses (control characters, a NUL, invisible and combining
        /// scalars, one past the Basic Multilingual Plane), and any scalar.
        static let scalars = Gen<Unicode.Scalar>.oneOf(
            .element(
                of: Array("{}[]:,\"\\/.eE+-0123456789tfnrulsau ".unicodeScalars) + [
                    "\t", "\n", "\r", "\u{0}", "\u{1F}", "\u{7F}", "\u{A0}", "\u{FEFF}", "\u{2028}",
                    "\u{301}", "é", "\u{1F600}",
                ]
            ),
            Gen<UInt32>.integer(in: 0...0x10FFFF).map { Unicode.Scalar($0) ?? "\u{FFFD}" }
        )

        /// A document with a few edits, or any text at all.
        static let texts = Gen<String>.oneOf(
            Gen { tc in
                var scalars = Array(try tc.draw(documents).unicodeScalars)
                let edits = try tc.draw(Gen<Int>.element(of: [0, 1, 1, 1, 2, 3]))
                for _ in 0..<edits {
                    let at = try tc.draw(Gen<Int>.int(in: 0...scalars.count))
                    switch try tc.draw(Gen<Int>.int(in: 0...3)) {
                        case 0:
                            scalars.insert(try tc.draw(Self.scalars), at: at)
                        case 1 where at < scalars.count:
                            scalars[at] = try tc.draw(Self.scalars)
                        case 2 where at < scalars.count:
                            scalars.remove(at: at)
                        default:
                            scalars.removeSubrange(at...)
                    }
                }
                return String(String.UnicodeScalarView(scalars))
            },
            documents,
            .string()
        )

        /// `text` as JSON string content: quotes, backslashes and control
        /// characters escaped.
        static func escaped(_ text: String) -> String {
            var result = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                    case "\"": result += "\\\""
                    case "\\": result += "\\\\"
                    case _ where scalar.value < 0x20:
                        result += unicodeEscape(UInt16(scalar.value), uppercase: false)
                    default: result.unicodeScalars.append(scalar)
                }
            }
            return result
        }

        static func unicodeEscape(_ unit: UInt16, uppercase: Bool) -> String {
            let digits = String(unit, radix: 16, uppercase: uppercase)
            return "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
        }
    }

#endif

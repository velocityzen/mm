/// Where JSON text stops being JSON, and why: the reason
/// `MMCLIDynamicTree.parse(jsonText:)` gives for text it refuses, in the same
/// words on every platform.
///
/// `JSONDecoder` says where it stopped only in Apple's Foundation;
/// swift-foundation elsewhere says only that the text is not valid JSON. So
/// ``first(in:)`` reads the text before `JSONDecoder` does, for the first
/// place it stops being JSON. It accepts what `JSONDecoder` accepts:
///
/// - JSON as RFC 8259 defines it, with any value at the top level;
/// - a comma before the `]` or `}` that closes a non-empty array or object;
/// - a byte order mark before the document.
///
/// It refuses one thing `JSONDecoder` accepts: arrays and objects nested more
/// than ``maximumDepth`` deep.
///
/// A position is a line and a column, both counted from 1. A line ends at
/// `\n`, `\r\n` or a lone `\r`, and columns count Unicode scalars.
struct JSONSyntaxError: Error, Equatable, CustomStringConvertible {
    /// How deeply arrays and objects may nest: 128, `MMPackDecoder`'s
    /// default `maxDepth`, where `JSONDecoder` allows 512. `JSONTree` decodes
    /// each level in a call of its own, and a release build overflows the
    /// 512 KB stack of a task's thread at about 430 nested objects.
    static let maximumDepth = 128

    /// What is wrong at the position.
    enum Problem: Equatable, CustomStringConvertible {
        /// Something other than what JSON allows next: `expected` says what
        /// would do, and `found` is the scalar at the position, or nil where
        /// the text ends.
        case unexpected(expected: Expectation, found: Unicode.Scalar?)
        /// A string the text ends inside of. The position is its opening
        /// quote.
        case unterminatedString
        /// A backslash before something other than `"`, `\`, `/`, `b`, `f`,
        /// `n`, `r`, `t` or `u`. The position is the backslash.
        case invalidEscape(Unicode.Scalar)
        /// A `\u` escape of a high surrogate with no escape of a low
        /// surrogate right after it. The position is its backslash.
        case unpairedHighSurrogate(UInt16)
        /// A `\u` escape of a low surrogate with no escape of a high
        /// surrogate right before it. The position is its backslash.
        case unpairedLowSurrogate(UInt16)
        /// A control character, U+0000 to U+001F, in a string unescaped.
        case controlCharacter(Unicode.Scalar)
        /// A number whose 0 has another digit after it. The position is the
        /// zero.
        case leadingZero
        /// An array or object nested more than ``maximumDepth`` deep. The
        /// position is its opening bracket.
        case tooDeep

        /// Whether the text only ends too soon: more text after it could
        /// still make it JSON. Any other problem stays wherever the text
        /// goes on.
        var isEndOfText: Bool {
            switch self {
                case .unexpected(_, found: nil), .unterminatedString:
                    return true
                default:
                    return false
            }
        }

        var description: String {
            switch self {
                case .unexpected(let expected, let found):
                    let what = found.map(JSONSyntaxError.quoted) ?? "the end of the text"
                    return "Expected \(expected), found \(what)"
                case .unterminatedString:
                    return "Unterminated string"
                case .invalidEscape(let scalar):
                    guard JSONSyntaxError.isVisible(scalar) else {
                        return
                            "Invalid escape sequence '\\' followed by \(JSONSyntaxError.codePoint(scalar))"
                    }
                    return "Invalid escape sequence '\\\(scalar)'"
                case .unpairedHighSurrogate(let unit):
                    return "Unpaired high surrogate '\\u\(JSONSyntaxError.hexadecimal(unit))'"
                case .unpairedLowSurrogate(let unit):
                    return "Unpaired low surrogate '\\u\(JSONSyntaxError.hexadecimal(unit))'"
                case .controlCharacter(let scalar):
                    return
                        "Unescaped control character \(JSONSyntaxError.codePoint(scalar)) in a string"
                case .leadingZero:
                    return "Number with a leading zero"
                case .tooDeep:
                    return
                        "More than \(JSONSyntaxError.maximumDepth) arrays and objects nested in each other"
            }
        }
    }

    /// What JSON allows at a position.
    enum Expectation: Equatable, CustomStringConvertible {
        /// Any value: at the top level, or after a colon.
        case value
        /// A value, or the end of an array: after `[`, or after a comma in
        /// an array.
        case valueOrClosingBracket
        /// A comma, or the end of an array: after a value in an array.
        case commaOrClosingBracket
        /// A comma, or the end of an object: after a value in an object.
        case commaOrClosingBrace
        /// A key, or the end of an object: after `{`, or after a comma in an
        /// object.
        case keyOrClosingBrace
        /// The colon after a key.
        case colon
        /// Nothing but whitespace: after the top-level value.
        case endOfText
        /// The rest of `true`, `false` or `null`.
        case literal(String)
        /// A digit of a number.
        case digit
        /// One of the four hexadecimal digits of a `\u` escape.
        case unicodeEscapeDigit

        var description: String {
            switch self {
                case .value:
                    return "a value"
                case .valueOrClosingBracket:
                    return "a value or ']'"
                case .commaOrClosingBracket:
                    return "',' or ']'"
                case .commaOrClosingBrace:
                    return "',' or '}'"
                case .keyOrClosingBrace:
                    return "a quoted key or '}'"
                case .colon:
                    return "':'"
                case .endOfText:
                    return "the end of the text"
                case .literal(let word):
                    return "'\(word)'"
                case .digit:
                    return "a digit"
                case .unicodeEscapeDigit:
                    return "a hexadecimal digit in a '\\u' escape"
            }
        }
    }

    let problem: Problem
    /// The position, as a UTF-8 offset into the text.
    let offset: Int
    let line: Int
    let column: Int

    var description: String {
        "\(problem) at line \(line), column \(column)."
    }

    /// The first place `text` stops being JSON, or nil where it is JSON
    /// throughout.
    static func first(in text: String) -> JSONSyntaxError? {
        let bytes = Array(text.utf8)
        var scanner = JSONSyntaxScanner(bytes: bytes)
        guard let finding = scanner.firstProblem() else { return nil }
        return JSONSyntaxError(problem: finding.problem, offset: finding.offset, in: bytes)
    }

    /// The problem at `offset` in `bytes`, with the line and column it is at.
    init(problem: Problem, offset: Int, in bytes: [UInt8]) {
        var line = 1
        var column = 1
        for index in 0..<offset {
            let byte = bytes[index]
            let isLineEnd =
                byte == UInt8(ascii: "\n")
                || (byte == UInt8(ascii: "\r")
                    && (index + 1 == bytes.count || bytes[index + 1] != UInt8(ascii: "\n")))
            if isLineEnd {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                // Each scalar's first byte: continuation bytes are 10xxxxxx.
                column += 1
            }
        }
        self.problem = problem
        self.offset = offset
        self.line = line
        self.column = column
    }

    /// A scalar as a message shows it: quoted where it shows as itself, and
    /// as its code point where it would not (whitespace, a control or
    /// format character, a combining mark).
    static func quoted(_ scalar: Unicode.Scalar) -> String {
        isVisible(scalar) ? "'\(scalar)'" : codePoint(scalar)
    }

    /// Whether a scalar shows as itself on its own: a letter, a number, a
    /// punctuation mark or a symbol.
    static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                .otherLetter, .decimalNumber, .letterNumber, .otherNumber, .connectorPunctuation,
                .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol,
                .modifierSymbol, .otherSymbol:
                return true
            default:
                return false
        }
    }

    /// `U+` and at least four uppercase hexadecimal digits.
    static func codePoint(_ scalar: Unicode.Scalar) -> String {
        "U+" + hexadecimal(scalar.value)
    }

    /// At least four uppercase hexadecimal digits.
    static func hexadecimal(_ value: some BinaryInteger) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

/// A problem and the UTF-8 offset it is at.
private typealias Finding = (problem: JSONSyntaxError.Problem, offset: Int)

/// Reads JSON text the way `JSONDecoder` does, up to the first byte it would
/// refuse, or the first bracket nested too deep. `JSONDecoder` checks a
/// string's escapes and a number's digits only when it decodes them; this
/// checks them as it reads them, as `JSONTree` decodes every value.
private struct JSONSyntaxScanner {
    let bytes: [UInt8]
    var index = 0

    /// What the text must have next.
    private enum Step {
        case value(JSONSyntaxError.Expectation)
        case key
        case afterValue
    }

    /// The first problem, or nil where the text is JSON throughout.
    mutating func firstProblem() -> Finding? {
        // A byte order mark before the document is not part of it.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
        // The opening bracket of each array and object around the position.
        var open: [UInt8] = []
        var step = Step.value(.value)
        while true {
            skipWhitespace()
            switch step {
                case .value(let expectation):
                    guard let byte = peek() else {
                        return (.unexpected(expected: expectation, found: nil), index)
                    }
                    switch byte {
                        case UInt8(ascii: "\""):
                            if let finding = skipString() { return finding }
                            step = .afterValue
                        case UInt8(ascii: "["), UInt8(ascii: "{"):
                            guard open.count < JSONSyntaxError.maximumDepth else {
                                return (.tooDeep, index)
                            }
                            open.append(byte)
                            index += 1
                            skipWhitespace()
                            if peek() == closing(byte) {
                                index += 1
                                open.removeLast()
                                step = .afterValue
                            } else {
                                step =
                                    byte == UInt8(ascii: "[")
                                    ? .value(.valueOrClosingBracket) : .key
                            }
                        case UInt8(ascii: "t"):
                            if let finding = skipLiteral("true") { return finding }
                            step = .afterValue
                        case UInt8(ascii: "f"):
                            if let finding = skipLiteral("false") { return finding }
                            step = .afterValue
                        case UInt8(ascii: "n"):
                            if let finding = skipLiteral("null") { return finding }
                            step = .afterValue
                        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                            if let finding = skipNumber() { return finding }
                            step = .afterValue
                        default:
                            return (
                                .unexpected(expected: expectation, found: scalar(at: index)), index
                            )
                    }
                case .key:
                    guard peek() == UInt8(ascii: "\"") else {
                        return (.unexpected(expected: .keyOrClosingBrace, found: found()), index)
                    }
                    if let finding = skipString() { return finding }
                    skipWhitespace()
                    guard peek() == UInt8(ascii: ":") else {
                        return (.unexpected(expected: .colon, found: found()), index)
                    }
                    index += 1
                    step = .value(.value)
                case .afterValue:
                    guard let container = open.last else {
                        guard index < bytes.count else { return nil }
                        return (.unexpected(expected: .endOfText, found: scalar(at: index)), index)
                    }
                    let isArray = container == UInt8(ascii: "[")
                    switch peek() {
                        case UInt8(ascii: ",")?:
                            index += 1
                            skipWhitespace()
                            if peek() == closing(container) {
                                // A trailing comma, which `JSONDecoder` allows.
                                index += 1
                                open.removeLast()
                            } else {
                                step = isArray ? .value(.valueOrClosingBracket) : .key
                            }
                        case closing(container)?:
                            index += 1
                            open.removeLast()
                        default:
                            return (
                                .unexpected(
                                    expected: isArray
                                        ? .commaOrClosingBracket : .commaOrClosingBrace,
                                    found: found()
                                ),
                                index
                            )
                    }
            }
        }
    }

    // MARK: - Strings

    /// Skips the string whose opening quote is at the position.
    private mutating func skipString() -> Finding? {
        let start = index
        index += 1
        while index < bytes.count {
            switch bytes[index] {
                case UInt8(ascii: "\""):
                    index += 1
                    return nil
                case UInt8(ascii: "\\"):
                    if let finding = skipEscape(inStringAt: start) { return finding }
                case let byte where byte < 0x20:
                    return (.controlCharacter(Unicode.Scalar(byte)), index)
                default:
                    index += 1
            }
        }
        return (.unterminatedString, start)
    }

    /// Skips the escape whose backslash is at the position, in the string
    /// whose opening quote is at `start`.
    private mutating func skipEscape(inStringAt start: Int) -> Finding? {
        let backslash = index
        index += 1
        guard index < bytes.count else { return (.unterminatedString, start) }
        switch bytes[index] {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                index += 1
                return nil
            case UInt8(ascii: "u"):
                index += 1
            default:
                return (.invalidEscape(scalar(at: index)), backslash)
        }
        let unit: UInt16
        switch unicodeEscapeDigits(inStringAt: start) {
            case .value(let value): unit = value
            case .stop(let finding): return finding
        }
        if UTF16.isTrailSurrogate(unit) {
            return (.unpairedLowSurrogate(unit), backslash)
        }
        guard UTF16.isLeadSurrogate(unit) else { return nil }
        // A high surrogate needs `\u` and a low surrogate right after it.
        guard index < bytes.count else { return (.unterminatedString, start) }
        guard bytes[index] == UInt8(ascii: "\\") else {
            return (.unpairedHighSurrogate(unit), backslash)
        }
        guard index + 1 < bytes.count else { return (.unterminatedString, start) }
        guard bytes[index + 1] == UInt8(ascii: "u") else {
            return (.unpairedHighSurrogate(unit), backslash)
        }
        index += 2
        switch unicodeEscapeDigits(inStringAt: start) {
            case .value(let low) where UTF16.isTrailSurrogate(low):
                return nil
            case .value:
                return (.unpairedHighSurrogate(unit), backslash)
            case .stop(let finding):
                return finding
        }
    }

    /// The four hexadecimal digits of a `\u` escape, or where they stop.
    private enum UnicodeEscapeDigits {
        case value(UInt16)
        case stop(Finding)
    }

    /// Reads the four hexadecimal digits of the `\u` escape at the position.
    private mutating func unicodeEscapeDigits(inStringAt start: Int) -> UnicodeEscapeDigits {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { return .stop((.unterminatedString, start)) }
            let digit: UInt8
            switch bytes[index] {
                case let byte where (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte):
                    digit = byte - UInt8(ascii: "0")
                case let byte where (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte):
                    digit = byte - UInt8(ascii: "a") + 10
                case let byte where (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte):
                    digit = byte - UInt8(ascii: "A") + 10
                default:
                    return .stop(
                        (
                            .unexpected(expected: .unicodeEscapeDigit, found: scalar(at: index)),
                            index
                        )
                    )
            }
            value = value << 4 | UInt16(digit)
            index += 1
        }
        return .value(value)
    }

    // MARK: - Literals and numbers

    /// Skips `word`, which the text should have at the position.
    private mutating func skipLiteral(_ word: String) -> Finding? {
        for byte in word.utf8 {
            guard index < bytes.count else {
                return (.unexpected(expected: .literal(word), found: nil), index)
            }
            guard bytes[index] == byte else {
                return (.unexpected(expected: .literal(word), found: scalar(at: index)), index)
            }
            index += 1
        }
        return nil
    }

    /// Skips the number that starts at the position. What follows it is
    /// left to the caller: a number ends where JSON's number grammar does.
    private mutating func skipNumber() -> Finding? {
        if peek() == UInt8(ascii: "-") {
            index += 1
        }
        switch peek() {
            case UInt8(ascii: "0")?:
                if let next = peek(at: index + 1), isDigit(next) {
                    return (.leadingZero, index)
                }
                index += 1
            default:
                if let finding = skipDigits() { return finding }
        }
        if peek() == UInt8(ascii: ".") {
            index += 1
            if let finding = skipDigits() { return finding }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") {
                index += 1
            }
            if let finding = skipDigits() { return finding }
        }
        return nil
    }

    /// Skips one digit or more.
    private mutating func skipDigits() -> Finding? {
        guard let byte = peek(), isDigit(byte) else {
            return (.unexpected(expected: .digit, found: found()), index)
        }
        while let byte = peek(), isDigit(byte) {
            index += 1
        }
        return nil
    }

    // MARK: - Reading

    private func peek() -> UInt8? {
        peek(at: index)
    }

    private func peek(at offset: Int) -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private func closing(_ opening: UInt8) -> UInt8 {
        opening == UInt8(ascii: "[") ? UInt8(ascii: "]") : UInt8(ascii: "}")
    }

    /// The scalar at the position, or nil at the end of the text.
    private func found() -> Unicode.Scalar? {
        index < bytes.count ? scalar(at: index) : nil
    }

    /// The scalar that starts at `offset`, which is inside the text.
    private func scalar(at offset: Int) -> Unicode.Scalar {
        let end = min(offset + 4, bytes.count)
        return String(decoding: bytes[offset..<end], as: UTF8.self).unicodeScalars.first
            ?? "\u{FFFD}"
    }

    private mutating func skipWhitespace() {
        while let byte = peek(),
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
        {
            index += 1
        }
    }
}

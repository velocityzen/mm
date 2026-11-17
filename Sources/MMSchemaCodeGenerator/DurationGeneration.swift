// MARK: - Durations in source

// The macro reads durations from source without MMSchema: a default as
// ISO 8601 text, a range's ends as `Duration` literals. Both are held as a
// count of attoseconds, the unit `MMDuration` keeps, and must agree with the
// runtime's reading of the same source.

private let attosecondsPerSecond: UInt128 = 1_000_000_000_000_000_000

/// The attoseconds of ISO 8601 duration text, read by the grammar of the
/// runtime's `MMDuration.parse`:
/// `["-"] "P" [n "D"] ["T" [n "H"] [n "M"] [n ["." f] "S"]]`, with at least
/// one component, at least one after a `T`, and `f` 1 to 18 digits. Nil for
/// text that breaks the grammar or names a span beyond the range of
/// `Duration` (±2¹²⁷ attoseconds).
func durationAttoseconds(parsing text: String) -> Int128? {
    let bytes = Array(text.utf8)
    var index = 0
    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
    let negative = peek() == UInt8(ascii: "-")
    if negative { index += 1 }
    guard peek() == UInt8(ascii: "P") else { return nil }
    index += 1
    var magnitude: UInt128 = 0
    var overflowed = false
    func add(_ value: UInt128, times factor: UInt128 = 1) {
        let (product, productOverflow) = value.multipliedReportingOverflow(by: factor)
        let (sum, sumOverflow) = magnitude.addingReportingOverflow(product)
        if productOverflow || sumOverflow { overflowed = true } else { magnitude = sum }
    }
    var inTime = false
    var components = 0
    var timeComponents = 0
    // The designators in their order: D, then H, M, S after the T.
    var nextUnit = 0
    while index < bytes.count {
        if bytes[index] == UInt8(ascii: "T") {
            guard !inTime else { return nil }
            inTime = true
            index += 1
            continue
        }
        let start = index
        var whole: UInt128 = 0
        var wholeOverflowed = false
        while let byte = peek(), (0x30...0x39).contains(byte) {
            let (shifted, shiftOverflow) = whole.multipliedReportingOverflow(by: 10)
            let (next, digitOverflow) = shifted.addingReportingOverflow(UInt128(byte - 0x30))
            if shiftOverflow || digitOverflow { wholeOverflowed = true } else { whole = next }
            index += 1
        }
        guard index > start else { return nil }
        var fraction: UInt128?
        if peek() == UInt8(ascii: ".") {
            index += 1
            var digits = 0
            var value: UInt128 = 0
            while let byte = peek(), (0x30...0x39).contains(byte) {
                guard digits < 18 else { return nil }
                value = value * 10 + UInt128(byte - 0x30)
                digits += 1
                index += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<18 { value *= 10 }
            fraction = value
        }
        guard let designator = peek() else { return nil }
        index += 1
        let unit: Int
        let seconds: UInt128
        switch (designator, inTime) {
            case (UInt8(ascii: "D"), false): (unit, seconds) = (0, 86_400)
            case (UInt8(ascii: "H"), true): (unit, seconds) = (1, 3_600)
            case (UInt8(ascii: "M"), true): (unit, seconds) = (2, 60)
            case (UInt8(ascii: "S"), true): (unit, seconds) = (3, 1)
            default: return nil
        }
        guard unit >= nextUnit, fraction == nil || unit == 3 else { return nil }
        nextUnit = unit + 1
        components += 1
        if inTime { timeComponents += 1 }
        if wholeOverflowed { overflowed = true }
        add(whole, times: seconds * attosecondsPerSecond)
        add(fraction ?? 0)
    }
    guard components > 0, !inTime || timeComponents > 0, !overflowed else { return nil }
    if negative {
        guard magnitude <= Int128.min.magnitude else { return nil }
        return magnitude == Int128.min.magnitude ? .min : -Int128(magnitude)
    }
    return Int128(exactly: magnitude)
}

/// The canonical ISO 8601 text of a span of attoseconds, as the runtime's
/// `MMDuration.description` writes it: `PT0S`, `PT1H30M`, `-PT0.5S`.
func durationText(_ attoseconds: Int128) -> String {
    guard attoseconds != 0 else { return "PT0S" }
    let magnitude = attoseconds.magnitude
    let wholeSeconds = magnitude / attosecondsPerSecond
    let fraction = magnitude % attosecondsPerSecond
    let hours = wholeSeconds / 3_600
    let minutes = wholeSeconds % 3_600 / 60
    let seconds = wholeSeconds % 60
    var text = attoseconds < 0 ? "-PT" : "PT"
    if hours > 0 { text += "\(hours)H" }
    if minutes > 0 { text += "\(minutes)M" }
    if seconds > 0 || fraction > 0 {
        text += "\(seconds)"
        if fraction > 0 {
            var digits = String(fraction)
            digits = String(repeating: "0", count: 18 - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        text += "S"
    }
    return text
}

/// The `MMDuration` expression of a span of attoseconds.
func durationExpression(_ attoseconds: Int128) -> String {
    "MMDuration(Duration(attoseconds: \(attoseconds)))"
}

/// The attoseconds of a `Duration` literal, as a range's end is written:
/// `.seconds(30)`, `.milliseconds(-250)`, `Duration.nanoseconds(1)`,
/// `.zero`, parenthesized or not. Nil for any other expression. The count
/// is an integer literal: `Duration.seconds(Double)` rounds through a
/// binary floating number, which the macro does not reproduce.
func durationLiteralAttoseconds(_ text: String) -> Int128? {
    var text = Substring(text.filter { !$0.isWhitespace })
    while text.hasPrefix("("), text.hasSuffix(")") {
        text = text.dropFirst().dropLast()
    }
    if text.hasPrefix("Duration.") {
        text = text.dropFirst("Duration".count)
    }
    guard text.hasPrefix(".") else { return nil }
    text = text.dropFirst()
    if text == "zero" { return 0 }
    let units: [(name: String, attoseconds: Int128)] = [
        ("seconds", 1_000_000_000_000_000_000),
        ("milliseconds", 1_000_000_000_000_000),
        ("microseconds", 1_000_000_000_000),
        ("nanoseconds", 1_000_000_000),
    ]
    for unit in units where text.hasPrefix(unit.name + "(") && text.hasSuffix(")") {
        let argument = text.dropFirst(unit.name.count + 1).dropLast()
        guard let count = integerLiteral(String(argument).filter { $0 != "_" }) else {
            return nil
        }
        return Int128(count) * unit.attoseconds
    }
    return nil
}

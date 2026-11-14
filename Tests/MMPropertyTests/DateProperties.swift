// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import Foundation
    import HegelTesting
    import MMSchema
    import Testing

    enum DateKind: String, CaseIterable, Sendable {
        case date = "a date"
        case dateTime = "a datetime"
        case timestamp = "a timestamp"
    }

    /// The fields of a date, a datetime or a timestamp, valid or not. A kind
    /// reads only the fields it carries.
    struct DateFields: Sendable, Hashable {
        var year = 1970
        var month = 1
        var day = 1
        var hour = 0
        var minute = 0
        var second = 0
        var nanosecond = 0
        var offsetNegative = false
        var offsetHours = 0
        var offsetMinutes = 0

        /// The offset in minutes east of UTC.
        var offset: Int {
            (offsetNegative ? -1 : 1) * (offsetHours * 60 + offsetMinutes)
        }

        mutating func setOffset(_ minutes: Int) {
            offsetNegative = minutes < 0
            offsetHours = abs(minutes) / 60
            offsetMinutes = abs(minutes) % 60
        }
    }

    /// The first and last days of the wire range, 0000-01-01 and
    /// 9999-12-31, counted from 1970-01-01.
    let firstWireDay = -719_528
    let lastWireDay = 2_932_896
    let wireDays = firstWireDay...lastWireDay

    /// Whether the fields a kind carries name a real date, clock and
    /// offset: a year of four digits, month 1...12, a day within its month,
    /// hour 0...23, minute 0...59, second 0...60 (a leap second), and an
    /// offset within ±18:00 whose minutes are under 60.
    func isValid(_ fields: DateFields, as kind: DateKind) -> Bool {
        let date =
            (0...9999).contains(fields.year) && (1...12).contains(fields.month)
            && (1...daysIn(month: fields.month, year: Int64(fields.year))).contains(fields.day)
        guard kind != .date else { return date }
        let clock =
            date && (0...23).contains(fields.hour) && (0...59).contains(fields.minute)
            && (0...60).contains(fields.second) && (0..<1_000_000_000).contains(fields.nanosecond)
        guard kind == .timestamp else { return clock }
        return clock && fields.offsetMinutes < 60
            && fields.offsetHours * 60 + fields.offsetMinutes <= 1080
    }

    func zeroPadded(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// The canonical text of valid fields (wire specification, section
    /// 6.4): zero-padded fields, an uppercase `T`, a fraction only when
    /// non-zero with its trailing zeros dropped, and `Z` for offset zero.
    func canonicalText(of fields: DateFields, as kind: DateKind) -> String {
        var text =
            "\(zeroPadded(fields.year, 4))-\(zeroPadded(fields.month, 2))-\(zeroPadded(fields.day, 2))"
        guard kind != .date else { return text }
        text +=
            "T\(zeroPadded(fields.hour, 2)):\(zeroPadded(fields.minute, 2)):\(zeroPadded(fields.second, 2))"
        if fields.nanosecond != 0 {
            text +=
                "."
                + String(zeroPadded(fields.nanosecond, 9).reversed().drop { $0 == "0" }.reversed())
        }
        guard kind == .timestamp else { return text }
        guard fields.offset != 0 else { return text + "Z" }
        let sign = fields.offset < 0 ? "-" : "+"
        return text + sign
            + "\(zeroPadded(fields.offsetHours, 2)):\(zeroPadded(fields.offsetMinutes, 2))"
    }

    /// A value of any of the three kinds, so one property covers them all.
    enum DateValue: Hashable, CustomStringConvertible {
        case date(MMDate)
        case dateTime(MMDateTime)
        case timestamp(MMTimestamp)

        var description: String {
            switch self {
                case .date(let value): value.description
                case .dateTime(let value): value.description
                case .timestamp(let value): value.description
            }
        }
    }

    func dateValue(of fields: DateFields, as kind: DateKind) -> DateValue? {
        guard let date = MMDate(year: fields.year, month: fields.month, day: fields.day) else {
            return nil
        }
        guard kind != .date else { return .date(date) }
        guard
            let dateTime = MMDateTime(
                date: date,
                hour: fields.hour,
                minute: fields.minute,
                second: fields.second,
                nanosecond: fields.nanosecond
            )
        else { return nil }
        guard kind == .timestamp else { return .dateTime(dateTime) }
        return MMTimestamp(dateTime: dateTime, offsetMinutes: fields.offset).map { .timestamp($0) }
    }

    func parseDate(_ text: String, as kind: DateKind) -> Result<DateValue, MMDateTimeParseFailure> {
        switch kind {
            case .date: MMDate.parse(text).map { .date($0) }
            case .dateTime: MMDateTime.parse(text).map { .dateTime($0) }
            case .timestamp: MMTimestamp.parse(text).map { .timestamp($0) }
        }
    }

    /// A piece of date text: fixed-width digits, a separator or zone
    /// letter, or a fraction with its dot.
    struct TextPiece: Sendable {
        enum Role: Sendable { case digits, separator, fraction }
        var text: String
        var role: Role
    }

    /// One way to break the grammar. Each leaves text that no kind parses:
    /// every field is fixed-width and every separator required, so a shift
    /// or a stray character always lands where the grammar wants something
    /// else.
    enum TextBreak: String, CaseIterable, Sendable {
        case dropSeparator = "a separator dropped"
        case swapSeparator = "a separator swapped"
        case extraDigit = "an extra digit"
        case missingDigit = "a missing digit"
        case foreignDigit = "a digit that is not ASCII"
        case emptyFraction = "a dot with no fraction"
        case longFraction = "a fraction past nine digits"
        case leadingJunk = "a character before"
        case trailingJunk = "a character after"
    }

    /// Text for a kind, built from fields that may name no real date, with
    /// the grammar's liberties (lowercase `t` and `z`, `±00:00` for `Z`)
    /// and maybe one break.
    struct DateText: Sendable {
        var kind: DateKind
        var fields: DateFields
        var text: String
        var textBreak: TextBreak?
    }

    /// Foundation's Gregorian calendar in UTC.
    let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// 1583-01-01. Foundation's calendar is Julian before the Gregorian
    /// reform of 1582 and MMSchema's is proleptic Gregorian, so they are
    /// compared from the first whole year after it.
    let firstFoundationDay = -141_349

    func foundationDate(of fields: DateFields, offset: Int = 0) -> Date? {
        var calendar = utcCalendar
        if offset != 0, let zone = TimeZone(secondsFromGMT: offset * 60) {
            calendar.timeZone = zone
        }
        let components = DateComponents(
            year: fields.year,
            month: fields.month,
            day: fields.day,
            hour: fields.hour,
            minute: fields.minute,
            second: fields.second
        )
        return calendar.date(from: components)
    }

    /// The UTC date and clock fields of a Foundation date.
    func foundationFields(of date: Date) -> DateFields {
        let components = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return DateFields(
            year: components.year ?? -1,
            month: components.month ?? -1,
            day: components.day ?? -1,
            hour: components.hour ?? -1,
            minute: components.minute ?? -1,
            second: components.second ?? -1
        )
    }

    func fields(of date: MMDate) -> DateFields {
        DateFields(year: date.year, month: date.month, day: date.day)
    }

    func fields(of dateTime: MMDateTime) -> DateFields {
        var fields = fields(of: dateTime.date)
        (fields.hour, fields.minute, fields.second) = (
            dateTime.hour, dateTime.minute, dateTime.second
        )
        fields.nanosecond = dateTime.nanosecond
        return fields
    }

    /// The seconds since 1970 of a wall clock read as UTC, by Foundation.
    func foundationSeconds(of fields: DateFields, offset: Int = 0) throws -> Int {
        Int(try #require(foundationDate(of: fields, offset: offset)).timeIntervalSince1970)
    }

    enum CalendarOperation: String, CaseIterable, Sendable {
        case dayNumber = "a date's day number"
        case dateOfDayNumber = "the date of a day number"
        case days = "adding days"
        case months = "adding months"
        case years = "adding years"
        case hours = "adding hours"
        case minutes = "adding minutes"
        case seconds = "adding seconds"
        case instants = "two timestamps' instants"
    }

    /// A component of calendar arithmetic, any count to come.
    enum ComponentKind: String, CaseIterable, Sendable {
        case year, month, day, hour, minute, second, nanosecond
        case dayNumber = "day number"

        func component(_ count: Int) -> MMDateComponent {
            switch self {
                case .year: .year(count)
                case .month: .month(count)
                case .day, .dayNumber: .day(count)
                case .hour: .hour(count)
                case .minute: .minute(count)
                case .second: .second(count)
                case .nanosecond: .nanosecond(count)
            }
        }
    }

    /// Where adding `count` of a component to the datetime lands, worked
    /// out in Int128, where no Int count can overflow, and read in the unit
    /// the component moves: months since 0000-01 for years and months, a
    /// day number for days, nanoseconds since the epoch on the wall clock
    /// for the clock components. Nil past the wire range. For the day
    /// number, `count` itself when it is one.
    func landing(
        _ fields: DateFields,
        days: Int,
        adding count: Int128,
        of kind: ComponentKind
    ) -> Int128? {
        let second: Int128 = 1_000_000_000
        let wireDayNumbers = Int128(firstWireDay)...Int128(lastWireDay)
        let target: Int128
        let range: ClosedRange<Int128>
        switch kind {
            case .dayNumber:
                (target, range) = (count, wireDayNumbers)
            case .year, .month:
                // Year 0...9999 is months 0...119_999 since 0000-01.
                let months = Int128(fields.year * 12 + fields.month - 1)
                (target, range) = (months + (kind == .year ? count * 12 : count), 0...119_999)
            case .day:
                (target, range) = (Int128(days) + count, wireDayNumbers)
            case .hour, .minute, .second, .nanosecond:
                let unit: Int128 =
                    switch kind {
                        case .hour: 3600 * second
                        case .minute: 60 * second
                        case .second: second
                        default: 1
                    }
                let clock = Int128(fields.hour * 3600 + fields.minute * 60 + fields.second)
                let start = (Int128(days) * 86_400 + clock) * second + Int128(fields.nanosecond)
                let first = Int128(firstWireDay) * 86_400 * second
                let last = Int128(lastWireDay + 1) * 86_400 * second - 1
                (target, range) = (start + count * unit, first...last)
        }
        return range.contains(target) ? target : nil
    }

    /// A datetime read in the unit `landing` uses for the component.
    func reading(_ dateTime: MMDateTime, as kind: ComponentKind) -> Int128 {
        let date = dateTime.date
        switch kind {
            case .year, .month:
                return Int128(date.year * 12 + date.month - 1)
            case .day, .dayNumber:
                return Int128(date.daysSinceEpoch)
            case .hour, .minute, .second, .nanosecond:
                let clock = Int128(dateTime.hour * 3600 + dateTime.minute * 60 + dateTime.second)
                return (Int128(date.daysSinceEpoch) * 86_400 + clock) * 1_000_000_000
                    + Int128(dateTime.nanosecond)
        }
    }

    enum DateGenerators {
        static let yearMenu = [
            0, 1, 4, 100, 400, 1582, 1583, 1600, 1900, 1969, 1970, 2000, 2024, 9999,
        ]

        static let nanoseconds: Gen<Int> = .oneOf(
            .int(in: 0...999_999_999),
            .element(of: [0, 1, 10, 100_000_000, 120_000_000, 500_000_000, 999_999_999])
        )

        /// Offsets within ±18:00, a third of them at either bound.
        static let offsets: Gen<Int> = .oneOf(
            .int(in: -1080...1080),
            .element(of: [-1080, 1080]),
            .element(of: [-1, 0, 1, 330])
        )

        /// Any day of any month in the years, often the first or last.
        static func anyDay(in years: ClosedRange<Int>) -> Gen<DateFields> {
            Gen { tc in
                let year = try tc.draw(
                    Gen<Int>.oneOf(.int(in: years), .element(of: yearMenu.filter(years.contains)))
                )
                let month = try tc.draw(Gen<Int>.oneOf(.int(in: 1...12), .element(of: [1, 2, 12])))
                let last = daysIn(month: month, year: Int64(year))
                let day = try tc.draw(Gen<Int>.oneOf(.int(in: 1...last), .element(of: [1, last])))
                return DateFields(year: year, month: month, day: day)
            }
        }

        /// The end of February or the turn of a year in a year where the
        /// leap rules part: every fourth year, every century, every fourth
        /// century, or any year.
        static func yearEdges(in years: ClosedRange<Int>) -> Gen<DateFields> {
            Gen { tc in
                func multiples(of step: Int) -> Gen<Int> {
                    Gen<Int>.int(
                        in: ((years.lowerBound + step - 1) / step)...(years.upperBound / step)
                    ).map { $0 * step }
                }
                let year = try tc.draw(
                    Gen<Int>.oneOf(
                        multiples(of: 400),
                        multiples(of: 100),
                        multiples(of: 4),
                        .int(in: years)
                    )
                )
                let endOfFebruary = daysIn(month: 2, year: Int64(year))
                switch try tc.draw(Gen<Int>.int(in: 0...4)) {
                    case 0: return DateFields(year: year, month: 2, day: 28)
                    case 1: return DateFields(year: year, month: 2, day: endOfFebruary)
                    case 2: return DateFields(year: year, month: 3, day: 1)
                    case 3: return DateFields(year: year, month: 12, day: 31)
                    default: return DateFields(year: year, month: 1, day: 1)
                }
            }
        }

        static func dates(in years: ClosedRange<Int>) -> Gen<DateFields> {
            .oneOf(anyDay(in: years), yearEdges(in: years))
        }

        /// Valid fields for every kind: a date from `dates`, any clock with
        /// second 60 included, any nanosecond, any offset.
        static func withClock(_ dates: Gen<DateFields>) -> Gen<DateFields> {
            Gen { tc in
                var fields = try tc.draw(dates)
                fields.hour = try tc.draw(Gen<Int>.oneOf(.int(in: 0...23), .element(of: [0, 23])))
                fields.minute = try tc.draw(
                    Gen<Int>.oneOf(.int(in: 0...59), .element(of: [0, 59]))
                )
                fields.second = try tc.draw(
                    Gen<Int>.oneOf(.int(in: 0...60), .element(of: [0, 59, 60]))
                )
                fields.nanosecond = try tc.draw(nanoseconds)
                fields.setOffset(try tc.draw(offsets))
                return fields
            }
        }

        static let validFields = withClock(dates(in: 0...9999))

        /// Fields as text can carry them: each in its range, at an edge just
        /// past it, or any value its two digits hold.
        static let anyFields: Gen<DateFields> = Gen { tc in
            func field(_ inRange: ClosedRange<Int>, _ edges: [Int]) throws -> Int {
                try tc.draw(
                    Gen<Int>.oneOf(.int(in: inRange), .element(of: edges), .int(in: 0...99))
                )
            }
            var fields = DateFields()
            fields.year = try tc.draw(Gen<Int>.oneOf(.int(in: 0...9999), .element(of: yearMenu)))
            fields.month = try field(1...12, [0, 13, 99])
            fields.day = try field(1...28, [0, 29, 30, 31, 32])
            fields.hour = try field(0...23, [24, 99])
            fields.minute = try field(0...59, [60, 99])
            fields.second = try field(0...60, [61, 99])
            fields.offsetNegative = try tc.draw(.bool())
            fields.offsetHours = try field(0...18, [18, 19, 23, 99])
            fields.offsetMinutes = try field(0...59, [0, 1, 60, 99])
            return fields
        }

        static let fractionDigits: Gen<String> = .oneOf(
            .just(""),
            .string(of: .characters("0123456789"), count: 1...9),
            .element(of: ["0", "000000000", "5", "100", "123456789", "999999999"])
        )

        /// Characters that are no separator the grammar has, and no digit.
        static let strangers = [" ", "/", "_", "x", "\u{2010}", "\u{FF1A}"]

        static func applying(_ textBreak: TextBreak, to pieces: inout [TextPiece], _ tc: TestCase)
            throws
        {
            func index(of role: TextPiece.Role) throws -> Int {
                try tc.draw(.element(of: pieces.indices.filter { pieces[$0].role == role }))
            }
            func setFraction(_ text: String) {
                if let index = pieces.firstIndex(where: { $0.role == .fraction }) {
                    pieces[index].text = text
                } else {
                    // After the seconds, the eleventh piece.
                    pieces.insert(TextPiece(text: text, role: .fraction), at: 11)
                }
            }
            switch textBreak {
                case .dropSeparator:
                    pieces.remove(at: try index(of: .separator))
                case .swapSeparator:
                    pieces[try index(of: .separator)].text = try tc.draw(.element(of: strangers))
                case .extraDigit:
                    pieces[try index(of: .digits)].text += String(
                        try tc.draw(Gen<Int>.int(in: 0...9))
                    )
                case .missingDigit:
                    pieces[try index(of: .digits)].text.removeLast()
                case .foreignDigit:
                    let piece = try index(of: .digits)
                    var characters = Array(pieces[piece].text)
                    let position = try tc.draw(Gen<Int>.int(in: 0...(characters.count - 1)))
                    characters[position] = try tc.draw(
                        .element(of: ["\u{0663}", "\u{FF13}", "a", "O"])
                    )
                    pieces[piece].text = String(characters)
                case .emptyFraction:
                    setFraction(".")
                case .longFraction:
                    setFraction(
                        "."
                            + (try tc.draw(
                                Gen<String>.string(of: .characters("0123456789"), count: 10...12)
                            ))
                    )
                case .leadingJunk:
                    let junk = try tc.draw(
                        Gen<String>.element(of: [" ", "+", "x", "0", "\u{FEFF}"])
                    )
                    pieces.insert(TextPiece(text: junk, role: .separator), at: 0)
                case .trailingJunk:
                    let junk = try tc.draw(
                        Gen<String>.element(of: [
                            " ", "\n", "x", "Z", "\u{E9}", "\u{0}", "-", "T", ".",
                        ])
                    )
                    pieces.append(TextPiece(text: junk, role: .separator))
            }
        }

        static let texts: Gen<DateText> = Gen { tc in
            let kind = try tc.draw(Gen<DateKind>.element(of: DateKind.allCases))
            var fields = try tc.draw(Gen<DateFields>.oneOf(validFields, anyFields))
            let fraction = try tc.draw(fractionDigits)
            fields.nanosecond =
                Int(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? -1

            func digits(_ value: Int, _ width: Int) -> TextPiece {
                TextPiece(text: zeroPadded(value, width), role: .digits)
            }
            func separator(_ text: String) -> TextPiece { TextPiece(text: text, role: .separator) }
            var pieces = [
                digits(fields.year, 4), separator("-"), digits(fields.month, 2), separator("-"),
                digits(fields.day, 2),
            ]
            if kind != .date {
                pieces += [
                    separator(try tc.draw(.element(of: ["T", "t"]))), digits(fields.hour, 2),
                    separator(":"),
                    digits(fields.minute, 2), separator(":"), digits(fields.second, 2),
                ]
                if !fraction.isEmpty {
                    pieces.append(TextPiece(text: "." + fraction, role: .fraction))
                }
            }
            if kind == .timestamp {
                let letterWanted = try tc.draw(Gen<Bool>.bool())
                if fields.offset == 0 && letterWanted {
                    pieces.append(separator(try tc.draw(.element(of: ["Z", "z"]))))
                } else {
                    pieces += [
                        separator(fields.offsetNegative ? "-" : "+"), digits(fields.offsetHours, 2),
                        separator(":"),
                        digits(fields.offsetMinutes, 2),
                    ]
                }
            }

            let breaks =
                kind == .date
                ? TextBreak.allCases.filter { ![.emptyFraction, .longFraction].contains($0) }
                : TextBreak.allCases
            let textBreak = try tc.draw(Gen<TextBreak?>.optional(.element(of: breaks)))
            if let textBreak { try applying(textBreak, to: &pieces, tc) }
            return DateText(
                kind: kind,
                fields: fields,
                text: pieces.map(\.text).joined(),
                textBreak: textBreak
            )
        }

        /// Day numbers in the wire range, at its edges, or far past it.
        static let dayNumbers: Gen<Int> = .oneOf(
            .int(in: wireDays),
            .element(of: [firstWireDay - 1, firstWireDay, -1, 0, 1, lastWireDay, lastWireDay + 1]),
            .int(in: -(1 << 50)...(1 << 50))
        )

        /// A count of days from day `start` that lands in the wire range,
        /// just past either end, or far past it.
        static func dayCounts(from start: Int) -> Gen<Int> {
            .oneOf(
                .int(in: (firstWireDay - start)...(lastWireDay - start)),
                .element(of: [firstWireDay - start - 1, lastWireDay - start + 1, -1, 0, 1]),
                .int(in: -(1 << 50)...(1 << 50))
            )
        }

        /// A date from 1583 on, where Foundation's calendar is Gregorian too.
        static let foundationDates = dates(in: 1583...9999)

        /// A count in `range`, often at either end or zero.
        static func counts(in range: ClosedRange<Int>) -> Gen<Int> {
            .oneOf(
                .int(in: range),
                .element(of: [range.lowerBound, range.upperBound, 0].filter(range.contains))
            )
        }
    }

    @Suite("Date and time properties", .hegel, .offTheCooperativePool)
    struct DateProperties {
        /// Every date, datetime and timestamp renders as its canonical text
        /// (wire specification, section 6.4) and parses back to itself.
        ///
        /// Mutation check: trimming only one trailing zero from the fraction,
        /// or rejecting a +18:00 offset, fails here.
        @Test
        func everyValueRoundTripsThroughText() throws {
            try property(
                reaching: reachClaims(
                    everyRun: ["a date", "a timestamp"],
                    deepRuns: ["a datetime", "a leap second", "offset +18:00", "offset -18:00"]
                )
            ) { tc in
                let kind = try #draw(Gen<DateKind>.element(of: DateKind.allCases), from: tc)
                let fields = try #draw(DateGenerators.validFields, from: tc)
                try tc.event(kind.rawValue)
                if kind != .date && fields.second == 60 { try tc.event("a leap second") }
                if kind == .timestamp && fields.offset == 1080 { try tc.event("offset +18:00") }
                if kind == .timestamp && fields.offset == -1080 { try tc.event("offset -18:00") }
                let value = try #require(dateValue(of: fields, as: kind), "\(fields)")
                #expect(value.description == canonicalText(of: fields, as: kind))
                #expect(parseDate(value.description, as: kind) == .success(value))
            }
        }

        /// Text parses exactly when it follows its kind's grammar and names
        /// a real date, clock and offset; then it gives those fields and
        /// renders canonically. Grammatical text naming no real value fails
        /// as `invalidComponent`; a grammar break fails as `malformedText`,
        /// or as `invalidComponent` when an impossible field comes first.
        ///
        /// Mutation check: a date parser that takes text after the day fails
        /// here.
        @Test
        func parsingFollowsTheGrammar() throws {
            try property(
                reaching: reachClaims(
                    everyRun: [
                        "a timestamp", "failed with invalidComponent", "failed with malformedText",
                        "no break",
                    ],
                    deepRuns: [
                        "a character after", "a character before", "a date", "a datetime",
                        "a digit that is not ASCII", "a missing digit", "a separator dropped",
                        "a separator swapped", "an extra digit", "parsed",
                    ]
                )
            ) { tc in
                let text = try #draw(DateGenerators.texts, from: tc)
                let valid = isValid(text.fields, as: text.kind)
                let parsed = parseDate(text.text, as: text.kind)
                try tc.event(text.kind.rawValue)
                try tc.event(text.textBreak?.rawValue ?? "no break")
                switch parsed {
                    case .success: try tc.event("parsed")
                    case .failure(let failure): try tc.event("failed with \(failure)")
                }
                if let textBreak = text.textBreak {
                    let allowed: [MMDateTimeParseFailure] =
                        valid ? [.malformedText] : [.malformedText, .invalidComponent]
                    guard case .failure(let failure) = parsed, allowed.contains(failure) else {
                        Issue.record(
                            "\(text.text.debugDescription), with \(textBreak.rawValue), gave \(parsed)"
                        )
                        return
                    }
                } else if valid {
                    let value = try #require(
                        dateValue(of: text.fields, as: text.kind),
                        "\(text.fields)"
                    )
                    #expect(parsed == .success(value), "\(text.text.debugDescription)")
                    #expect(value.description == canonicalText(of: text.fields, as: text.kind))
                } else {
                    #expect(parsed == .failure(.invalidComponent), "\(text.text.debugDescription)")
                }
            }
        }

        /// A date's day number gives the date back, and a day number gives
        /// a date exactly when it lies in the wire range, one with that day
        /// number, which orders against other dates as the numbers do.
        ///
        /// Mutation check: reading a day number back without the 400-year
        /// term (29 February of every fourth century), or numbering January
        /// and February of year 0 with a truncated era, fails here and in
        /// `dayArithmeticInverts`.
        @Test
        func dayNumbersRoundTrip() throws {
            try property(
                reaching: reachClaims(
                    everyRun: ["a day number in the wire range"],
                    deepRuns: ["a day number past it"]
                )
            ) { tc in
                let fields = try #draw(DateGenerators.dates(in: 0...9999), from: tc)
                let number = try #draw(DateGenerators.dayNumbers, from: tc)
                let date = try #require(
                    MMDate(year: fields.year, month: fields.month, day: fields.day)
                )
                try tc.event(
                    wireDays.contains(number)
                        ? "a day number in the wire range" : "a day number past it"
                )
                #expect(MMDate.date(daysSinceEpoch: date.daysSinceEpoch) == date)
                let numbered = MMDate.date(daysSinceEpoch: number)
                #expect((numbered != nil) == wireDays.contains(number), "\(number)")
                if let numbered {
                    #expect(numbered.daysSinceEpoch == number)
                    #expect((numbered < date) == (number < date.daysSinceEpoch))
                }
            }
        }

        /// Adding days gives a date exactly when it lands in the wire
        /// range; then `(d + .day(n)) - d == n`, subtracting the days gives
        /// `d` back, and the result is later exactly when `n` is positive.
        @Test
        func dayArithmeticInverts() throws {
            try property(
                reaching: reachClaims(
                    everyRun: ["lands in the wire range"],
                    deepRuns: ["lands past it"]
                )
            ) { tc in
                let fields = try #draw(DateGenerators.dates(in: 0...9999), from: tc)
                let date = try #require(
                    MMDate(year: fields.year, month: fields.month, day: fields.day)
                )
                let count = try #draw(DateGenerators.dayCounts(from: date.daysSinceEpoch), from: tc)
                let lands = wireDays.contains(date.daysSinceEpoch + count)
                try tc.event(lands ? "lands in the wire range" : "lands past it")
                let result = date.adding(.day(count))
                #expect((result != nil) == lands, "\(date) + \(count) days")
                if let result {
                    #expect(result - date == count)
                    #expect(date.distance(to: result) == count)
                    #expect(result.adding(.day(-count)) == date)
                    #expect((date < result) == (count > 0))
                }
            }
        }

        /// Adding any count of any component, up to Int's limits, gives the
        /// value the calendar says, or nil exactly when that leaves the wire
        /// range, and never traps; so does the date of any day number.
        /// Subtracting any count, Int.min included, gives the value the
        /// calendar says wherever that lands in the range. Values are read
        /// in the unit the component moves, so a month added to 31 January
        /// is checked to land in February, not on which day.
        ///
        /// Mutation check: dropping the range check on a day number,
        /// multiplying an hour count without reporting overflow, leaving a
        /// nanosecond remainder negative, subtracting by plain negation, or
        /// subtracting Int.min as Int.max alone, fails here. Splitting a
        /// month total before its range check fails at the nightly depth:
        /// it overflows only from the first months of year 0 with a count
        /// near Int.min.
        @Test
        func anyCountGivesAValueOrNil() throws {
            try property(
                reaching: reachClaims(
                    everyRun: [
                        "added", "lands in the wire range", "lands past it", "nanosecond",
                        "subtracted",
                    ],
                    deepRuns: [
                        "Int.min subtracted, landing in the range", "day", "day number", "hour",
                        "minute", "month", "second", "year",
                    ]
                )
            ) { tc in
                let fields = try #draw(DateGenerators.validFields, from: tc)
                // Nanoseconds get a branch of their own: they are the only
                // component whose counts at Int's ends land inside the range.
                let kind = try #draw(
                    Gen<ComponentKind>.oneOf(
                        .element(of: ComponentKind.allCases),
                        .just(.nanosecond)
                    ),
                    from: tc
                )
                // Int's two ends get a branch of their own: they are what
                // this property is for.
                let count = try #draw(
                    Gen<Int>.oneOf(
                        .int(),
                        .element(of: [.min, .max]),
                        .element(of: [.min + 1, .max - 1, -1, 0, 1])
                    ),
                    from: tc
                )
                let subtractDrawn = try #draw(Gen<Bool>.bool(), from: tc)
                let subtract = subtractDrawn && kind != .dayNumber
                let dateTime = try #require(dateValue(of: fields, as: .dateTime))
                guard case .dateTime(let dateTime) = dateTime else { return }
                let days = dateTime.date.daysSinceEpoch
                let wide = subtract ? -Int128(count) : Int128(count)
                let expected = landing(fields, days: days, adding: wide, of: kind)
                try tc.event(kind.rawValue)
                try tc.event(subtract ? "subtracted" : "added")
                try tc.event(expected != nil ? "lands in the wire range" : "lands past it")
                if subtract && count == .min && expected != nil {
                    try tc.event("Int.min subtracted, landing in the range")
                }
                let label = "\(dateTime) \(subtract ? "-" : "+") \(count) \(kind.rawValue)"
                if subtract {
                    // The operator traps past the range, as documented, so
                    // it is tried only where the result lands.
                    guard let expected else { return }
                    #expect(
                        reading(dateTime - kind.component(count), as: kind) == expected,
                        "\(label)"
                    )
                    return
                }
                let result: Int128? =
                    kind == .dayNumber
                    ? MMDate.date(daysSinceEpoch: count).map { Int128($0.daysSinceEpoch) }
                    : dateTime.adding(kind.component(count)).map { reading($0, as: kind) }
                #expect(result == expected, "\(label)")
            }
        }

        /// Day numbers and calendar arithmetic agree with Foundation's
        /// Gregorian calendar from 1583 on: a date's day number, the date of
        /// a day number, adding days, months (clamped to the month's length)
        /// and years to a date, adding hours, minutes and seconds to a
        /// datetime (a leap second folding into the next minute), and two
        /// timestamps' instants, difference and order. A result past 9999
        /// is nil.
        ///
        /// Mutation check: month addition that stops clamping the day
        /// (31 January plus a month) fails here.
        @Test
        func calendarAgreesWithFoundation() throws {
            try property(
                reaching: reachClaims(
                    everyRun: [],
                    deepRuns: [
                        "a date's day number", "adding days", "adding hours", "adding minutes",
                        "adding months", "adding seconds", "adding years", "past 9999",
                        "the date of a day number", "two timestamps' instants",
                    ]
                )
            ) { tc in
                let operation = try #draw(
                    Gen<CalendarOperation>.element(of: CalendarOperation.allCases),
                    from: tc
                )
                let fields = try #draw(
                    DateGenerators.withClock(DateGenerators.foundationDates),
                    from: tc
                )
                try tc.event(operation.rawValue)
                let date = try #require(
                    MMDate(year: fields.year, month: fields.month, day: fields.day)
                )
                let foundation = try #require(
                    foundationDate(
                        of: DateFields(year: fields.year, month: fields.month, day: fields.day)
                    )
                )
                switch operation {
                    case .dayNumber:
                        #expect(
                            date.daysSinceEpoch * 86_400 == Int(foundation.timeIntervalSince1970)
                        )
                    case .dateOfDayNumber:
                        let number = try #draw(
                            DateGenerators.counts(in: firstFoundationDay...(lastWireDay + 366)),
                            from: tc
                        )
                        let expected = foundationFields(
                            of: Date(timeIntervalSince1970: Double(number) * 86_400)
                        )
                        try check(
                            MMDate.date(daysSinceEpoch: number).map(fields(of:)),
                            against: expected,
                            tc
                        )
                    case .days, .months, .years:
                        let unit: Calendar.Component
                        let range: ClosedRange<Int>
                        switch operation {
                            case .days:
                                (unit, range) = (
                                    .day,
                                    (firstFoundationDay - date.daysSinceEpoch)...(lastWireDay + 366
                                        - date.daysSinceEpoch)
                                )
                            case .months:
                                let month = date.year * 12 + date.month - 1
                                (unit, range) = (
                                    .month, (1583 * 12 - month)...(10_000 * 12 + 11 - month)
                                )
                            default:
                                (unit, range) = (.year, (1583 - date.year)...(10_000 - date.year))
                        }
                        let count = try #draw(DateGenerators.counts(in: range), from: tc)
                        let component: MMDateComponent =
                            switch operation {
                                case .days: .day(count)
                                case .months: .month(count)
                                default: .year(count)
                            }
                        let added = try #require(
                            utcCalendar.date(byAdding: unit, value: count, to: foundation)
                        )
                        try check(
                            date.adding(component).map(fields(of:)),
                            against: foundationFields(of: added),
                            tc
                        )
                    case .hours, .minutes, .seconds:
                        let dateTime = try #require(
                            MMDateTime(
                                date: date,
                                hour: fields.hour,
                                minute: fields.minute,
                                second: fields.second,
                                nanosecond: fields.nanosecond
                            )
                        )
                        let (unit, length): (Calendar.Component, Int) =
                            switch operation {
                                case .hours: (.hour, 3600)
                                case .minutes: (.minute, 60)
                                default: (.second, 1)
                            }
                        let start = try foundationSeconds(of: fields)
                        let fewest = -((start - firstFoundationDay * 86_400) / length)
                        let most = ((lastWireDay + 366) * 86_400 - start) / length
                        let count = try #draw(DateGenerators.counts(in: fewest...most), from: tc)
                        let component: MMDateComponent =
                            switch operation {
                                case .hours: .hour(count)
                                case .minutes: .minute(count)
                                default: .second(count)
                            }
                        let clock = try #require(foundationDate(of: fields))
                        let added = try #require(
                            utcCalendar.date(byAdding: unit, value: count, to: clock)
                        )
                        let result = dateTime.adding(component)
                        try check(
                            result.map(fields(of:)).map {
                                var f = $0; f.nanosecond = 0; return f
                            },
                            against: foundationFields(of: added),
                            tc
                        )
                        if let result { #expect(result.nanosecond == dateTime.nanosecond) }
                    case .instants:
                        let otherFields = try #draw(
                            DateGenerators.withClock(DateGenerators.foundationDates),
                            from: tc
                        )
                        let first = try #require(dateValue(of: fields, as: .timestamp))
                        let second = try #require(dateValue(of: otherFields, as: .timestamp))
                        guard case .timestamp(let left) = first, case .timestamp(let right) = second
                        else { return }
                        let leftSeconds = try foundationSeconds(of: fields, offset: fields.offset)
                        let rightSeconds = try foundationSeconds(
                            of: otherFields,
                            offset: otherFields.offset
                        )
                        #expect(left.secondsSinceEpoch.seconds == leftSeconds)
                        #expect(right.secondsSinceEpoch.seconds == rightSeconds)
                        let difference =
                            Duration.seconds(leftSeconds - rightSeconds)
                            + .nanoseconds(left.dateTime.nanosecond - right.dateTime.nanosecond)
                        #expect(left - right == difference)
                        let leftKey = (leftSeconds, left.dateTime.nanosecond, left.offsetMinutes)
                        let rightKey = (
                            rightSeconds, right.dateTime.nanosecond, right.offsetMinutes
                        )
                        #expect((left < right) == (leftKey < rightKey))
                }
            }
        }

        /// Checks a result against Foundation's: nil when Foundation's lands
        /// past 9999, the same fields otherwise.
        private func check(_ result: DateFields?, against expected: DateFields, _ tc: TestCase)
            throws
        {
            if expected.year > 9999 {
                try tc.event("past 9999")
                #expect(result == nil, "Foundation gives \(expected)")
            } else {
                #expect(result == expected)
            }
        }
    }

#endif

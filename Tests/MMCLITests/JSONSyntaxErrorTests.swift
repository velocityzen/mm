import Testing

@testable import MMCLI

/// What `JSONSyntaxError` accepts, the message for each problem, and how it
/// counts lines and columns. The messages are the same on every platform, so
/// they are checked whole.
@Suite("JSON syntax errors")
struct JSONSyntaxErrorTests {
    @Test("JSON, and what JSONDecoder also allows, has no error")
    func accepted() {
        let texts = [
            "null", "true", "false", "0", "-0", "0.5e-3", "1E+05", "1e400", "-12.75",
            #""""#, #""\u0000""#, #""😀""#, #""\/\b\f\n\r\t\"\\""#, "[]", "{}",
            "[1,]", #"{"a":1,}"#, #"{"a":1,"a":2}"#, "\u{FEFF}{}", " \t\r\n1 \r\n",
            String(repeating: "[", count: 128) + String(repeating: "]", count: 128),
        ]
        for text in texts {
            #expect(JSONSyntaxError.first(in: text) == nil, "\(text.debugDescription)")
        }
    }

    @Test("each problem says what is wrong and where")
    func messages() {
        let messages = [
            #"{"a": "abc"#: "Unterminated string at line 1, column 7.",
            "\"\\\t\"": "Invalid escape sequence '\\' followed by U+0009 at line 1, column 2.",
            #""\udc00""#: "Unpaired low surrogate '\\uDC00' at line 1, column 2.",
            #""\ud800A""#: "Unpaired high surrogate '\\uD800' at line 1, column 2.",
            #""\ud800x""#: "Unpaired high surrogate '\\uD800' at line 1, column 2.",
            "\"a\nb\"": "Unescaped control character U+000A in a string at line 1, column 3.",
            "[-01]": "Number with a leading zero at line 1, column 3.",
            String(repeating: "[", count: 129):
                "More than 128 arrays and objects nested in each other at line 1, column 129.",
            "1.": "Expected a digit, found the end of the text at line 1, column 3.",
            "-x": "Expected a digit, found 'x' at line 1, column 2.",
            "1.e5": "Expected a digit, found 'e' at line 1, column 3.",
            #""\u12G4""#:
                "Expected a hexadecimal digit in a '\\u' escape, found 'G' at line 1, column 6.",
            #"{"a":1 "b":2}"#: "Expected ',' or '}', found '\"' at line 1, column 8.",
            "[1 2]": "Expected ',' or ']', found '2' at line 1, column 4.",
            "{a:1}": "Expected a quoted key or '}', found 'a' at line 1, column 2.",
            #"{"a",1}"#: "Expected ':', found ',' at line 1, column 5.",
            "nul1": "Expected 'null', found '1' at line 1, column 4.",
            "[,]": "Expected a value or ']', found ',' at line 1, column 2.",
            "1 x": "Expected the end of the text, found 'x' at line 1, column 3.",
            "[1,\u{00A0}2]": "Expected a value or ']', found U+00A0 at line 1, column 4.",
            "[\u{301}]": "Expected a value or ']', found U+0301 at line 1, column 2.",
        ]
        for (text, message) in messages {
            #expect(
                JSONSyntaxError.first(in: text)?.description == message,
                "\(text.debugDescription)"
            )
        }
    }

    @Test("a line ends at LF, CRLF or a lone CR, and columns count scalars")
    func positions() {
        let positions = [
            "[\n x]": (line: 2, column: 2),
            "[\r\n x]": (line: 2, column: 2),
            "[\r x]": (line: 2, column: 2),
            "[\n\r\n\r x]": (line: 4, column: 2),
            "[\"é😀\", x]": (line: 1, column: 8),
            "\u{FEFF}x": (line: 1, column: 2),
        ]
        for (text, position) in positions {
            let error = JSONSyntaxError.first(in: text)
            #expect(error?.line == position.line, "\(text.debugDescription)")
            #expect(error?.column == position.column, "\(text.debugDescription)")
        }
    }
}

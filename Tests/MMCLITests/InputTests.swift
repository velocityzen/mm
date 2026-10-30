import ArgumentParser
import Foundation
import MMClient
import MMWire
import Synchronization
import Testing

@testable import MMCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// The byte stream behind `cli: .input`: its sources, the line splitter,
/// interruption, and the default one-call-per-line run.
@Suite("Input stream")
struct InputTests {
    @Test("lines split on LF and CRLF, keeping empty lines and an unterminated last line")
    func lines() async {
        #expect(await texts(MMCLIInput(text: "one\r\ntwo\n\nthree").lines) == ["one", "two", "", "three"])
        #expect(await texts(MMCLIInput(text: "only\n").lines) == ["only"])
        #expect(await texts(MMCLIInput(text: "").lines) == [])
        // Invalid UTF-8 decodes with replacement characters, never fails.
        #expect(await texts(MMCLIInput(bytes: [0x61, 0xFF, 0x0A]).lines) == ["a\u{FFFD}"])
    }

    @Test("a line over the limit fails once and ends the lines; a trailing CR doesn't count")
    func lineTooLong() async {
        let lines = MMCLIInput(text: "abc\r\nabcdef\nafter").lines(maximumLength: 3)
        #expect(await texts(lines) == ["abc", "! input line longer than 3 bytes"])
        let unterminated = MMCLIInput(text: "abcdef").lines(maximumLength: 3)
        #expect(await texts(unterminated) == ["! input line longer than 3 bytes"])
    }

    @Test("a file reads in chunks, with lines spanning chunk boundaries")
    func fileAcrossChunks() async throws {
        let expected = (0..<30_000).map { "line \($0)" }
        try await withTemporaryFile(expected.joined(separator: "\n") + "\n") { path in
            let withInput = MMCLIInputSource.file(path: path).open()
            let read = await withInput { input in
                .success(await texts(input.lines))
            }
            let lines = try read.get()
            #expect(lines == expected)
        }
    }

    @Test("an unreadable file fails acquire with exit 66")
    func unreadableFile() async {
        let path = NSTemporaryDirectory() + "mm-input-missing-\(UInt64.random(in: 0...UInt64.max))"
        let withInput = MMCLIInputSource.file(path: path).open()
        let read = await withInput { _ in .success(()) }
        guard case .failure(let error) = read, case .inputUnreadable(path, _) = error else {
            Issue.record("expected inputUnreadable, got \(read)")
            return
        }
        #expect(error.exitCode == ExitCode(66))
    }

    @Test("an interrupt ends a read parked on an idle pipe")
    func interruptParkedRead() async throws {
        try await withPipe { readEnd, _ in
            let input = MMCLIInput(descriptor: readEnd, name: "pipe")
            await withTaskGroup(of: [String].self) { tasks in
                tasks.addTask { await texts(input) }
                while input.reader.hasParkedRead == false {
                    await Task.yield()
                }
                input.interrupt()
                #expect(await tasks.next() == [])
            }
            #expect(input.isInterrupted)
        }
    }

    @Test("cancelling the reader ends a parked read")
    func cancelParkedRead() async throws {
        try await withPipe { readEnd, _ in
            let input = MMCLIInput(descriptor: readEnd, name: "pipe")
            await withTaskGroup(of: [String].self) { tasks in
                tasks.addTask { await texts(input) }
                while input.reader.hasParkedRead == false {
                    await Task.yield()
                }
                tasks.cancelAll()
                #expect(await tasks.next() == [])
            }
        }
    }

    @Test("lines already buffered are dropped once interrupted")
    func interruptDropsBufferedLines() async throws {
        let input = MMCLIInput(text: "a\nb\nc")
        var lines = input.lines.makeAsyncIterator()
        #expect(try await lines.next()?.get() == "a")
        input.interrupt()
        #expect(await lines.next() == nil)
    }

    @Test("a source is exactly one of the value and --input")
    func source() throws {
        #expect(try MMCLIInputSource.from(value: "x", path: nil, name: "term").get() == .value("x"))
        #expect(try MMCLIInputSource.from(value: nil, path: "-", name: "term").get() == .standardInput)
        #expect(try MMCLIInputSource.from(value: nil, path: "a.txt", name: "term").get() == .file(path: "a.txt"))
        #expect(throws: ValidationError.self) {
            try MMCLIInputSource.from(value: nil, path: nil, name: "term").get()
        }
        #expect(throws: ValidationError.self) {
            try MMCLIInputSource.from(value: "x", path: "-", name: "term").get()
        }
    }

    // MARK: - The default run

    @Test("the default run calls once per trimmed, non-blank line, in order")
    func defaultRunsEachLine() async {
        let seen = Seen()
        let code = await MMCLIInputRunner.batch(
            .standardInput,
            input: MMCLIInput(text: "  aphex twin \n\n\t\nburial\r\nboards"),
            call: seen.call(),
            format: .json
        )
        #expect(code == nil)
        #expect(seen.values == ["aphex twin", "burial", "boards"])
    }

    @Test("a value given on the command line is one call, verbatim")
    func defaultValueVerbatim() async {
        let seen = Seen()
        let code = await MMCLIInputRunner.batch(
            .value("  two\nlines "),
            input: MMCLIInput(text: "  two\nlines "),
            call: seen.call(),
            format: .json
        )
        #expect(code == nil)
        #expect(seen.values == ["  two\nlines "])
    }

    @Test("failures of one value let the run go on; the first code wins")
    func defaultContinuesPastValueFailures() async {
        let seen = Seen()
        let call = seen.call { value in
            switch value {
                case "bad": return .remote(MMError(code: 1000, message: "nope"))
                case "malformed": return .malformedParams
                default: return nil
            }
        }
        let code = await MMCLIInputRunner.batch(
            .standardInput, input: MMCLIInput(text: "a\nbad\nb\nmalformed\nc"), call: call, format: .json)
        #expect(code == ExitCode(1))
        #expect(seen.values == ["a", "bad", "b", "malformed", "c"])
    }

    @Test("a failure of the run, like a lost connection, ends it at once")
    func defaultStopsOnRunFailure() async {
        let seen = Seen()
        let call = seen.call { $0 == "b" ? .connectionClosed : nil }
        let code = await MMCLIInputRunner.batch(
            .standardInput, input: MMCLIInput(text: "a\nb\nc"), call: call, format: .json)
        #expect(code == ExitCode(69))
        #expect(seen.values == ["a", "b"])
    }

    @Test("an interrupt during a call ends the run after it, with 130")
    func interruptAfterCall() async throws {
        let seen = Seen()
        let input = MMCLIInput(text: "a\nb")
        let call = seen.call { _ in
            input.interrupt()
            return nil
        }
        let code = try await MMCLIInputRunner.interruptible(input) {
            await MMCLIInputRunner.batch(.standardInput, input: input, call: call, format: .json)
        }
        #expect(code == ExitCode(130))
        #expect(seen.values == ["a"])
    }
}

// MARK: - Helpers

/// Every line, or chunk as text; a failure reads `! <description>`.
func texts<Lines: AsyncSequence, Failure: Error>(
    _ sequence: Lines
) async -> [String] where Lines.Failure == Never, Lines.Element == Result<String, Failure> {
    var collected: [String] = []
    for await element in sequence {
        switch element {
            case .success(let text): collected.append(text)
            case .failure(let error): collected.append("! \(error.localizedDescription)")
        }
    }
    return collected
}

func texts(_ input: MMCLIInput) async -> [String] {
    await texts(input.map { $0.map { String(decoding: $0, as: UTF8.self) } })
}

/// The values calls saw, across their `@Sendable` boundary.
final class Seen: Sendable {
    private let storage = Mutex<[String]>([])

    var values: [String] { self.storage.withLock { $0 } }

    func add(_ value: String) { self.storage.withLock { $0.append(value) } }

    /// A call that records its value and fails with `failure(value)`, if any.
    func call(
        failing failure: @escaping @Sendable (String) -> MMCallError? = { _ in nil }
    ) -> MMCLIInputCall<SeenRequest, Int> {
        MMCLIInputCall(arguments: SeenRequest(value: ""), input: \.value) { request in
            self.add(request.value)
            guard let error = failure(request.value) else { return .success(request.value.count) }
            return .failure(.call(error, method: "test.call", entity: "test"))
        }
    }
}

/// The request of a ``Seen`` call: just the input field.
struct SeenRequest: Sendable {
    var value: String
}

func withTemporaryFile<T>(_ contents: String, _ body: (String) async throws -> T) async throws -> T {
    let path = NSTemporaryDirectory() + "mm-input-\(UInt64.random(in: 0...UInt64.max)).txt"
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    return try await body(path)
}

/// A pipe for the body; both ends are closed after it, the write end first
/// so a pool read still parked on the read end returns.
func withPipe(_ body: (CInt, CInt) async throws -> Void) async throws {
    var descriptors: [CInt] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw CLITestFailure(description: "pipe failed") }
    let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
    do {
        try await body(readEnd, writeEnd)
    } catch {
        _ = close(writeEnd)
        _ = close(readEnd)
        throw error
    }
    _ = close(writeEnd)
    _ = close(readEnd)
}

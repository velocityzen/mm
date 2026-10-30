#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// The bytes behind a `cli: .input` field, as an `AsyncSequence` of chunks.
/// They come from the command-line value itself, a file (`--input <path>`),
/// or standard input (`--input -`). An `Input(...)` body reads them however
/// it wants: as raw chunks, or as text `lines`. Elements are `Result`s, so
/// either feeds an FPPipe `FromResult(...)` source directly.
///
/// - Reads are pulled. Each `next()` reads one chunk of up to 64 KiB, so
///   nothing is read ahead of the consumer. The read runs on NIO's blocking
///   thread pool, never on a cooperative thread.
/// - A read failure arrives as one `.failure` element, then the sequence ends.
/// - The first Ctrl-C ends the sequence as if at end of file, and so does
///   cancelling the iterating task. A read still waiting for input is
///   abandoned at once, and `lines` drops the lines it has buffered.
/// - A file or stdin is read once. A second iteration continues where the
///   first stopped, which after the end yields nothing.
public struct MMCLIInput: AsyncSequence, Sendable {
    public typealias Element = Result<[UInt8], MMCLIError>
    public typealias Failure = Never

    enum Storage: Sendable {
        case bytes([UInt8])
        case descriptor(CInt, name: String)
    }

    let storage: Storage
    let reader: MMCLIInputReader

    init(storage: Storage) {
        self.storage = storage
        self.reader = MMCLIInputReader()
    }

    /// An input of these bytes, delivered as one chunk.
    public init(bytes: [UInt8]) {
        self.init(storage: .bytes(bytes))
    }

    /// An input of this text's UTF-8 bytes, delivered as one chunk. A value
    /// given on the command line reads this way.
    public init(text: String) {
        self.init(bytes: Array(text.utf8))
    }

    /// An input read from an open descriptor. `name` identifies it in errors.
    init(descriptor: CInt, name: String) {
        self.init(storage: .descriptor(descriptor, name: name))
    }

    /// Standard input, which is never closed.
    static var standardInput: MMCLIInput {
        MMCLIInput(descriptor: STDIN_FILENO, name: "stdin")
    }

    /// The input split into text lines, each at most 1 MiB; see
    /// ``lines(maximumLength:)``.
    public var lines: MMCLIInputLines {
        self.lines(maximumLength: 1 << 20)
    }

    /// The input split into text lines: on `\n`, with a trailing `\r`
    /// dropped, decoded as UTF-8 (invalid bytes become U+FFFD). Empty lines
    /// are kept, and a last line with no line break still counts. A line
    /// longer than `maximumLength` bytes arrives as
    /// ``MMCLIError/lineTooLong(limit:)``, and the lines end there.
    public func lines(maximumLength: Int) -> MMCLIInputLines {
        MMCLIInputLines(input: self, maximumLength: maximumLength)
    }

    /// Ends the input as if at end of file, abandoning a read in progress.
    func interrupt() {
        self.reader.interrupt()
    }

    /// Whether ``interrupt()`` ended the input.
    var isInterrupted: Bool {
        self.reader.isInterrupted
    }

    /// Closes the input's descriptor, once no read on it is still running.
    /// For the file bracket only: stdin is never closed.
    func close() async {
        guard case .descriptor(let descriptor, _) = self.storage else { return }
        await self.reader.settle()
        _ = systemClose(descriptor)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        switch self.storage {
            case .bytes(let bytes):
                return AsyncIterator(state: bytes.isEmpty ? .finished : .bytes(bytes), reader: self.reader)
            case .descriptor(let descriptor, let name):
                return AsyncIterator(state: .descriptor(descriptor, name: name), reader: self.reader)
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Failure = Never

        enum State {
            case bytes([UInt8])
            case descriptor(CInt, name: String)
            case finished
        }

        var state: State
        let reader: MMCLIInputReader

        /// Whether the input was interrupted: what was read but not yet
        /// consumed is dropped too.
        var isInterrupted: Bool {
            self.reader.isInterrupted
        }

        public mutating func next() async -> Result<[UInt8], MMCLIError>? {
            guard !self.reader.isInterrupted else {
                self.state = .finished
                return nil
            }
            switch self.state {
                case .finished:
                    return nil
                case .bytes(let bytes):
                    self.state = .finished
                    return .success(bytes)
                case .descriptor(let descriptor, let name):
                    switch await self.reader.nextChunk(from: descriptor) {
                        case .chunk(let bytes):
                            return .success(bytes)
                        case .end:
                            self.state = .finished
                            return nil
                        case .failed(let reason):
                            self.state = .finished
                            return .failure(.inputReadFailed(source: name, reason: reason))
                    }
            }
        }
    }
}

/// `close(2)`, out of reach of the `close()` member's name.
private func systemClose(_ descriptor: CInt) -> CInt {
    close(descriptor)
}

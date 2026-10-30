/// An ``MMCLIInput`` split into text lines; see
/// ``MMCLIInput/lines(maximumLength:)``. Like the input, its elements are
/// `Result`s: a read failure or an over-long line arrives as one `.failure`,
/// then the lines end.
public struct MMCLIInputLines: AsyncSequence, Sendable {
    public typealias Element = Result<String, MMCLIError>
    public typealias Failure = Never

    let input: MMCLIInput
    let maximumLength: Int

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: self.input.makeAsyncIterator(), maximumLength: self.maximumLength)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Failure = Never

        private static let lineFeed = UInt8(ascii: "\n")
        private static let carriageReturn = UInt8(ascii: "\r")

        var base: MMCLIInput.AsyncIterator
        let maximumLength: Int
        /// Bytes read but not yet returned as lines; `start` is the first.
        private var buffer: [UInt8] = []
        private var start = 0
        /// Where the search for the next line feed resumes.
        private var scanned = 0
        private var ended = false

        init(base: MMCLIInput.AsyncIterator, maximumLength: Int) {
            self.base = base
            self.maximumLength = maximumLength
        }

        public mutating func next() async -> Result<String, MMCLIError>? {
            // Interrupted: the buffered lines go unread with the rest.
            guard !self.base.isInterrupted else { return nil }
            while true {
                if let line = self.bufferedLine() {
                    return self.checked(line)
                }
                if self.ended {
                    guard let line = self.remainder() else { return nil }
                    return self.checked(line)
                }
                // No line break yet: the pending line may still end in `\r`.
                if self.buffer.count - self.start > self.maximumLength + 1 {
                    return self.fail(.lineTooLong(limit: self.maximumLength))
                }
                switch await self.base.next() {
                    case .success(let chunk)?:
                        self.append(chunk)
                    case .failure(let error)?:
                        return self.fail(error)
                    case nil:
                        self.ended = true
                }
            }
        }

        /// The next complete line in the buffer, without its line break.
        private mutating func bufferedLine() -> ArraySlice<UInt8>? {
            guard
                let lineFeed = self.buffer[self.scanned...].firstIndex(of: Self.lineFeed)
            else {
                self.scanned = self.buffer.count
                return nil
            }
            let line = self.buffer[self.start..<lineFeed]
            self.start = lineFeed + 1
            self.scanned = self.start
            return line
        }

        /// The last line, when the input does not end with a line break.
        private mutating func remainder() -> ArraySlice<UInt8>? {
            guard self.start < self.buffer.count else { return nil }
            let line = self.buffer[self.start...]
            self.start = self.buffer.count
            return line
        }

        private mutating func checked(_ line: ArraySlice<UInt8>) -> Result<String, MMCLIError> {
            let content = line.last == Self.carriageReturn ? line.dropLast() : line
            guard content.count <= self.maximumLength else {
                return self.fail(.lineTooLong(limit: self.maximumLength))
            }
            return .success(String(decoding: content, as: UTF8.self))
        }

        /// Ends the lines with one failure.
        private mutating func fail(_ error: MMCLIError) -> Result<String, MMCLIError> {
            self.ended = true
            self.buffer = []
            self.start = 0
            self.scanned = 0
            return .failure(error)
        }

        /// Appends a chunk, first dropping the lines already returned.
        private mutating func append(_ chunk: [UInt8]) {
            if self.start > 0 {
                self.buffer.removeFirst(self.start)
                self.scanned -= self.start
                self.start = 0
            }
            self.buffer.append(contentsOf: chunk)
        }
    }
}

/// The module's traverse: transform every element, short-circuiting on the
/// first failure. (Stated here once — MMSchema imports nothing, so the
/// combinator cannot come from a package.)
extension Sequence {
    func traverse<Value, Failure: Error>(
        _ transform: (Element) -> Result<Value, Failure>
    ) -> Result<[Value], Failure> {
        var collected: [Value] = []
        collected.reserveCapacity(self.underestimatedCount)
        for element in self {
            switch transform(element) {
                case .success(let value): collected.append(value)
                case .failure(let error): return .failure(error)
            }
        }
        return .success(collected)
    }
}

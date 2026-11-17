/// A stored property kept in a box on the heap, so that a struct can hold a
/// value of its own type.
///
/// Swift lays out a struct's stored properties inline, so a struct can't
/// hold itself: `struct Node { var parent: Node? }` has no finite size. A
/// property kept in a box has the size of one reference, whatever it holds.
/// `#schema` keeps a field in one when the field holds, through optionals
/// and nested structures, the type that declares it, directly or through
/// other declared types:
///
/// ```swift
/// Type("Node") {
///     Field("name", .string)
///     Field("parent", .optional("Node"))
/// }
/// ```
///
/// generates `@MMIndirect public var parent: Node?`. The property's type,
/// the initializer, equality, hashing and the wire bytes are the ones the
/// field would have without the box.
///
/// Copies share a box until one of them changes: a change puts the new value
/// in a new box, so it never reaches another copy. A box never changes once
/// made, which is what makes it `Sendable`.
@propertyWrapper
public struct MMIndirect<Value: Sendable>: Sendable {
    /// One value, never changed once boxed.
    private final class Box: Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private var box: Box

    public init(wrappedValue: Value) {
        self.box = Box(wrappedValue)
    }

    public var wrappedValue: Value {
        get { self.box.value }
        set { self.box = Box(newValue) }
    }
}

/// Equal when the boxed values are equal, as the property would be without
/// the box: no shortcut for a shared box, which would make a value holding
/// a NaN equal to itself.
extension MMIndirect: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}

/// Hashes the boxed value, as the property would without the box.
extension MMIndirect: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.wrappedValue)
    }
}

// Conditionally compiled like DateTimeFoundation.swift: `UUID` interop
// exists only where Foundation does, and nothing else about MMUUID touches
// it.
#if canImport(Foundation)
    import Foundation

    extension MMUUID {
        /// The identifier with the same 16 bytes as `uuid`.
        public init(_ uuid: UUID) {
            let value = uuid.uuid
            // Force unwrap: a `uuid_t` is 16 bytes by its type.
            self.init(
                bytes: [
                    value.0, value.1, value.2, value.3, value.4, value.5, value.6, value.7,
                    value.8, value.9, value.10, value.11, value.12, value.13, value.14, value.15,
                ]
            )!
        }

        /// The Foundation `UUID` with the same 16 bytes.
        public var uuid: UUID {
            let bytes = self.bytes
            return UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                    bytes[15]
                )
            )
        }
    }
#endif

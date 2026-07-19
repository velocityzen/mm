import NIOCore

/// Connection hello preamble: a fixed 15-byte binary layout — deliberately not
/// MessagePack, so it can be parsed before any coder state exists.
///
/// ```
/// offset  0-1   magic 0x4D 0x4D ("MM")
/// offset  2     protocolVersion   UInt8
/// offset  3-10  schemaFingerprint UInt64 little-endian
/// offset 11-14  capabilities      UInt32 little-endian
/// ```
///
/// Forward compatibility: decoding reads exactly the first 15 readable bytes and
/// tolerates (ignores) any trailing bytes, so a future version may append fields to
/// its hello without breaking older peers. Decoding does not consume input.
///
/// Version negotiation itself (min-wins) and the fingerprint-mismatch → discovery
/// policy belong to higher layers; this type is pure layout.
public struct MMHello: Equatable, Sendable {
    /// The two magic bytes, "MM".
    public static let magic: [UInt8] = [0x4d, 0x4d]
    /// The fixed encoded size in bytes.
    public static let encodedByteCount = 15

    public var protocolVersion: UInt8
    public var schemaFingerprint: UInt64
    public var capabilities: UInt32

    public init(protocolVersion: UInt8, schemaFingerprint: UInt64, capabilities: UInt32) {
        self.protocolVersion = protocolVersion
        self.schemaFingerprint = schemaFingerprint
        self.capabilities = capabilities
    }

    /// Writes the fixed 15-byte layout into `buffer`. Cannot fail.
    public func encode(into buffer: inout ByteBuffer) {
        buffer.writeBytes(Self.magic)
        buffer.writeInteger(self.protocolVersion)
        buffer.writeInteger(self.schemaFingerprint, endianness: .little)
        buffer.writeInteger(self.capabilities, endianness: .little)
    }

    /// Encodes into a fresh buffer. The `Result` is for signature uniformity with the
    /// rest of the wire layer; encoding a fixed layout cannot fail in this version.
    public func encode() -> Result<ByteBuffer, MMWireError> {
        var buffer = ByteBuffer()
        buffer.reserveCapacity(Self.encodedByteCount)
        self.encode(into: &buffer)
        return .success(buffer)
    }

    /// Decodes a hello from the first 15 readable bytes of `buffer` without consuming
    /// them. Trailing extra bytes are tolerated and ignored (forward compatibility).
    ///
    /// Failure order: fewer than 2 readable bytes is `.truncated`; a wrong magic is
    /// `.badMagic` (checked as soon as both magic bytes are present, even if the rest
    /// is short); otherwise fewer than 15 readable bytes is `.truncated`.
    public static func decode(from buffer: ByteBuffer) -> Result<MMHello, MMWireError> {
        let base = buffer.readerIndex
        guard buffer.readableBytes >= 2 else { return .failure(.truncated) }
        guard
            buffer.getInteger(at: base, as: UInt8.self) == Self.magic[0],
            buffer.getInteger(at: base + 1, as: UInt8.self) == Self.magic[1]
        else {
            return .failure(.badMagic)
        }
        // One consecutive little-endian read of the whole 15-byte layout
        // (magic re-read and discarded); nil = not all 15 bytes arrived.
        guard let fields = buffer.peekMultipleIntegers(
            endianness: .little,
            as: (UInt8, UInt8, UInt8, UInt64, UInt32).self
        ) else {
            return .failure(.truncated)
        }
        
        return .success(
            MMHello(
                protocolVersion: fields.2,
                schemaFingerprint: fields.3,
                capabilities: fields.4
            )
        )
    }
}

/// The hello-negotiation math — fixed wire decisions stated once for both
/// sides: version is **min-wins**, capabilities are the **bitwise
/// intersection**.
package enum HelloNegotiation {
    package struct Negotiated: Sendable, Hashable {
        package var protocolVersion: UInt8
        package var capabilities: UInt32

        package init(protocolVersion: UInt8, capabilities: UInt32) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
        }
    }

    package static func negotiate(
        localVersion: UInt8, localCapabilities: UInt32, remote: MMHello
    ) -> Negotiated {
        Negotiated(
            protocolVersion: min(localVersion, remote.protocolVersion),
            capabilities: localCapabilities & remote.capabilities
        )
    }

    package static func negotiate(server: MMHello, client: MMHello) -> Negotiated {
        negotiate(
            localVersion: server.protocolVersion,
            localCapabilities: server.capabilities,
            remote: client
        )
    }
}

import MMSchema
import MMWire
import NIOCore

/// The echo fixture pair shared by the server and integration suites: a
/// request carrying its target entity plus a value, echoed back.
public struct EchoRequest: Codable, Hashable, Sendable {
    public var entity: EntityName
    public var value: Int

    public init(entity: EntityName, value: Int) {
        self.entity = entity
        self.value = value
    }

    enum CodingKeys: Int, CodingKey {
        case entity = 0
        case value = 1
    }
}

public struct EchoResponse: Codable, Hashable, Sendable {
    public var value: Int

    public init(value: Int) {
        self.value = value
    }

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }
}

/// MMPack-encodes a params/result payload for a hand-built envelope.
public func encodedParams<T: Encodable>(_ value: T) -> ByteBuffer {
    try! MMPackEncoder().encode(value).get()
}

/// A hand-built request envelope around an encodable params payload.
public func request<T: Encodable>(
    msgid: UInt32 = 1, method: String, entity: EntityName = .root, _ body: T
) -> MMEnvelope {
    .request(msgid: msgid, method: method, entity: entity.rawValue, params: encodedParams(body))
}

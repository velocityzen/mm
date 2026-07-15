/// MMWire — MessagePack coder over `ByteBuffer`, length-prefix framing, and the RPC envelope.
public enum MMWireInfo {
    /// Wire protocol version carried in the hello preamble.
    public static let protocolVersion: UInt8 = 1

    /// Default maximum frame payload length: 16 MiB. Configurable per endpoint on
    /// `MMFrameDecoder` / `MMFrameEncoder`.
    public static let defaultMaxFrameLength: UInt32 = 16 * 1024 * 1024
}

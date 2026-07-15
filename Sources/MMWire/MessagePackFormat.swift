/// MessagePack format-byte constants.
///
/// Multi-byte payloads (lengths, integer bodies, float bit patterns) are big-endian
/// per the MessagePack spec. Only the frame length prefix — owned by the framing
/// layer, not this file — is little-endian.
enum MPFormat {
    static let positiveFixintMax: UInt8 = 0x7f
    static let fixmapBase: UInt8 = 0x80  // 0x80...0x8f
    static let fixarrayBase: UInt8 = 0x90  // 0x90...0x9f
    static let fixstrBase: UInt8 = 0xa0  // 0xa0...0xbf
    static let nilByte: UInt8 = 0xc0
    static let neverUsed: UInt8 = 0xc1
    static let falseByte: UInt8 = 0xc2
    static let trueByte: UInt8 = 0xc3
    static let bin8: UInt8 = 0xc4
    static let bin16: UInt8 = 0xc5
    static let bin32: UInt8 = 0xc6
    static let ext8: UInt8 = 0xc7
    static let ext16: UInt8 = 0xc8
    static let ext32: UInt8 = 0xc9
    static let float32: UInt8 = 0xca
    static let float64: UInt8 = 0xcb
    static let uint8: UInt8 = 0xcc
    static let uint16: UInt8 = 0xcd
    static let uint32: UInt8 = 0xce
    static let uint64: UInt8 = 0xcf
    static let int8: UInt8 = 0xd0
    static let int16: UInt8 = 0xd1
    static let int32: UInt8 = 0xd2
    static let int64: UInt8 = 0xd3
    static let fixext1: UInt8 = 0xd4
    static let fixext2: UInt8 = 0xd5
    static let fixext4: UInt8 = 0xd6
    static let fixext8: UInt8 = 0xd7
    static let fixext16: UInt8 = 0xd8
    static let str8: UInt8 = 0xd9
    static let str16: UInt8 = 0xda
    static let str32: UInt8 = 0xdb
    static let array16: UInt8 = 0xdc
    static let array32: UInt8 = 0xdd
    static let map16: UInt8 = 0xde
    static let map32: UInt8 = 0xdf
    static let negativeFixintBase: UInt8 = 0xe0  // 0xe0...0xff

    /// True for every format in the integer family (fixints, uint8...64, int8...64).
    static func isInteger(_ format: UInt8) -> Bool {
        switch format {
            case 0x00...0x7f, 0xcc...0xcf, 0xd0...0xd3, 0xe0...0xff: return true
            default: return false
        }
    }

    /// True for every format in the str family (fixstr, str8/16/32).
    static func isString(_ format: UInt8) -> Bool {
        switch format {
            case 0xa0...0xbf, 0xd9...0xdb: return true
            default: return false
        }
    }
}

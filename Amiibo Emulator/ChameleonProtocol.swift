import Foundation

struct ChameleonResponse: Equatable {
    let command: UInt16
    let status: UInt16
    let payload: Data
}

enum ChameleonProtocolError: Error, Equatable {
    case frameTooShort
    case invalidPreamble
    case payloadTooLarge(Int)
    case invalidFrameLength(expected: Int, actual: Int)
    case invalidHeaderChecksum
    case invalidPayloadChecksum
}

enum ChameleonProtocol {
    static let successStatus: UInt16 = 0x0068
    static let maximumPayloadLength = 512

    static func encodeRequest(command: UInt16, payload: Data = Data()) throws -> Data {
        guard payload.count <= maximumPayloadLength else {
            throw ChameleonProtocolError.payloadTooLarge(payload.count)
        }

        let length = UInt16(payload.count)
        var frame = Data([
            0x11,
            0xEF,
            UInt8(command >> 8),
            UInt8(command & 0xFF),
            0x00,
            0x00,
            UInt8(length >> 8),
            UInt8(length & 0xFF)
        ])
        frame.append(lrc(for: frame[2..<8]))
        frame.append(payload)
        frame.append(lrc(for: payload))
        return frame
    }

    static func decodeResponse(_ frame: Data) throws -> ChameleonResponse {
        guard frame.count >= 10 else {
            throw ChameleonProtocolError.frameTooShort
        }
        guard frame[0] == 0x11, frame[1] == 0xEF else {
            throw ChameleonProtocolError.invalidPreamble
        }

        let payloadLength = Int(readUInt16(frame, at: 6))
        guard payloadLength <= maximumPayloadLength else {
            throw ChameleonProtocolError.payloadTooLarge(payloadLength)
        }

        let expectedLength = payloadLength + 10
        guard frame.count == expectedLength else {
            throw ChameleonProtocolError.invalidFrameLength(
                expected: expectedLength,
                actual: frame.count
            )
        }
        guard frame[8] == lrc(for: frame[2..<8]) else {
            throw ChameleonProtocolError.invalidHeaderChecksum
        }

        let payload = frame.subdata(in: 9..<(9 + payloadLength))
        guard frame[9 + payloadLength] == lrc(for: payload) else {
            throw ChameleonProtocolError.invalidPayloadChecksum
        }

        return ChameleonResponse(
            command: readUInt16(frame, at: 2),
            status: readUInt16(frame, at: 4),
            payload: payload
        )
    }

    static func payloadLength(inHeader data: Data) -> Int? {
        guard data.count >= 8 else { return nil }
        return Int(readUInt16(data, at: 6))
    }

    private static func lrc<C: Collection>(for bytes: C) -> UInt8 where C.Element == UInt8 {
        let sum = bytes.reduce(UInt8.zero) { $0 &+ $1 }
        return 0 &- sum
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}

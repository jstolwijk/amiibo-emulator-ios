import Foundation

nonisolated struct ValidatedAmiiboDump: Equatable, Sendable {
    static let byteCount = 540

    let data: Data
    let uid: Data
    let hasUnexpectedManufacturer: Bool

    func dataWithAuthenticationPages() throws -> Data {
        guard data.count == Self.byteCount, uid.count == 7 else {
            throw AmiiboDumpValidationError.invalidValidatedDump
        }

        var authenticatedData = data
        let password: [UInt8] = [
            0xAA ^ uid[1] ^ uid[3],
            0x55 ^ uid[2] ^ uid[4],
            0xAA ^ uid[3] ^ uid[5],
            0x55 ^ uid[4] ^ uid[6]
        ]
        authenticatedData.replaceSubrange(532..<536, with: password)
        authenticatedData.replaceSubrange(536..<540, with: [0x80, 0x80, 0x00, 0x00])
        return authenticatedData
    }
}

nonisolated enum AmiiboDumpValidationError: LocalizedError, Equatable {
    case invalidSize(actual: Int)
    case invalidBCC0(expected: UInt8, actual: UInt8)
    case invalidBCC1(expected: UInt8, actual: UInt8)
    case invalidDynamicLockPage
    case invalidConfigurationPages
    case nonPlaceholderAuthenticationPages
    case invalidValidatedDump

    var errorDescription: String? {
        switch self {
        case .invalidSize(let actual):
            "Expected a 540-byte NTAG215 dump, found \(actual) bytes."
        case .invalidBCC0(let expected, let actual):
            "Invalid UID check byte BCC0: expected \(expected.hex), found \(actual.hex)."
        case .invalidBCC1(let expected, let actual):
            "Invalid UID check byte BCC1: expected \(expected.hex), found \(actual.hex)."
        case .invalidDynamicLockPage:
            "Unexpected NTAG215 dynamic lock page at page 130."
        case .invalidConfigurationPages:
            "Unexpected NTAG215 configuration pages 131-132."
        case .nonPlaceholderAuthenticationPages:
            "PWD/PACK pages must contain unreadable zero placeholders."
        case .invalidValidatedDump:
            "The validated dump no longer has the expected NTAG215 structure."
        }
    }
}

nonisolated enum AmiiboDumpValidator {
    static func validate(_ data: Data) throws -> ValidatedAmiiboDump {
        guard data.count == ValidatedAmiiboDump.byteCount else {
            throw AmiiboDumpValidationError.invalidSize(actual: data.count)
        }

        let expectedBCC0 = 0x88 ^ data[0] ^ data[1] ^ data[2]
        guard data[3] == expectedBCC0 else {
            throw AmiiboDumpValidationError.invalidBCC0(
                expected: expectedBCC0,
                actual: data[3]
            )
        }

        let expectedBCC1 = data[4] ^ data[5] ^ data[6] ^ data[7]
        guard data[8] == expectedBCC1 else {
            throw AmiiboDumpValidationError.invalidBCC1(
                expected: expectedBCC1,
                actual: data[8]
            )
        }

        guard data[520..<524].elementsEqual([0x01, 0x00, 0x0F, 0xBD]) else {
            throw AmiiboDumpValidationError.invalidDynamicLockPage
        }
        guard data[524..<528].elementsEqual([0x00, 0x00, 0x00, 0x04]),
              data[528..<532].elementsEqual([0x5F, 0x00, 0x00, 0x00]) else {
            throw AmiiboDumpValidationError.invalidConfigurationPages
        }
        guard data[532..<540].allSatisfy({ $0 == 0 }) else {
            throw AmiiboDumpValidationError.nonPlaceholderAuthenticationPages
        }

        let uid = Data([data[0], data[1], data[2], data[4], data[5], data[6], data[7]])
        return ValidatedAmiiboDump(
            data: data,
            uid: uid,
            hasUnexpectedManufacturer: data[0] != 0x04
        )
    }
}

nonisolated private extension UInt8 {
    var hex: String {
        String(format: "%02X", self)
    }
}

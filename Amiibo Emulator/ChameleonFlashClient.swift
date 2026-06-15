import Foundation

struct FlashProgress: Equatable {
    enum Stage: Equatable {
        case preflight
        case backup
        case writing
        case configuring
        case verifying
        case rollback
        case complete
    }

    let stage: Stage
    let message: String
    let completedUnits: Int
    let totalUnits: Int

    var fractionCompleted: Double {
        guard totalUnits > 0 else { return 0 }
        return Double(completedUnits) / Double(totalUnits)
    }
}

struct NtagBackup: Codable, Equatable {
    let slot: Int
    let hfType: UInt16
    let hfEnabled: Bool
    let hfNickname: String
    let uid: Data
    let atqa: Data
    let sak: UInt8
    let ats: Data
    let uidMagic: Bool
    let writeMode: UInt8
    let detectionEnabled: Bool
    let counter: UInt32
    let counterTearing: Bool
    let versionData: Data
    let signatureData: Data
    let pages: Data
}

enum ChameleonFlashError: LocalizedError {
    case invalidSlot
    case unsupportedFirmware(String)
    case invalidBoolean(command: UInt16, value: UInt8)
    case invalidAntiCollision
    case invalidWriteMode(UInt8)
    case verification(String)
    case rollbackFailed(operation: Error, rollback: Error, recoveryURL: URL?)

    var errorDescription: String? {
        switch self {
        case .invalidSlot:
            return "The selected slot is outside the supported range."
        case .unsupportedFirmware(let version):
            return "Firmware \(version) is unsupported. Firmware major version 2 is required."
        case .invalidBoolean(let command, let value):
            return "Command \(command) returned invalid boolean value \(value)."
        case .invalidAntiCollision:
            return "The device returned invalid anti-collision data."
        case .invalidWriteMode(let value):
            return "The device returned invalid NTAG write mode \(value)."
        case .verification(let message):
            return "Verification failed: \(message)"
        case .rollbackFailed(let operation, let rollback, let recoveryURL):
            var message = "\(operation.localizedDescription) Rollback also failed: \(rollback.localizedDescription)"
            if let recoveryURL {
                message += " Recovery data was preserved at \(recoveryURL.lastPathComponent)."
            }
            return message
        }
    }
}

@MainActor
final class ChameleonFlashClient {
    typealias ProgressHandler = (FlashProgress) -> Void

    private enum Command {
        static let getAppVersion: UInt16 = 1000
        static let setActiveSlot: UInt16 = 1003
        static let setSlotTagType: UInt16 = 1004
        static let setSlotDataDefault: UInt16 = 1005
        static let setSlotEnable: UInt16 = 1006
        static let setSlotNickname: UInt16 = 1007
        static let getSlotNickname: UInt16 = 1008
        static let saveSlotConfiguration: UInt16 = 1009
        static let getActiveSlot: UInt16 = 1018
        static let getSlotInfo: UInt16 = 1019
        static let getEnabledSlots: UInt16 = 1023
        static let deleteSlotSenseType: UInt16 = 1024
        static let setAntiCollision: UInt16 = 4001
        static let getAntiCollision: UInt16 = 4018
        static let getUIDMagic: UInt16 = 4019
        static let setUIDMagic: UInt16 = 4020
        static let readPages: UInt16 = 4021
        static let writePages: UInt16 = 4022
        static let getVersionData: UInt16 = 4023
        static let setVersionData: UInt16 = 4024
        static let getSignatureData: UInt16 = 4025
        static let setSignatureData: UInt16 = 4026
        static let getCounterData: UInt16 = 4027
        static let setCounterData: UInt16 = 4028
        static let getPageCount: UInt16 = 4030
        static let getWriteMode: UInt16 = 4031
        static let setWriteMode: UInt16 = 4032
        static let setDetectionEnabled: UInt16 = 4033
        static let getDetectionEnabled: UInt16 = 4036
    }

    private static let ntag215Type: UInt16 = 1101
    private let transport: ChameleonBluetoothManager

    init(transport: ChameleonBluetoothManager) {
        self.transport = transport
    }

    func clearAllSlots(progress: @escaping ProgressHandler) async throws {
        try await requireCompatibleFirmware()

        let totalOperations = 8 * 2
        var completedOperations = 0

        for slot in 0..<8 {
            progress(.init(
                stage: .configuring,
                message: "Clearing slot \(slot + 1) of 8...",
                completedUnits: completedOperations,
                totalUnits: totalOperations
            ))

            for senseType: UInt8 in [1, 2] {
                try await command(
                    Command.deleteSlotSenseType,
                    payload: Data([UInt8(slot), senseType])
                )
                completedOperations += 1
            }
        }

        try await command(Command.saveSlotConfiguration)

        let slotTypes = try await command(
            Command.getSlotInfo,
            expected: 32...32,
            retryCount: 2
        )
        guard slotTypes.allSatisfy({ $0 == 0 }) else {
            throw ChameleonFlashError.verification("one or more slots could not be cleared.")
        }

        progress(.init(
            stage: .complete,
            message: "All slots cleared.",
            completedUnits: totalOperations,
            totalUnits: totalOperations
        ))
    }

    func flash(
        slot: ChameleonSlot,
        dump: ValidatedAmiiboDump,
        nickname: String,
        progress: @escaping ProgressHandler
    ) async throws {
        guard (0..<8).contains(slot.id) else {
            throw ChameleonFlashError.invalidSlot
        }

        progress(.init(stage: .preflight, message: "Checking device and slot...", completedUnits: 0, totalUnits: 1))
        let originalActiveSlot = try await readActiveSlot()
        try await requireCompatibleFirmware()
        let currentSlot = try await readSlotMetadata(slot: slot.id)
        guard currentSlot.hfType == slot.hfType else {
            throw ChameleonFlashError.verification(
                "slot \(slot.id + 1) changed after confirmation; refresh slots and try again."
            )
        }

        var backup: NtagBackup?
        if Self.isNtagFamily(currentSlot.hfType) {
            progress(.init(stage: .backup, message: "Backing up slot \(slot.id + 1)...", completedUnits: 0, totalUnits: 1))
            backup = try await captureBackup(slot: currentSlot, restoreActiveSlot: originalActiveSlot)
        }

        do {
            try await program(
                slot: slot.id,
                dump: dump,
                nickname: Self.truncatedNickname(nickname),
                progress: progress
            )
        } catch {
            progress(.init(stage: .rollback, message: "Restoring previous slot state...", completedUnits: 0, totalUnits: 1))
            if let backup {
                do {
                    try await restore(backup, activeSlot: originalActiveSlot, verify: true)
                } catch let rollbackError {
                    let recoveryURL = try? persistRecovery(backup)
                    throw ChameleonFlashError.rollbackFailed(
                        operation: error,
                        rollback: rollbackError,
                        recoveryURL: recoveryURL
                    )
                }
            } else {
                _ = try? await command(Command.setSlotEnable, payload: Data([UInt8(slot.id), 2, 0]))
                _ = try? await command(Command.setActiveSlot, payload: Data([UInt8(originalActiveSlot)]))
            }
            throw error
        }

        progress(.init(stage: .complete, message: "Flash verified.", completedUnits: 1, totalUnits: 1))
    }

    private func program(
        slot: Int,
        dump: ValidatedAmiiboDump,
        nickname: String,
        progress: @escaping ProgressHandler
    ) async throws {
        let pages = try dump.dataWithAuthenticationPages()
        let typePayload = Data([UInt8(slot), UInt8(Self.ntag215Type >> 8), UInt8(Self.ntag215Type & 0xFF)])

        progress(.init(stage: .writing, message: "Preparing NTAG215...", completedUnits: 0, totalUnits: 9))
        try await command(Command.setSlotTagType, payload: typePayload)
        try await command(Command.setSlotDataDefault, payload: typePayload)
        try await command(Command.setActiveSlot, payload: Data([UInt8(slot)]))

        let batches = Array(pages.chunks(ofCount: 64))
        for (index, batch) in batches.enumerated() {
            let startPage = index * 16
            var payload = Data([UInt8(startPage), UInt8(batch.count / 4)])
            payload.append(batch)
            try await command(Command.writePages, payload: payload, timeout: 5)
            progress(.init(
                stage: .writing,
                message: "Writing pages \(startPage + 1)-\(startPage + batch.count / 4) of 135...",
                completedUnits: index + 1,
                totalUnits: batches.count
            ))
        }

        progress(.init(stage: .configuring, message: "Configuring Amiibo emulation...", completedUnits: 0, totalUnits: 6))
        try await setAntiCollision(uid: dump.uid, atqa: Data([0x44, 0x00]), sak: 0, ats: Data())
        try await command(Command.setUIDMagic, payload: Data([0]))
        try await command(Command.setWriteMode, payload: Data([0]))
        try await command(
            Command.setSlotNickname,
            payload: Data([UInt8(slot), 2]) + Data(nickname.utf8)
        )
        try await command(Command.setSlotEnable, payload: Data([UInt8(slot), 2, 1]))
        try await command(Command.saveSlotConfiguration)

        progress(.init(stage: .verifying, message: "Reading all 135 pages back...", completedUnits: 0, totalUnits: 1))
        try await verifyNtag215(slot: slot, pages: pages, uid: dump.uid, nickname: nickname)
    }

    private func verifyNtag215(slot: Int, pages: Data, uid: Data, nickname: String) async throws {
        let pageCount = try await command(Command.getPageCount, expected: 1...1, retryCount: 2)[0]
        guard pageCount == 135 else {
            throw ChameleonFlashError.verification("device reports \(pageCount) pages instead of 135.")
        }
        guard try await readAllPages(pageCount: pageCount) == pages else {
            throw ChameleonFlashError.verification("the complete page read-back differs from the selected dump.")
        }

        let anti = try parseAntiCollision(
            try await command(Command.getAntiCollision, expected: 5...265, retryCount: 2)
        )
        guard anti.uid == uid, anti.atqa == Data([0x44, 0]), anti.sak == 0, anti.ats.isEmpty else {
            throw ChameleonFlashError.verification("anti-collision settings do not match Amiibo settings.")
        }
        guard try await readBool(Command.getUIDMagic) == false else {
            throw ChameleonFlashError.verification("UID-magic mode remained enabled.")
        }
        guard try await command(Command.getWriteMode, expected: 1...1, retryCount: 2)[0] == 0 else {
            throw ChameleonFlashError.verification("write mode is not NORMAL.")
        }

        let types = try await command(Command.getSlotInfo, expected: 32...32, retryCount: 2)
        let enabled = try await command(Command.getEnabledSlots, expected: 16...16, retryCount: 2)
        let offset = slot * 4
        let actualType = (UInt16(types[offset]) << 8) | UInt16(types[offset + 1])
        guard actualType == Self.ntag215Type, enabled[slot * 2] != 0 else {
            throw ChameleonFlashError.verification("slot type or HF enablement is incorrect.")
        }
        guard try await readNickname(slot: slot, senseType: 2) == nickname else {
            throw ChameleonFlashError.verification("slot nickname does not match.")
        }
    }

    private func captureBackup(
        slot: ChameleonSlot,
        restoreActiveSlot: Int
    ) async throws -> NtagBackup {
        let hfNickname = try await readNickname(slot: slot.id, senseType: 2)
        try await command(Command.setActiveSlot, payload: Data([UInt8(slot.id)]))

        do {
            let backup = try await readActiveBackup(slot: slot, hfNickname: hfNickname)
            try await command(Command.setActiveSlot, payload: Data([UInt8(restoreActiveSlot)]))
            return backup
        } catch {
            _ = try? await command(Command.setActiveSlot, payload: Data([UInt8(restoreActiveSlot)]))
            throw error
        }
    }

    private func readActiveBackup(slot: ChameleonSlot, hfNickname: String) async throws -> NtagBackup {
        let anti = try parseAntiCollision(
            try await command(Command.getAntiCollision, expected: 5...265, retryCount: 2)
        )
        let uidMagic = try await readBool(Command.getUIDMagic)
        let writeMode = try await command(Command.getWriteMode, expected: 1...1, retryCount: 2)[0]
        guard writeMode <= 4 else {
            throw ChameleonFlashError.invalidWriteMode(writeMode)
        }
        let detectionEnabled = try await readBool(Command.getDetectionEnabled)
        let versionData = try await command(Command.getVersionData, expected: 8...8, retryCount: 2)
        let signatureData = try await command(Command.getSignatureData, expected: 32...32, retryCount: 2)
        let counterData = try await command(Command.getCounterData, payload: Data([0]), expected: 4...4, retryCount: 2)
        let counter = UInt32(counterData[0]) | (UInt32(counterData[1]) << 8) | (UInt32(counterData[2]) << 16)
        let counterTearing: Bool
        switch counterData[3] {
        case 0xBD: counterTearing = false
        case 0x00: counterTearing = true
        default: throw ChameleonFlashError.verification("the NTAG counter tearing byte is invalid.")
        }
        let pageCount = try await command(Command.getPageCount, expected: 1...1, retryCount: 2)[0]
        let pages = try await readAllPages(pageCount: pageCount)

        return NtagBackup(
            slot: slot.id,
            hfType: slot.hfType,
            hfEnabled: slot.hfEnabled,
            hfNickname: hfNickname,
            uid: anti.uid,
            atqa: anti.atqa,
            sak: anti.sak,
            ats: anti.ats,
            uidMagic: uidMagic,
            writeMode: writeMode,
            detectionEnabled: detectionEnabled,
            counter: counter,
            counterTearing: counterTearing,
            versionData: versionData,
            signatureData: signatureData,
            pages: pages
        )
    }

    private func restore(_ backup: NtagBackup, activeSlot: Int, verify: Bool) async throws {
        let typePayload = Data([
            UInt8(backup.slot),
            UInt8(backup.hfType >> 8),
            UInt8(backup.hfType & 0xFF)
        ])
        try await command(Command.setSlotTagType, payload: typePayload)
        try await command(Command.setSlotDataDefault, payload: typePayload)
        try await command(Command.setActiveSlot, payload: Data([UInt8(backup.slot)]))
        try await writeAllPages(backup.pages)
        try await setAntiCollision(uid: backup.uid, atqa: backup.atqa, sak: backup.sak, ats: backup.ats)
        try await command(Command.setVersionData, payload: backup.versionData)
        try await command(Command.setSignatureData, payload: backup.signatureData)
        try await command(Command.setCounterData, payload: Data([
            0x80,
            UInt8(backup.counter & 0xFF),
            UInt8((backup.counter >> 8) & 0xFF),
            UInt8((backup.counter >> 16) & 0xFF)
        ]))
        try await command(Command.setUIDMagic, payload: Data([backup.uidMagic ? 1 : 0]))
        try await command(Command.setWriteMode, payload: Data([backup.writeMode]))
        try await command(Command.setDetectionEnabled, payload: Data([backup.detectionEnabled ? 1 : 0]))
        try await command(
            Command.setSlotNickname,
            payload: Data([UInt8(backup.slot), 2]) + Data(backup.hfNickname.utf8)
        )
        try await command(
            Command.setSlotEnable,
            payload: Data([UInt8(backup.slot), 2, backup.hfEnabled ? 1 : 0])
        )
        try await command(Command.saveSlotConfiguration)

        if verify {
            let slot = try await readSlotMetadata(slot: backup.slot)
            let actual = try await readActiveBackup(slot: slot, hfNickname: backup.hfNickname)
            // Firmware can restore the counter value but not an interrupted-write marker.
            // Normalize that marker while preserving all meaningful slot data.
            guard actual == normalizedForRestore(backup) else {
                throw ChameleonFlashError.verification("restored NTAG state did not match its backup.")
            }
        }
        try await command(Command.setActiveSlot, payload: Data([UInt8(activeSlot)]))
    }

    private func normalizedForRestore(_ backup: NtagBackup) -> NtagBackup {
        NtagBackup(
            slot: backup.slot,
            hfType: backup.hfType,
            hfEnabled: backup.hfEnabled,
            hfNickname: backup.hfNickname,
            uid: backup.uid,
            atqa: backup.atqa,
            sak: backup.sak,
            ats: backup.ats,
            uidMagic: backup.uidMagic,
            writeMode: backup.writeMode,
            detectionEnabled: backup.detectionEnabled,
            counter: backup.counter,
            counterTearing: false,
            versionData: backup.versionData,
            signatureData: backup.signatureData,
            pages: backup.pages
        )
    }

    private func writeAllPages(_ pages: Data) async throws {
        for (index, batch) in pages.chunks(ofCount: 64).enumerated() {
            var payload = Data([UInt8(index * 16), UInt8(batch.count / 4)])
            payload.append(batch)
            try await command(Command.writePages, payload: payload, timeout: 5)
        }
    }

    private func readAllPages(pageCount: UInt8) async throws -> Data {
        var result = Data()
        var page: UInt8 = 0
        while page < pageCount {
            let count = min(pageCount - page, 32)
            result.append(try await command(
                Command.readPages,
                payload: Data([page, count]),
                expected: Int(count) * 4...Int(count) * 4,
                timeout: 5,
                retryCount: 2
            ))
            page += count
        }
        return result
    }

    private func setAntiCollision(uid: Data, atqa: Data, sak: UInt8, ats: Data) async throws {
        var payload = Data([UInt8(uid.count)])
        payload.append(uid)
        payload.append(atqa)
        payload.append(sak)
        payload.append(UInt8(ats.count))
        payload.append(ats)
        try await command(Command.setAntiCollision, payload: payload)
    }

    private func parseAntiCollision(_ payload: Data) throws
        -> (uid: Data, atqa: Data, sak: UInt8, ats: Data) {
        guard let uidLengthByte = payload.first else {
            throw ChameleonFlashError.invalidAntiCollision
        }
        let uidLength = Int(uidLengthByte)
        guard [4, 7, 10].contains(uidLength) else {
            throw ChameleonFlashError.invalidAntiCollision
        }
        let fixedEnd = 1 + uidLength + 2 + 1 + 1
        guard payload.count >= fixedEnd else {
            throw ChameleonFlashError.invalidAntiCollision
        }
        let atsLength = Int(payload[fixedEnd - 1])
        guard payload.count == fixedEnd + atsLength else {
            throw ChameleonFlashError.invalidAntiCollision
        }
        return (
            payload.subdata(in: 1..<(1 + uidLength)),
            payload.subdata(in: (1 + uidLength)..<(3 + uidLength)),
            payload[3 + uidLength],
            payload.subdata(in: fixedEnd..<payload.count)
        )
    }

    private func readActiveSlot() async throws -> Int {
        let value = try await command(Command.getActiveSlot, expected: 1...1, retryCount: 2)[0]
        guard value < 8 else { throw ChameleonFlashError.invalidSlot }
        return Int(value)
    }

    private func readSlotMetadata(slot: Int) async throws -> ChameleonSlot {
        guard (0..<8).contains(slot) else {
            throw ChameleonFlashError.invalidSlot
        }
        let types = try await command(Command.getSlotInfo, expected: 32...32, retryCount: 2)
        let enabled = try await command(Command.getEnabledSlots, expected: 16...16, retryCount: 2)
        let typeOffset = slot * 4
        let enabledOffset = slot * 2
        return ChameleonSlot(
            id: slot,
            hfType: (UInt16(types[typeOffset]) << 8) | UInt16(types[typeOffset + 1]),
            lfType: (UInt16(types[typeOffset + 2]) << 8) | UInt16(types[typeOffset + 3]),
            hfEnabled: enabled[enabledOffset] != 0,
            lfEnabled: enabled[enabledOffset + 1] != 0,
            nickname: try await readNickname(slot: slot, senseType: 2)
        )
    }

    private func requireCompatibleFirmware() async throws {
        let version = try await command(Command.getAppVersion, expected: 2...2, retryCount: 2)
        guard version[0] == 2 else {
            throw ChameleonFlashError.unsupportedFirmware("\(version[0]).\(version[1])")
        }
    }

    private func readBool(_ commandID: UInt16) async throws -> Bool {
        let value = try await command(commandID, expected: 1...1, retryCount: 2)[0]
        switch value {
        case 0: return false
        case 1: return true
        default: throw ChameleonFlashError.invalidBoolean(command: commandID, value: value)
        }
    }

    private func readNickname(slot: Int, senseType: UInt8) async throws -> String {
        let response = try await transport.send(
            command: Command.getSlotNickname,
            payload: Data([UInt8(slot), senseType]),
            retryCount: 2
        )
        if response.status == 0x0071 {
            return ""
        }
        guard response.status == ChameleonProtocol.successStatus else {
            throw ChameleonCommandError.failedStatus(command: response.command, status: response.status)
        }
        guard response.payload.count <= 32,
              let nickname = String(data: response.payload, encoding: .utf8) else {
            throw ChameleonCommandError.invalidPayload(
                command: response.command,
                expected: "0...32 bytes of UTF-8",
                actual: response.payload.count
            )
        }
        return nickname
    }

    @discardableResult
    private func command(
        _ commandID: UInt16,
        payload: Data = Data(),
        expected: ClosedRange<Int> = 0...0,
        timeout: TimeInterval = 2.5,
        retryCount: Int = 0
    ) async throws -> Data {
        let response = try await transport.send(
            command: commandID,
            payload: payload,
            timeout: timeout,
            retryCount: retryCount
        )
        guard response.status == ChameleonProtocol.successStatus else {
            throw ChameleonCommandError.failedStatus(command: commandID, status: response.status)
        }
        guard expected.contains(response.payload.count) else {
            throw ChameleonCommandError.invalidPayload(
                command: commandID,
                expected: "\(expected.lowerBound)...\(expected.upperBound) bytes",
                actual: response.payload.count
            )
        }
        return response.payload
    }

    private func persistRecovery(_ backup: NtagBackup) throws -> URL {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AmiiboDatabaseError.cacheUnavailable
        }
        let directory = applicationSupport
            .appending(path: "Amiibo Emulator", directoryHint: .isDirectory)
            .appending(path: "Recovery", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(
            path: "slot-\(backup.slot + 1)-\(Int(Date().timeIntervalSince1970)).json",
            directoryHint: .notDirectory
        )
        try JSONEncoder().encode(backup).write(to: url, options: .atomic)
        return url
    }

    private static func isNtagFamily(_ type: UInt16) -> Bool {
        (1100...1108).contains(type)
    }

    static func truncatedNickname(_ name: String) -> String {
        var bytes = 0
        var result = ""
        for character in name {
            let count = String(character).utf8.count
            guard bytes + count <= 32 else { break }
            result.append(character)
            bytes += count
        }
        return result
    }
}

private extension Data {
    func chunks(ofCount count: Int) -> [Data] {
        stride(from: 0, to: self.count, by: count).map {
            subdata(in: $0..<Swift.min($0 + count, self.count))
        }
    }
}

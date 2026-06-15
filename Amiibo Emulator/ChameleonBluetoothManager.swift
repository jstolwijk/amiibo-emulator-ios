import Combine
import CoreBluetooth
import Foundation

struct ChameleonDevice: Identifiable {
    let peripheral: CBPeripheral
    let rssi: Int

    var id: UUID { peripheral.identifier }
    var name: String { peripheral.name ?? "Chameleon" }
}

struct ChameleonSlot: Identifiable {
    let id: Int
    var hfType: UInt16 = 0
    var lfType: UInt16 = 0
    var hfEnabled = false
    var lfEnabled = false
    var nickname = ""

    var isAllocated: Bool {
        hfType != 0 || lfType != 0
    }
}

enum ChameleonCommandError: LocalizedError {
    case notConnected
    case disconnected
    case timeout(command: UInt16)
    case writeFailed(String)
    case unexpectedResponse(expected: UInt16, actual: UInt16)
    case failedStatus(command: UInt16, status: UInt16)
    case invalidPayload(command: UInt16, expected: String, actual: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "The Bluetooth connection is not ready."
        case .disconnected:
            "The Chameleon disconnected."
        case .timeout(let command):
            "Command \(command) timed out."
        case .writeFailed(let message):
            "Bluetooth write failed: \(message)"
        case .unexpectedResponse(let expected, let actual):
            "Expected response \(expected), received \(actual)."
        case .failedStatus(let command, let status):
            "Command \(command) failed with status 0x\(String(format: "%04X", status))."
        case .invalidPayload(let command, let expected, let actual):
            "Command \(command) returned \(actual) bytes; expected \(expected)."
        }
    }
}

final class ChameleonBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = "Starting Bluetooth..."
    @Published private(set) var devices: [ChameleonDevice] = []
    @Published private(set) var slots = (0..<8).map { ChameleonSlot(id: $0) }
    @Published private(set) var activeSlot: Int?
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var gitVersion: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isLoadingSlots = false
    @Published private(set) var slotLoadingMessage = "Reading slots..."
    @Published var errorMessage: String?

    private static let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartRXUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartTXUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var discoveredDevices: [UUID: ChameleonDevice] = [:]
    private var receiveBuffer = Data()
    private var pendingRequests: [CommandRequest] = []
    private var activeRequest: CommandRequest?
    private var outgoingChunks: [Data] = []
    private var commandTimeout: Timer?

    private final class CommandRequest {
        let command: UInt16
        let payload: Data
        let timeout: TimeInterval
        let maximumAttempts: Int
        let continuation: CheckedContinuation<ChameleonResponse, Error>
        var attempts = 0

        init(
            command: UInt16,
            payload: Data,
            timeout: TimeInterval,
            maximumAttempts: Int,
            continuation: CheckedContinuation<ChameleonResponse, Error>
        ) {
            self.command = command
            self.payload = payload
            self.timeout = timeout
            self.maximumAttempts = maximumAttempts
            self.continuation = continuation
        }
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            errorMessage = "Bluetooth is not available."
            return
        }

        discoveredDevices.removeAll()
        devices.removeAll()
        errorMessage = nil
        isScanning = true
        bluetoothState = "Searching for Chameleon devices..."
        centralManager.scanForPeripherals(
            withServices: [Self.uartServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        bluetoothState = connectedPeripheral == nil ? "Ready to scan" : "Connected"
    }

    func connect(to device: ChameleonDevice) {
        stopScanning()
        errorMessage = nil
        bluetoothState = "Connecting to \(device.name)..."
        connectedPeripheral = device.peripheral
        device.peripheral.delegate = self
        centralManager.connect(device.peripheral)
    }

    func disconnect() {
        guard let connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    func refreshSlots() {
        guard rxCharacteristic != nil else {
            errorMessage = "Connect to a Chameleon first."
            return
        }
        guard !isLoadingSlots else { return }

        errorMessage = nil
        isLoadingSlots = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.loadSlots()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoadingSlots = false
            self.slotLoadingMessage = "Reading slots..."
        }
    }

    private func loadSlots() async throws {
        slotLoadingMessage = "Reading firmware..."
        let appVersionResponse = try await send(command: 1000, retryCount: 2)
        try requireSuccess(appVersionResponse, payloadCount: 2)
        let major = appVersionResponse.payload[0]
        let minor = appVersionResponse.payload[1]
        guard major == 2 else {
            throw ChameleonCommandError.invalidPayload(
                command: 1000,
                expected: "firmware major version 2",
                actual: Int(major)
            )
        }
        firmwareVersion = "\(major).\(minor)"

        let gitVersionResponse = try await send(command: 1017, retryCount: 2)
        try requireSuccess(gitVersionResponse, payloadRange: 1...128)
        guard let gitVersion = String(data: gitVersionResponse.payload, encoding: .utf8) else {
            throw ChameleonCommandError.invalidPayload(
                command: 1017,
                expected: "valid UTF-8",
                actual: gitVersionResponse.payload.count
            )
        }
        self.gitVersion = gitVersion

        slotLoadingMessage = "Reading active slot..."
        let activeSlotResponse = try await send(command: 1018, retryCount: 2)
        try requireSuccess(activeSlotResponse, payloadCount: 1)
        guard let slot = activeSlotResponse.payload.first, slot < 8 else {
            throw ChameleonCommandError.invalidPayload(
                command: 1018,
                expected: "one valid slot byte",
                actual: activeSlotResponse.payload.count
            )
        }
        activeSlot = Int(slot)

        slotLoadingMessage = "Reading slot types..."
        let slotTypesResponse = try await send(command: 1019, retryCount: 2)
        try requireSuccess(slotTypesResponse, payloadCount: 32)
        parseSlotTypes(slotTypesResponse.payload)

        slotLoadingMessage = "Reading enabled slots..."
        let enabledSlotsResponse = try await send(command: 1023, retryCount: 2)
        try requireSuccess(enabledSlotsResponse, payloadCount: 16)
        parseEnabledSlots(enabledSlotsResponse.payload)

        for index in slots.indices {
            slotLoadingMessage = "Reading nickname \(index + 1) of 8..."
            slots[index].nickname = try await readHFNickname(slot: index)
        }
    }

    func send(
        command: UInt16,
        payload: Data = Data(),
        timeout: TimeInterval = 2.5,
        retryCount: Int = 0
    ) async throws -> ChameleonResponse {
        guard connectedPeripheral != nil, rxCharacteristic != nil else {
            throw ChameleonCommandError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(
                CommandRequest(
                    command: command,
                    payload: payload,
                    timeout: timeout,
                    maximumAttempts: max(1, retryCount + 1),
                    continuation: continuation
                )
            )
            startNextRequestIfNeeded()
        }
    }

    private func startNextRequestIfNeeded() {
        guard activeRequest == nil, !pendingRequests.isEmpty else { return }
        activeRequest = pendingRequests.removeFirst()
        beginActiveRequest()
    }

    private func beginActiveRequest() {
        guard let activeRequest, let connectedPeripheral, let rxCharacteristic else {
            completeActiveRequest(with: .failure(ChameleonCommandError.notConnected))
            return
        }

        do {
            activeRequest.attempts += 1
            let frame = try ChameleonProtocol.encodeRequest(
                command: activeRequest.command,
                payload: activeRequest.payload
            )
            let chunkSize = connectedPeripheral.maximumWriteValueLength(for: .withResponse)
            outgoingChunks = stride(from: 0, to: frame.count, by: chunkSize).map { offset in
                frame.subdata(in: offset..<min(offset + chunkSize, frame.count))
            }
            writeNextChunk(to: connectedPeripheral, characteristic: rxCharacteristic)
        } catch {
            completeActiveRequest(with: .failure(error))
        }
    }

    private func writeNextChunk(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard !outgoingChunks.isEmpty else {
            startTimeout()
            return
        }
        peripheral.writeValue(outgoingChunks.removeFirst(), for: characteristic, type: .withResponse)
    }

    private func startTimeout() {
        guard let activeRequest else { return }
        commandTimeout?.invalidate()
        commandTimeout = Timer.scheduledTimer(withTimeInterval: activeRequest.timeout, repeats: false) {
            [weak self] _ in
            self?.handleTimeout()
        }
    }

    private func handleTimeout() {
        guard let activeRequest else { return }
        if activeRequest.attempts < activeRequest.maximumAttempts {
            beginActiveRequest()
        } else {
            completeActiveRequest(
                with: .failure(ChameleonCommandError.timeout(command: activeRequest.command))
            )
        }
    }

    private func completeActiveRequest(with result: Result<ChameleonResponse, Error>) {
        commandTimeout?.invalidate()
        commandTimeout = nil
        outgoingChunks.removeAll()
        guard let request = activeRequest else { return }
        activeRequest = nil
        request.continuation.resume(with: result)
        startNextRequestIfNeeded()
    }

    private func cancelAllRequests(with error: Error) {
        commandTimeout?.invalidate()
        commandTimeout = nil
        outgoingChunks.removeAll()

        if let activeRequest {
            self.activeRequest = nil
            activeRequest.continuation.resume(throwing: error)
        }
        let requests = pendingRequests
        pendingRequests.removeAll()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
    }

    private func processReceivedData(_ data: Data) {
        receiveBuffer.append(data)

        while true {
            guard receiveBuffer.count >= 10 else { return }

            guard receiveBuffer[0] == 0x11, receiveBuffer[1] == 0xEF else {
                receiveBuffer = Data(receiveBuffer.dropFirst())
                continue
            }

            let payloadLength = Int(readUInt16(receiveBuffer, at: 6))
            guard payloadLength <= 512 else {
                receiveBuffer = Data(receiveBuffer.dropFirst())
                continue
            }

            let frameLength = payloadLength + 10
            guard receiveBuffer.count >= frameLength else { return }

            let packet = Data(receiveBuffer.prefix(frameLength))
            receiveBuffer = Data(receiveBuffer.dropFirst(frameLength))
            do {
                try handleResponse(ChameleonProtocol.decodeResponse(packet))
            } catch {
                completeActiveRequest(with: .failure(error))
            }
        }
    }

    private func handleResponse(_ response: ChameleonResponse) throws {
        guard let activeRequest else { return }
        guard response.command == activeRequest.command else {
            throw ChameleonCommandError.unexpectedResponse(
                expected: activeRequest.command,
                actual: response.command
            )
        }
        completeActiveRequest(with: .success(response))
    }

    private func parseSlotTypes(_ payload: Data) {
        for index in slots.indices {
            let offset = index * 4
            slots[index].hfType = readUInt16(payload, at: offset)
            slots[index].lfType = readUInt16(payload, at: offset + 2)
        }
    }

    private func parseEnabledSlots(_ payload: Data) {
        for index in slots.indices {
            let offset = index * 2
            slots[index].hfEnabled = payload[offset] != 0
            slots[index].lfEnabled = payload[offset + 1] != 0
        }
    }

    private func requireSuccess(_ response: ChameleonResponse, payloadCount: Int) throws {
        try requireSuccess(response, payloadRange: payloadCount...payloadCount)
    }

    private func requireSuccess(
        _ response: ChameleonResponse,
        payloadRange: ClosedRange<Int>
    ) throws {
        guard response.status == ChameleonProtocol.successStatus else {
            throw ChameleonCommandError.failedStatus(
                command: response.command,
                status: response.status
            )
        }
        guard payloadRange.contains(response.payload.count) else {
            throw ChameleonCommandError.invalidPayload(
                command: response.command,
                expected: "\(payloadRange.lowerBound)...\(payloadRange.upperBound) bytes",
                actual: response.payload.count
            )
        }
    }

    private func readHFNickname(slot: Int) async throws -> String {
        let response = try await send(
            command: 1008,
            payload: Data([UInt8(slot), 2]),
            retryCount: 2
        )
        if response.status == 0x0071 {
            return ""
        }
        try requireSuccess(response, payloadRange: 0...32)
        guard let nickname = String(data: response.payload, encoding: .utf8) else {
            throw ChameleonCommandError.invalidPayload(
                command: 1008,
                expected: "valid UTF-8",
                actual: response.payload.count
            )
        }
        return nickname
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private func resetConnection() {
        connectedPeripheral = nil
        connectedDeviceName = nil
        rxCharacteristic = nil
        receiveBuffer.removeAll()
        activeSlot = nil
        firmwareVersion = nil
        gitVersion = nil
        slots = (0..<8).map { ChameleonSlot(id: $0) }
        cancelAllRequests(with: ChameleonCommandError.disconnected)
        isLoadingSlots = false
        slotLoadingMessage = "Reading slots..."
    }
}

extension ChameleonBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "Ready to scan"
        case .poweredOff:
            bluetoothState = "Bluetooth is turned off"
        case .unauthorized:
            bluetoothState = "Bluetooth permission is required"
        case .unsupported:
            bluetoothState = "Bluetooth Low Energy is unsupported"
        case .resetting:
            bluetoothState = "Bluetooth is resetting"
        case .unknown:
            bluetoothState = "Bluetooth state is unknown"
        @unknown default:
            bluetoothState = "Bluetooth is unavailable"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? ""
        guard name.hasPrefix("ChameleonUltra") || name.hasPrefix("ChameleonLite") else { return }

        discoveredDevices[peripheral.identifier] = ChameleonDevice(
            peripheral: peripheral,
            rssi: RSSI.intValue
        )
        devices = discoveredDevices.values.sorted { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        bluetoothState = "Discovering services..."
        connectedDeviceName = peripheral.name ?? "Chameleon"
        peripheral.discoverServices([Self.uartServiceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let message = error?.localizedDescription ?? "Unknown connection error"
        resetConnection()
        bluetoothState = "Ready to scan"
        errorMessage = "Could not connect: \(message)"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        resetConnection()
        bluetoothState = "Disconnected"
        if let error {
            errorMessage = error.localizedDescription
        }
    }
}

extension ChameleonBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            errorMessage = error.localizedDescription
            return
        }

        guard let uartService = peripheral.services?.first(where: {
            $0.uuid == Self.uartServiceUUID
        }) else {
            errorMessage = "The Chameleon UART service was not found."
            return
        }

        peripheral.discoverCharacteristics(
            [Self.uartRXUUID, Self.uartTXUUID],
            for: uartService
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            errorMessage = error.localizedDescription
            return
        }

        rxCharacteristic = service.characteristics?.first(where: {
            $0.uuid == Self.uartRXUUID
        })
        let txCharacteristic = service.characteristics?.first(where: {
            $0.uuid == Self.uartTXUUID
        })

        guard let txCharacteristic, rxCharacteristic != nil else {
            errorMessage = "The Chameleon UART characteristics were not found."
            return
        }

        bluetoothState = "Connected"
        peripheral.setNotifyValue(true, for: txCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            errorMessage = error.localizedDescription
            return
        }

        if characteristic.uuid == Self.uartTXUUID, characteristic.isNotifying {
            refreshSlots()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            errorMessage = error.localizedDescription
            return
        }

        guard characteristic.uuid == Self.uartTXUUID, let value = characteristic.value else {
            return
        }

        processReceivedData(value)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            completeActiveRequest(
                with: .failure(ChameleonCommandError.writeFailed(error.localizedDescription))
            )
            return
        }

        if let rxCharacteristic, characteristic.uuid == rxCharacteristic.uuid {
            writeNextChunk(to: peripheral, characteristic: rxCharacteristic)
        }
    }
}

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

    var isAllocated: Bool {
        hfType != 0 || lfType != 0
    }
}

final class ChameleonBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = "Starting Bluetooth..."
    @Published private(set) var devices: [ChameleonDevice] = []
    @Published private(set) var slots = (0..<8).map { ChameleonSlot(id: $0) }
    @Published private(set) var activeSlot: Int?
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isLoadingSlots = false
    @Published var errorMessage: String?

    private static let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartRXUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartTXUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let successStatus: UInt16 = 0x0068

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var discoveredDevices: [UUID: ChameleonDevice] = [:]
    private var receiveBuffer = Data()

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

        errorMessage = nil
        isLoadingSlots = true
        send(command: 1018)
    }

    private func send(command: UInt16, payload: Data = Data()) {
        guard let connectedPeripheral, let rxCharacteristic else { return }

        let length = UInt16(payload.count)
        var packet = Data([
            0x11,
            0xEF,
            UInt8(command >> 8),
            UInt8(command & 0xFF),
            0x00,
            0x00,
            UInt8(length >> 8),
            UInt8(length & 0xFF)
        ])
        packet.append(lrc(for: packet.suffix(6)))
        packet.append(payload)
        packet.append(lrc(for: payload))

        connectedPeripheral.writeValue(packet, for: rxCharacteristic, type: .withResponse)
    }

    private func lrc<C: Collection>(for bytes: C) -> UInt8 where C.Element == UInt8 {
        let sum = bytes.reduce(UInt8.zero) { $0 &+ $1 }
        return 0 &- sum
    }

    private func processReceivedData(_ data: Data) {
        receiveBuffer.append(data)

        while true {
            guard receiveBuffer.count >= 10 else { return }

            guard receiveBuffer[0] == 0x11, receiveBuffer[1] == 0xEF else {
                receiveBuffer.removeFirst()
                continue
            }

            let payloadLength = Int(readUInt16(receiveBuffer, at: 6))
            guard payloadLength <= 512 else {
                receiveBuffer.removeFirst()
                continue
            }

            let frameLength = payloadLength + 10
            guard receiveBuffer.count >= frameLength else { return }

            let frame = receiveBuffer.prefix(frameLength)
            receiveBuffer.removeFirst(frameLength)
            let packet = Data(frame)
            guard isValid(packet) else { continue }
            handleFrame(packet)
        }
    }

    private func isValid(_ frame: Data) -> Bool {
        let payloadLength = Int(readUInt16(frame, at: 6))
        let headerLRC = frame[8]
        let payload = frame.subdata(in: 9..<(9 + payloadLength))
        let payloadLRC = frame[9 + payloadLength]

        return headerLRC == lrc(for: frame[2..<8])
            && payloadLRC == lrc(for: payload)
    }

    private func handleFrame(_ frame: Data) {
        let command = readUInt16(frame, at: 2)
        let status = readUInt16(frame, at: 4)
        let payloadLength = Int(readUInt16(frame, at: 6))
        let payload = frame.subdata(in: 9..<(9 + payloadLength))

        guard status == Self.successStatus else {
            isLoadingSlots = false
            errorMessage = "Chameleon command \(command) failed with status \(status)."
            return
        }

        switch command {
        case 1018:
            activeSlot = payload.first.map(Int.init)
            send(command: 1019)
        case 1019:
            parseSlotTypes(payload)
            send(command: 1023)
        case 1023:
            parseEnabledSlots(payload)
            isLoadingSlots = false
        default:
            break
        }
    }

    private func parseSlotTypes(_ payload: Data) {
        guard payload.count >= 32 else {
            errorMessage = "The device returned incomplete slot information."
            return
        }

        for index in slots.indices {
            let offset = index * 4
            slots[index].hfType = readUInt16(payload, at: offset)
            slots[index].lfType = readUInt16(payload, at: offset + 2)
        }
    }

    private func parseEnabledSlots(_ payload: Data) {
        guard payload.count >= 16 else {
            errorMessage = "The device returned incomplete enabled-slot information."
            return
        }

        for index in slots.indices {
            let offset = index * 2
            slots[index].hfEnabled = payload[offset] != 0
            slots[index].lfEnabled = payload[offset + 1] != 0
        }
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
        slots = (0..<8).map { ChameleonSlot(id: $0) }
        isLoadingSlots = false
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
            isLoadingSlots = false
            errorMessage = "Bluetooth write failed: \(error.localizedDescription)"
        }
    }
}

import CoreBluetooth
import Foundation

/// The Bluetooth LE side of the ambient light: scan, connect, find out what the device offers,
/// write commands, and write down everything that happens. Used by the test screen and by the
/// music light (LightMusic).
///
/// Created the first time the test screen is opened or the music light is switched on - that
/// is when iOS asks for the Bluetooth permission - and never before, so with both unused the
/// rest of the app is not touched by it. The app has the bluetooth-central background mode, so
/// a connection keeps working with the screen locked.
///
/// Every line goes to the screen (`onLog`) and, prefixed with "light", to the app's own log
/// (Diag), which is sent to the PC.
///
/// Main queue only (CoreBluetooth is told to call back there).
final class LightLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = LightLink()

    struct Found {
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
        var services: [String]
        /// Advertises a service the vendor's app looks for (or the control service itself).
        var likely: Bool
    }

    enum WriteMode: Int {
        case auto = 0
        case withoutResponse = 1
        case withResponse = 2
    }

    enum Handed {
        case sent        // given to CoreBluetooth
        case queued      // waits until the link is ready
        case skipped     // not sent: no link, or the link was not ready
    }

    /// Services the vendor app's scan accepts, plus the control service.
    static let likelyServices: Set<String> = ["AF30", "FFF0", "FEE7", "FFE0"]

    /// A new line for the screen (already with its time).
    var onLog: ((String) -> Void)?
    /// The list of devices, the connection or the write target changed.
    var onChange: (() -> Void)?
    /// The same, for the music light (the test screen owns `onChange`).
    var onStatus: (() -> Void)?
    /// Every complete frame the controller sends, also during quiet and muted stretches.
    var onFrame: ((LightFrame) -> Void)?

    private(set) var found: [Found] = []
    private(set) var connected: CBPeripheral?
    private(set) var connecting: CBPeripheral?
    private(set) var writable: [CBCharacteristic] = []
    private(set) var writeTarget: CBCharacteristic?
    private(set) var scanning = false
    /// Notifications received since the app started.
    private(set) var notifications = 0
    /// The controller's state frames, newest last (at most 20), whoever asked for them.
    private(set) var states: [LightState] = []
    /// How many state frames have arrived since the app started.
    private(set) var stateCount = 0
    /// Every frame, newest last (at most 40), and how many have arrived since the app started.
    private(set) var frames: [LightFrame] = []
    private(set) var frameCount = 0
    /// Every line so far, for the copy button.
    private(set) var lines: [String] = []

    /// Which kind of write to use; `auto` = without response when the characteristic allows it.
    var writeMode: WriteMode = .auto
    /// Send even when CoreBluetooth says the link is not ready for another write.
    var ignoreReady = false
    /// During a rate test: single writes and notifications are counted, not written down.
    var quiet = false
    /// While the music light runs: notifications are not written down one by one (frames still
    /// go to `onFrame`; the music light writes down those it uses).
    var muted = false
    /// The scan is looking for the light: connect to the first device that advertises one of
    /// the vendor's services.
    private var autoPick = false

    /// The device connected last time (kept over restarts).
    private static let savedKey = "lightDevice"
    var savedDevice: (id: UUID, name: String)? {
        guard let entry = UserDefaults.standard.dictionary(forKey: LightLink.savedKey),
              let text = entry["id"] as? String, let id = UUID(uuidString: text) else { return nil }
        return (id, entry["name"] as? String ?? "")
    }

    var poweredOn: Bool { return central.state == .poweredOn }
    var bluetoothState: CBManagerState { return central.state }
    /// Connected, with a characteristic to write to.
    var isReady: Bool { return connected?.state == .connected && writeTarget != nil }

    private var central: CBCentralManager!
    private let splitter = LightReplySplitter()
    private var pending: [String] = []
    private var awaitingResponse = false
    private var wantScan = false
    private var quietReceived = 0
    private let clock: DateFormatter

    private override init() {
        clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss.SSS"
        super.init()
        /* queue nil = the main queue */
        central = CBCentralManager(delegate: self, queue: nil)
        log("bluetooth started")
    }

    private func changed() {
        onChange?()
        onStatus?()
    }

    // MARK: log

    func log(_ text: String, error: Bool = false) {
        let line = clock.string(from: Date()) + " " + text
        lines.append(line)
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
        Diag.shared.log("light " + text, error: error)
        onLog?(line)
    }

    var stateText: String {
        switch central.state {
        case .poweredOn:
            if let p = connected { return "已連線：" + (p.name ?? "(無名稱)") }
            if let p = connecting { return "連線中：" + (p.name ?? "(無名稱)") }
            return scanning ? "掃描中…" : "藍牙已開啟"
        case .poweredOff: return "藍牙已關閉"
        case .unauthorized: return "沒有藍牙權限（到「設定」裡允許）"
        case .unsupported: return "這台裝置不支援藍牙 LE"
        case .resetting: return "藍牙重設中"
        default: return "藍牙狀態未知"
        }
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        default: return "unknown"
        }
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    // MARK: scanning and connecting

    func startScan() {
        wantScan = true
        guard central.state == .poweredOn else {
            log("scan asked, bluetooth is \(LightLink.describe(central.state))")
            changed()
            return
        }
        found.removeAll()
        /* No service filter: everything nearby is listed, each device once. */
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true
        log("scan started (no filter)")
        changed()
    }

    /// Looks for the light: only devices that advertise one of the vendor's services (a scan
    /// with a service filter also works in the background), and connects to the first one.
    func scanForLight() {
        wantScan = true
        autoPick = true
        guard central.state == .poweredOn else { return }
        if scanning { central.stopScan() }
        found.removeAll()
        let services = ["AF30", "FFF0", "FEE7"].map { CBUUID(string: $0) }
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true
        log("scan for the light started")
        changed()
    }

    /// Connects to the device used last time, if iOS still knows it. False = it does not (or
    /// Bluetooth is not on); scan instead.
    @discardableResult
    func connectSaved() -> Bool {
        guard central.state == .poweredOn, let saved = savedDevice,
              let peripheral = central.retrievePeripherals(withIdentifiers: [saved.id]).first else { return false }
        if peripheral === connected || peripheral === connecting { return true }
        connect(peripheral)
        return true
    }

    func stopScan() {
        wantScan = false
        autoPick = false
        if scanning {
            central.stopScan()
            scanning = false
            log("scan stopped, \(found.count) devices seen")
            changed()
        }
    }

    func connect(_ peripheral: CBPeripheral) {
        if scanning {
            central.stopScan()
            scanning = false
        }
        wantScan = false
        autoPick = false
        if let old = connected ?? connecting, old !== peripheral {
            central.cancelPeripheralConnection(old)
        }
        connecting = peripheral
        log("connecting to \(peripheral.name ?? "(no name)") \(peripheral.identifier.uuidString)")
        central.connect(peripheral, options: nil)
        changed()
    }

    func disconnect() {
        if let p = connected ?? connecting {
            log("disconnect asked")
            central.cancelPeripheralConnection(p)
        }
    }

    func chooseWriteTarget(_ characteristic: CBCharacteristic) {
        writeTarget = characteristic
        log("write characteristic chosen: \(characteristic.uuid.uuidString) (\(LightLink.describe(characteristic.properties)))")
        changed()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("bluetooth state: \(LightLink.describe(central.state))", error: central.state == .unauthorized || central.state == .unsupported)
        if central.state != .poweredOn {
            scanning = false
            connected = nil
            connecting = nil
            writeTarget = nil
            writable = []
        } else if wantScan {
            if autoPick { scanForLight() } else { startScan() }
        }
        changed()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let listed = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let services = listed.map { $0.uuidString }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? ""
        let likely = services.contains { LightLink.likelyServices.contains($0) }
        let entry = Found(peripheral: peripheral, name: name, rssi: RSSI.intValue, services: services, likely: likely)
        if let at = found.firstIndex(where: { $0.peripheral === peripheral }) {
            found[at] = entry
        } else {
            found.append(entry)
            /* Devices without a name and without a telling service are only counted. */
            if likely || !name.isEmpty {
                let mark = likely ? " *likely*" : ""
                log("found \(name.isEmpty ? "(no name)" : name) rssi \(RSSI.intValue) services [\(services.joined(separator: ","))]\(mark)")
            }
        }
        if autoPick && likely {
            log("light found: \(name.isEmpty ? "(no name)" : name)")
            connect(peripheral)
            return
        }
        found.sort { a, b in
            if a.likely != b.likely { return a.likely }
            if a.name.isEmpty != b.name.isEmpty { return !a.name.isEmpty }
            return a.rssi > b.rssi
        }
        changed()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connecting = nil
        connected = peripheral
        writable = []
        writeTarget = nil
        pending = []
        awaitingResponse = false
        splitter.reset()
        peripheral.delegate = self
        let noResponse = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let response = peripheral.maximumWriteValueLength(for: .withResponse)
        log("connected to \(peripheral.name ?? "(no name)"); longest write: \(noResponse) bytes without response, \(response) with")
        UserDefaults.standard.set(["id": peripheral.identifier.uuidString, "name": peripheral.name ?? ""], forKey: LightLink.savedKey)
        /* Everything the device offers, not only the services we expect. */
        peripheral.discoverServices(nil)
        changed()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting = nil
        log("connecting failed: \(error?.localizedDescription ?? "no reason given")", error: true)
        changed()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === connected || peripheral === connecting {
            connected = nil
            connecting = nil
            writeTarget = nil
            writable = []
            pending = []
            awaitingResponse = false
        }
        if let error = error {
            log("disconnected: \(error.localizedDescription)", error: true)
        } else {
            log("disconnected")
        }
        changed()
    }

    // MARK: what the device offers

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("service discovery failed: \(error.localizedDescription)", error: true)
            return
        }
        let services = peripheral.services ?? []
        log("services: [\(services.map { $0.uuid.uuidString }.joined(separator: ","))]")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("characteristics of \(service.uuid.uuidString) failed: \(error.localizedDescription)", error: true)
            return
        }
        for c in service.characteristics ?? [] {
            log("service \(service.uuid.uuidString) characteristic \(c.uuid.uuidString): \(LightLink.describe(c.properties))")
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                writable.append(c)
                /* The vendor app writes to FFE2. Anything else is for the user to pick. */
                if c.uuid.uuidString == "FFE2" && writeTarget == nil {
                    writeTarget = c
                    log("write characteristic: FFE2 (\(LightLink.describe(c.properties)))")
                }
            }
        }
        changed()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("notify on \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)", error: true)
        } else {
            log("notify on \(characteristic.uuid.uuidString): \(characteristic.isNotifying ? "on" : "off")")
        }
    }

    // MARK: receiving

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("RX \(characteristic.uuid.uuidString) error: \(error.localizedDescription)", error: true)
            return
        }
        guard let data = characteristic.value else { return }
        notifications += 1
        /* During a rate test only the first few are written down; all are counted. While the
           music light runs nothing is written down here. Frames are always passed on. */
        var write = !muted
        if quiet {
            quietReceived += 1
            if quietReceived > 5 { write = false }
        }
        if write {
            let text = String(decoding: data.map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x2E }, as: UTF8.self)
            log("RX \(characteristic.uuid.uuidString) \(text) hex \(lightHex(data))")
        }
        for piece in splitter.feed(data) {
            switch piece {
            case .frame(let frame):
                if write { log("RX frame \(frame.text) type \(frame.type.isEmpty ? "?" : frame.type) \(frame.name ?? "unknown")") }
                frames.append(frame)
                if frames.count > 40 { frames.removeFirst(frames.count - 40) }
                frameCount += 1
                if let state = LightState(frame: frame.text) {
                    states.append(state)
                    if states.count > 20 { states.removeFirst(states.count - 20) }
                    stateCount += 1
                }
                onFrame?(frame)
            case .other(let other):
                if write { log("RX outside any frame: \(other)") }
            }
        }
    }

    // MARK: sending

    /// Starts or ends the quiet stretch of a rate test.
    func setQuiet(_ on: Bool) {
        quiet = on
        quietReceived = 0
    }

    /// Sends a command (the text as ASCII). `queueIfBusy`: when the link cannot take a write
    /// right now, keep the command and send it as soon as it can (for buttons); otherwise it
    /// is dropped and reported as skipped (for the rate tests, which count those).
    /// `silent`: nothing is written down (the music light's colour stream).
    @discardableResult
    func send(_ command: String, queueIfBusy: Bool, silent: Bool = false) -> Handed {
        let say = !quiet && !silent
        guard let peripheral = connected, peripheral.state == .connected else {
            if say { log("TX \(command) not sent: not connected", error: true) }
            return .skipped
        }
        guard let target = writeTarget else {
            if say { log("TX \(command) not sent: no write characteristic chosen", error: true) }
            return .skipped
        }
        var withoutResponse = target.properties.contains(.writeWithoutResponse)
        if writeMode == .withoutResponse { withoutResponse = true }
        if writeMode == .withResponse { withoutResponse = false }

        let ready = withoutResponse ? peripheral.canSendWriteWithoutResponse : !awaitingResponse
        if !ready && !ignoreReady {
            if queueIfBusy {
                pending.append(command)
                if pending.count > 20 { pending.removeFirst(pending.count - 20) }
                if !silent { log("TX \(command) waits: link not ready") }
                return .queued
            }
            return .skipped
        }
        let data = LightCommand.bytes(command)
        if withoutResponse {
            peripheral.writeValue(data, for: target, type: .withoutResponse)
        } else {
            awaitingResponse = true
            peripheral.writeValue(data, for: target, type: .withResponse)
        }
        if say {
            log("TX \(command) hex \(lightHex(data)) to \(target.uuid.uuidString) type=\(withoutResponse ? "NR" : "R") ready=\(ready)")
        }
        return .sent
    }

    private func sendPending() {
        /* In the order they were asked for; one that cannot go yet stays at the front. */
        while let next = pending.first {
            if send(next, queueIfBusy: false) != .sent { break }
            pending.removeFirst()
        }
    }

    /// The link can take another write without response.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if !quiet && !muted && !pending.isEmpty { log("link ready again") }
        sendPending()
    }

    /// The answer to a write with response.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        awaitingResponse = false
        if let error = error {
            log("TX to \(characteristic.uuid.uuidString) refused: \(error.localizedDescription)", error: true)
        } else if !quiet && !muted {
            log("TX to \(characteristic.uuid.uuidString) acknowledged")
        }
        sendPending()
    }
}

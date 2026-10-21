import SwiftUI
import CoreBluetooth

private let serviceUUID = CBUUID(string: "7B3A0001-7D5A-4F2B-9C1A-6E2D8F001001")
private let controlUUID = CBUUID(string: "7B3A0002-7D5A-4F2B-9C1A-6E2D8F001001")
private let statusUUID  = CBUUID(string: "7B3A0003-7D5A-4F2B-9C1A-6E2D8F001001")

struct DeviceStatus: Decodable {
    var volume: Int = 35
    var inputIndex: Int = 1
    var input: String = "AUX"
    var mute: Bool = false
    var eq: [Int] = [0, 0, 0, 0, 0]
    var lastCommand: String = "Nincs kapcsolat"
    var wifi: String = ""
}

@MainActor
final class HiFiController: NSObject, ObservableObject {
    @Published var status = DeviceStatus()
    @Published var bleState = "Bluetooth: keresésre vár"
    @Published var wifiState = "Wi-Fi: nincs csatlakoztatva"
    @Published var deviceIP = "192.168.1.100"
    @Published var isScanning = false
    @Published var isConnectedBLE = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scanBLE() {
        guard central.state == .poweredOn else {
            bleState = "Kapcsold be a Bluetooth-t"
            return
        }
        isScanning = true
        bleState = "HiFi-ESP32 keresése…"
        central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            if self.isScanning {
                self.central.stopScan()
                self.isScanning = false
                if !self.isConnectedBLE { self.bleState = "Nem található. Ellenőrizd az ESP32 tápját." }
            }
        }
    }

    func disconnectBLE() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    func send(_ command: String) {
        // Prefer BLE when connected; otherwise use the ESP32's local Wi-Fi API.
        if let p = peripheral, let characteristic = controlCharacteristic, isConnectedBLE {
            guard let data = command.data(using: .utf8) else { return }
            let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            p.writeValue(data, for: characteristic, type: type)
        } else {
            sendWiFi(command)
        }
    }

    func refreshWiFi() {
        guard let url = URL(string: "http://\(deviceIP)/api/state") else {
            wifiState = "Hibás IP-cím"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let decoded = try? JSONDecoder().decode(DeviceStatus.self, from: data) {
                    self.status = decoded
                    self.wifiState = "Csatlakozva: \(self.deviceIP)"
                } else {
                    self.wifiState = "Nem érhető el. Azonos Wi-Fi és helyes IP kell."
                }
            }
        }.resume()
    }

    private func sendWiFi(_ command: String) {
        guard let encoded = command.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://\(deviceIP)/api/cmd?c=\(encoded)") else {
            wifiState = "Hibás IP-cím"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let decoded = try? JSONDecoder().decode(DeviceStatus.self, from: data) {
                    self.status = decoded
                    self.wifiState = "Csatlakozva: \(self.deviceIP)"
                } else {
                    self.wifiState = "Parancs sikertelen. Ellenőrizd az IP-t és a Wi-Fi-t."
                }
            }
        }.resume()
    }
}

extension HiFiController: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bleState = "Bluetooth bekapcsolva"
        case .poweredOff: bleState = "Bluetooth kikapcsolva"
        case .unauthorized: bleState = "Bluetooth engedély szükséges"
        case .unsupported: bleState = "BLE nem támogatott"
        default: bleState = "Bluetooth állapot: \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard peripheral.name == "HiFi-ESP32" || advertisementData[CBAdvertisementDataLocalNameKey] as? String == "HiFi-ESP32" else { return }
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        central.stopScan()
        isScanning = false
        bleState = "Csatlakozás: HiFi-ESP32…"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnectedBLE = true
        bleState = "Bluetooth csatlakoztatva"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnectedBLE = false
        bleState = "Bluetooth csatlakozás sikertelen"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnectedBLE = false
        controlCharacteristic = nil
        statusCharacteristic = nil
        bleState = "Bluetooth bontva"
    }
}

extension HiFiController: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([controlUUID, statusUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.uuid == controlUUID { controlCharacteristic = char }
            if char.uuid == statusUUID {
                statusCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
                peripheral.readValue(for: char)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == statusUUID, let data = characteristic.value,
              let decoded = try? JSONDecoder().decode(DeviceStatus.self, from: data) else { return }
        DispatchQueue.main.async { self.status = decoded }
    }
}

struct ContentView: View {
    @StateObject private var controller = HiFiController()
    private let inputs = ["Bluetooth", "AUX", "USB audio", "Wi-Fi audio", "Internet radio"]
    private let bands = ["60 Hz", "150 Hz", "400 Hz", "1 kHz", "6 kHz"]

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.025, green: 0.07, blue: 0.12), Color(red: 0.05, green: 0.15, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("NOVA").font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(Color.cyan)
                                Text("HI-FI REMOTE").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.white.opacity(0.65))
                            }
                            Spacer()
                            Image(systemName: "waveform").font(.system(size: 30, weight: .medium)).foregroundStyle(.cyan)
                        }
                        .padding(.top, 8)

                        panel {
                            Text("AKTÍV BEMENET").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
                            Text(controller.status.input.uppercased()).font(.system(size: 27, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                                ForEach(inputs.indices, id: \.self) { i in
                                    Button { controller.send("INPUT:\(i)") } label: {
                                        Text(inputs[i]).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                                            .background(controller.status.inputIndex == i ? Color.cyan : Color.white.opacity(0.08))
                                            .foregroundStyle(controller.status.inputIndex == i ? Color.black : Color.white)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                        }

                        panel {
                            HStack {
                                Text("HANGERŐ").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
                                Spacer()
                                Text("\(controller.status.volume)%").font(.title2.bold()).foregroundStyle(.cyan)
                            }
                            Slider(value: Binding(
                                get: { Double(controller.status.volume) },
                                set: { controller.status.volume = Int($0) }
                            ), in: 0...100, step: 1) { editing in
                                if !editing { controller.send("VOL:\(controller.status.volume)") }
                            }.tint(.cyan)
                            Button {
                                controller.send("MUTE:\(controller.status.mute ? 0 : 1)")
                            } label: {
                                Label(controller.status.mute ? "Némítás kikapcsolása" : "Némítás", systemImage: controller.status.mute ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                    .frame(maxWidth: .infinity).padding(12).background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                            }.foregroundStyle(.white)
                        }

                        panel {
                            Text("ÖTSÁVOS EQ").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
                            ForEach(0..<5, id: \.self) { i in
                                VStack(spacing: 4) {
                                    HStack {
                                        Text(bands[i]).foregroundStyle(.white.opacity(0.85))
                                        Spacer()
                                        Text("\((controller.status.eq.indices.contains(i) ? controller.status.eq[i] : 0) dB")
                                                .foregroundStyle(.cyan)
                                                .monospacedDigit()
                                    }.font(.subheadline)
                                    Slider(value: Binding(
                                        get: { Double(controller.status.eq.indices.contains(i) ? controller.status.eq[i] : 0) },
                                        set: { value in
                                            while controller.status.eq.count < 5 { controller.status.eq.append(0) }
                                            controller.status.eq[i] = Int(value)
                                        }
                                    ), in: -12...12, step: 1) { editing in
                                        if !editing { controller.send("EQ\(i):\(controller.status.eq[i])") }
                                    }.tint(.cyan)
                                }
                            }
                            Text("Az EQ jelenleg a vezérlőparancsokat teszteli; a tényleges DSP később kerül bekötésre.")
                                .font(.caption).foregroundStyle(.white.opacity(0.55))
                        }

                        panel {
                            Text("KAPCSOLAT").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
                            Text(controller.bleState).font(.footnote).foregroundStyle(.cyan).frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button { controller.scanBLE() } label: {
                                    Label("BLE keresés", systemImage: "dot.radiowaves.left.and.right")
                                        .frame(maxWidth: .infinity).padding(12).background(Color.cyan).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                Button { controller.disconnectBLE() } label: {
                                    Text("Leválasztás").frame(maxWidth: .infinity).padding(12).background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                                }.foregroundStyle(.white)
                            }
                            TextField("ESP32 IP-címe (pl. 192.168.1.100)", text: $controller.deviceIP)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(12).background(Color.black.opacity(0.22)).clipShape(RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                            Button { controller.refreshWiFi() } label: {
                                Label("Wi-Fi kapcsolat tesztelése", systemImage: "wifi")
                                    .frame(maxWidth: .infinity).padding(12).background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                            }.foregroundStyle(.white)
                            Text(controller.wifiState).font(.footnote).foregroundStyle(.cyan).frame(maxWidth: .infinity, alignment: .leading)
                            Text("Wi-Fi vezérléshez az iPhone és az ESP32 ugyanazon az otthoni hálózaton legyen.")
                                .font(.caption).foregroundStyle(.white.opacity(0.55))
                        }

                        Text("NOVA Hi-Fi Remote · vezérlőprototípus").font(.caption2).foregroundStyle(.white.opacity(0.4)).padding(.bottom, 20)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.06, green: 0.13, blue: 0.20).opacity(0.95))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.09), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

@main
struct NOVAHiFiRemoteApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

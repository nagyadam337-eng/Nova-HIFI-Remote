import SwiftUI
import CoreBluetooth

// ==========================================
// ESP32 FIRMWARE-REL SZINKRONIZÁLT UUID-K
// ==========================================
private let serviceUUID = CBUUID(string: "4fa8691a-1065-4642-b113-401489822400")
private let controlUUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26a8")

struct DeviceStatus: Decodable {
    var volume: Int = 35
    var inputIndex: Int = 1
    var input: String = "AUX"
    var mute: Bool = false
    var eq: [Int] = [0, 0, 0, 0, 0]
    var currentRadio: String = "Rádió 1"
    var lastCommand: String = "Nincs kapcsolat"
    var wifi: String = ""
}

struct RadioStation: Identifiable {
    let id: Int
    let name: String
    let freqOrGenre: String
    let icon: String
}

@MainActor
final class HiFiController: NSObject, ObservableObject {
    @Published var status = DeviceStatus()
    @Published var bleState = "Bluetooth: keresésre vár"
    @Published var wifiState = "Wi-Fi: nincs csatlakoztatva"
    @Published var deviceIP = "192.168.1.100"
    @Published var isScanning = false
    @Published var isConnectedBLE = false
    @Published var commandText = ""
    @Published var commandMessage = ""
    @Published var wifiSSID = ""
    @Published var wifiPassword = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?

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
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        
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
        if let p = peripheral, let characteristic = controlCharacteristic, isConnectedBLE {
            guard let data = command.data(using: .utf8) else { return }
            let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            p.writeValue(data, for: characteristic, type: type)
            commandMessage = "Elküldve BLE-n: \(command)"
        } else {
            sendWiFi(command)
        }
    }

    func sendTypedCommand() {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        send(command)
        commandText = ""
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
                    self.wifiState = "Nem érhető el. Azonos Wi-Fi és IP kell."
                }
            }
        }.resume()
    }

    func configureWiFi() {
        let ssid = wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty, let peripheral, let characteristic = controlCharacteristic, isConnectedBLE else {
            wifiState = "Előbb csatlakozz Bluetoothon!"
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["ssid": ssid, "password": wifiPassword]) else {
            wifiState = "A Wi-Fi adatok nem küldhetők el"
            return
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        wifiState = "Wi-Fi beállítás küldése…"
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
                    self.wifiState = "Parancs sikertelen. Ellenőrizd az IP-t."
                }
            }
        }.resume()
    }
}

extension HiFiController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bleState = "Bluetooth bekapcsolva"
        case .poweredOff: bleState = "Bluetooth kikapcsolva"
        case .unauthorized: bleState = "Bluetooth engedély szükséges"
        default: bleState = "Bluetooth állapot: \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        if name.contains("HiFi-ESP32") || name.contains("Nova") {
            self.peripheral = peripheral
            self.peripheral?.delegate = self
            central.stopScan()
            isScanning = false
            bleState = "Csatlakozás: \(name)…"
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnectedBLE = true
        bleState = "Bluetooth csatlakoztatva"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnectedBLE = false
        controlCharacteristic = nil
        bleState = "Bluetooth bontva"
    }
}

extension HiFiController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([controlUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars where char.uuid == controlUUID {
            controlCharacteristic = char
            peripheral.setNotifyValue(true, for: char)
        }
    }
}

// ==========================================
// SWIFTUI FELÜLET MENÜSÁVVAL ÉS AKTIÓKKAL
// ==========================================
struct ContentView: View {
    @StateObject private var controller = HiFiController()
    
    var body: some View {
        TabView {
            // 1. TAB: FŐ VEZÉRLŐ & EQ
            MainControlsView(controller: controller)
                .tabItem {
                    Label("Vezérlés", systemImage: "slider.horizontal.3")
                }
            
            // 2. TAB: INTERNET RÁDIÓ CSATORNÁK
            RadioView(controller: controller)
                .tabItem {
                    Label("Rádió", systemImage: "radio.fill")
                }
            
            // 3. TAB: KAPCSOLAT & WI-FI BEÁLLÍTÁSOK
            SettingsView(controller: controller)
                .tabItem {
                    Label("Kapcsolat", systemImage: "wifi")
                }
            
            // 4. TAB: MANUÁLIS PARANCSOK
            ConsoleView(controller: controller)
                .tabItem {
                    Label("Konzol", systemImage: "terminal.fill")
                }
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }
}

// ------------------------------------------
// 1. FŐ VEZÉRLŐ ÉS EQ NÉZET
// ------------------------------------------
struct MainControlsView: View {
    @ObservedObject var controller: HiFiController
    private let inputs = ["Bluetooth", "AUX", "USB audio", "Wi-Fi audio", "Internet radio"]
    private let bands = ["60 Hz", "150 Hz", "400 Hz", "1 kHz", "6 kHz"]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.025, green: 0.07, blue: 0.12), Color(red: 0.05, green: 0.15, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Fejléc
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NOVA").font(.system(size: 28, weight: .black, design: .rounded)).foregroundStyle(Color.cyan)
                            Text("HI-FI VEZÉRLÉS").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Image(systemName: "waveform").font(.system(size: 26, weight: .medium)).foregroundStyle(.cyan)
                    }.padding(.top, 8)

                    // BEMENET VÁLASZTÓ (Az aktív bemenet ragyogó kék!)
                    panel {
                        Text("AKTÍV BEMENET").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
                        
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                            ForEach(inputs.indices, id: \.self) { i in
                                Button {
                                    controller.status.inputIndex = i
                                    controller.status.input = inputs[i]
                                    controller.send("INPUT:\(i)")
                                } label: {
                                    Text(inputs[i])
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        // Dinamikus kék kiemelés az aktív gombra!
                                        .background(controller.status.inputIndex == i ? Color.cyan : Color.white.opacity(0.08))
                                        .foregroundStyle(controller.status.inputIndex == i ? Color.black : Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .shadow(color: controller.status.inputIndex == i ? Color.cyan.opacity(0.5) : Color.clear, radius: 6)
                                }
                            }
                        }
                    }

                    // HANGERŐ & NÉMÍTÁS
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
                            controller.status.mute.toggle()
                            controller.send("MUTE:\(controller.status.mute ? 1 : 0)")
                        } label: {
                            Label(controller.status.mute ? "Némítás feloldása" : "Némítás", systemImage: controller.status.mute ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .frame(maxWidth: .infinity).padding(12)
                                .background(controller.status.mute ? Color.red.opacity(0.8) : Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }.foregroundStyle(.white)
                    }

                    // ÖTSÁVOS EQ
                    panel {
                        Text("ÖTSÁVOS EQ").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
                        ForEach(0..<5, id: \.self) { i in
                            VStack(spacing: 4) {
                                HStack {
                                    Text(bands[i]).foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Text("\(controller.status.eq.indices.contains(i) ? controller.status.eq[i] : 0) dB").foregroundStyle(.cyan).monospacedDigit()
                                }.font(.subheadline)
                                Slider(value: Binding(
                                    get: { Double(controller.status.eq.indices.contains(i) ? controller.status.eq[i] : 0) },
                                    set: { value in
                                        while controller.status.eq.count < 5 { controller.status.eq.append(0) }
                                        controller.status.eq[i] = Int(value)
                                    }
                                ), in: -12...12, step: 1) { editing in
                                    if !editing { controller.send("EQ:\(i):\(controller.status.eq[i])") }
                                }.tint(.cyan)
                            }
                        }
                    }
                }.padding(.horizontal, 16)
            }
        }
    }
}

// ------------------------------------------
// 2. INTERNET RÁDIÓ CSATORNAVÁLASZTÓ NÉZET
// ------------------------------------------
struct RadioView: View {
    @ObservedObject var controller: HiFiController
    
    let stations: [RadioStation] = [
        RadioStation(id: 0, name: "Rádió 1", freqOrGenre: "Pop / Mai slágerek", icon: "music.note"),
        RadioStation(id: 1, name: "Retro Rádió", freqOrGenre: "70-es, 80-as, 90-es évek", icon: "guitars.fill"),
        RadioStation(id: 2, name: "Rádió Rock", freqOrGenre: "Klasszikus & Modern Rock", icon: "bolt.heart.fill"),
        RadioStation(id: 3, name: "Music FM", freqOrGenre: "Dance & House Hits", icon: "headphones"),
        RadioStation(id: 4, name: "Petőfi Rádió", freqOrGenre: "Magyar & Indie Zene", icon: "star.fill"),
        RadioStation(id: 5, name: "Klubrádió", freqOrGenre: "Hírek & Beszélgetések", icon: "mic.fill")
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.025, green: 0.07, blue: 0.12), Color(red: 0.05, green: 0.15, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("INTERNET RÁDIÓ").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(Color.cyan)
                            Text("CSATORNA VÁLASZTÁS").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Image(systemName: "radio").font(.system(size: 26, weight: .medium)).foregroundStyle(.cyan)
                    }.padding(.top, 8)

                    panel {
                        Text("AKTUÁLIS ADÓ").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right").font(.title).foregroundStyle(.cyan)
                            Text(controller.status.currentRadio).font(.title2.bold()).foregroundStyle(.white)
                        }
                    }

                    // Adók Listája
                    VStack(spacing: 10) {
                        ForEach(stations) { station in
                            Button {
                                controller.status.currentRadio = station.name
                                // Automatikusan átvált Internet Radio bemenetre (4-es index) és elküldi a rádió ID-t
                                controller.status.inputIndex = 4
                                controller.status.input = "Internet radio"
                                controller.send("INPUT:4")
                                controller.send("RADIO:\(station.id)")
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: station.icon)
                                        .font(.title2)
                                        .frame(width: 44, height: 44)
                                        .background(controller.status.currentRadio == station.name ? Color.cyan : Color.white.opacity(0.1))
                                        .foregroundStyle(controller.status.currentRadio == station.name ? Color.black : Color.cyan)
                                        .clipShape(Circle())
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(station.name).font(.headline).foregroundStyle(.white)
                                        Text(station.freqOrGenre).font(.caption).foregroundStyle(.white.opacity(0.6))
                                    }
                                    Spacer()
                                    if controller.status.currentRadio == station.name {
                                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.cyan)
                                    }
                                }
                                .padding(12)
                                .background(controller.status.currentRadio == station.name ? Color.cyan.opacity(0.15) : Color(

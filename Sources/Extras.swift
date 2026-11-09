import AppKit
import CoreAudio
import SwiftUI

private let green = Color(red: 0.2, green: 0.84, blue: 0.4)

// MARK: - Animasi charging

/// Colok charger: baterai keisi pelan, petir, persentase, dan perkiraan penuh.
struct ChargingPopup: View {
    let percent: Int
    let minutesToFull: Int?
    @State private var fill: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1.5)
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(green)
                        .frame(width: max(3, 36 * fill), height: 14)
                        .padding(.leading, 3)
                    Image(systemName: "bolt.fill").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .frame(maxWidth: .infinity)
                        .symbolEffect(.bounce, value: fill)
                }
                .frame(width: 42, height: 20)
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.45)).frame(width: 2.5, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Charging").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 11)).foregroundStyle(dim)
            }
            Spacer(minLength: 6)
            Text("\(percent)%").font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(green)
        }
        .padding(.horizontal, 14)
        .onAppear {
            withAnimation(.spring(response: 1.2, dampingFraction: 0.85).delay(0.2)) { fill = CGFloat(percent) / 100 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Charging, \(percent) percent")
    }

    private var detail: String {
        guard let m = minutesToFull, m > 0 else { return percent >= 100 ? "Fully charged" : "Connected to power" }
        return m >= 60 ? "\(m / 60) hr \(m % 60) min until full" : "\(m) min until full"
    }
}

// MARK: - Notch kosong: gantian cuaca, jam, sholat berikutnya

struct IdleCarousel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var w = WeatherStore.shared

    private enum Item: Hashable { case weather, clock, prayer }

    var body: some View {
        // MacBook ber-notch: pas diem island cuma seukuran notch kamera (nyaru), isinya muncul pas di-hover
        if (model.slim || model.notch != nil) && !model.hovering {
            Color.clear
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                let items: [Item] = (w.temp != nil ? [.weather] : []) + [.clock, .prayer]
                let item = items[Int(ctx.date.timeIntervalSince1970 / 5) % items.count]
                content(item, now: ctx.date)
                    .id(item)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: item)
            }
        }
    }

    @ViewBuilder private func content(_ item: Item, now: Date) -> some View {
        Group {
            if model.notch != nil {
                // Ikon di kiri notch, tulisan di kanan notch
                HStack(spacing: 0) {
                    icon(item)
                    Spacer(minLength: 6)
                    label(item, now: now)
                }
                .padding(.horizontal, 12)
            } else {
                HStack(spacing: 5) {
                    icon(item)
                    label(item, now: now)
                }
                .fixedSize()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
    }

    @ViewBuilder private func icon(_ item: Item) -> some View {
        switch item {
        case .weather:
            Image(systemName: WeatherStore.symbol(w.code, day: w.isDay)).symbolRenderingMode(.multicolor).font(.system(size: 11))
        case .clock:
            Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(dim)
        case .prayer:
            Image(systemName: "moon.stars.fill").font(.system(size: 10)).foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.66))
        }
    }

    @ViewBuilder private func label(_ item: Item, now: Date) -> some View {
        switch item {
        case .weather:
            Text("\(Int((w.temp ?? 0).rounded()))°").monospacedDigit()
        case .clock:
            Text(now, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute()).monospacedDigit()
        case .prayer:
            let next = model.prayers.next(after: now)
            Text("\(next.name.title) \(prayerClock(next.date, model.prayers.place.timeZone))").monospacedDigit().fixedSize()
        }
    }
}

// MARK: - AirPods / headphone Bluetooth tersambung

enum BluetoothInfo {
    /// Baterai dari `system_profiler SPBluetoothDataType -json`, contoh "L 80% · R 78% · Case 50%".
    static func battery(fromProfilerJSON data: Data, name: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ctrl = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = ctrl["device_connected"] as? [[String: Any]] else { return nil }
        let wanted = name.lowercased()
        let match = connected.compactMap { $0.first }.first { $0.key.lowercased() == wanted }
            ?? connected.compactMap { $0.first }.first { wanted.contains($0.key.lowercased()) || $0.key.lowercased().contains(wanted) }
        guard let info = match?.value as? [String: Any] else { return nil }
        let parts: [(String, String)] = [("L", "device_batteryLevelLeft"), ("R", "device_batteryLevelRight"), ("Case", "device_batteryLevelCase"), ("Battery", "device_batteryLevelMain")]
        let out = parts.compactMap { label, key in (info[key] as? String).map { "\(label) \($0)" } }
        return out.isEmpty ? nil : out.joined(separator: " · ")
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("speaker") || n.contains("jbl") { return "hifispeaker.fill" }
        return "headphones"
    }

    static func deviceName(_ id: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
        return n as String
    }

    static func isBluetooth(_ id: AudioObjectID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Jalanin system_profiler di belakang (cuma pas perangkat baru nyambung).
    static func fetchBattery(name: String, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return DispatchQueue.main.async { done(nil) } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = battery(fromProfilerJSON: data, name: name)
            DispatchQueue.main.async { done(text) }
        }
    }
}

struct DevicePopup: View {
    let name: String
    let symbol: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(Circle().fill(.white.opacity(0.12)))
                .symbolEffect(.bounce, value: name)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(dim).lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(green)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) connected. \(detail)")
    }
}

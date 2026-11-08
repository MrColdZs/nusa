import AppKit
import SwiftUI

/// Cuaca dari Open-Meteo (gratis, tanpa akun) buat kota yang dipilih di tab Prayer.
final class WeatherStore: ObservableObject {
    static let shared = WeatherStore()

    struct Hour: Identifiable {
        let time: Date
        let temp: Double
        let rain: Int
        let code: Int
        var id: Date { time }
    }

    @Published private(set) var temp: Double?
    @Published private(set) var feels: Double?
    @Published private(set) var humidity: Int?
    @Published private(set) var code = 0
    @Published private(set) var isDay = true
    @Published private(set) var hours: [Hour] = []
    /// Dipanggil kalau kemungkinan hujan tinggi dalam 2 jam ke depan.
    var onRain: ((Hour) -> Void)?
    var place: () -> PrayerTimes.Place = { .cikarang }
    private var lastRainAlert = Date.distantPast
    private var timer: Timer?

    func start() {
        refresh()
        let t = Timer(timeInterval: 900, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let p = place()
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(p.latitude)), .init(name: "longitude", value: String(p.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            .init(name: "forecast_hours", value: "8"), .init(name: "timeformat", value: "unixtime"),
        ]
        URLSession.shared.dataTask(with: c.url!) { [weak self] data, _, _ in
            guard let obj = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
                  let cur = obj["current"] as? [String: Any], let h = obj["hourly"] as? [String: Any] else { return }
            let times = h["time"] as? [Double] ?? []
            let temps = h["temperature_2m"] as? [Double] ?? []
            let rains = h["precipitation_probability"] as? [Int] ?? []
            let codes = h["weather_code"] as? [Int] ?? []
            let hours = times.indices.compactMap { i -> Hour? in
                guard i < temps.count, i < codes.count else { return nil }
                return Hour(time: Date(timeIntervalSince1970: times[i]), temp: temps[i], rain: i < rains.count ? rains[i] : 0, code: codes[i])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.temp = cur["temperature_2m"] as? Double
                self.feels = cur["apparent_temperature"] as? Double
                self.humidity = cur["relative_humidity_2m"] as? Int
                self.code = cur["weather_code"] as? Int ?? 0
                self.isDay = (cur["is_day"] as? Int ?? 1) == 1
                self.hours = hours
                self.checkRain()
            }
        }.resume()
    }

    /// Paling banyak sekali tiap 3 jam, biar nggak cerewet pas musim hujan.
    private func checkRain(now: Date = Date()) {
        guard now.timeIntervalSince(lastRainAlert) > 3 * 3600,
              let hour = hours.first(where: { $0.time > now.addingTimeInterval(-1800) && $0.time < now.addingTimeInterval(7200) && $0.rain >= 60 })
        else { return }
        // Udah hujan sekarang? nggak usah diingetin
        guard !WeatherStore.isRain(code) else { return }
        lastRainAlert = now
        onRain?(hour)
    }

    static func isRain(_ code: Int) -> Bool { (51...67).contains(code) || (80...82).contains(code) || code >= 95 }

    /// Kode cuaca WMO ke SF Symbol.
    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61, 63, 80, 81: "cloud.rain.fill"
        case 65, 66, 67, 82: "cloud.heavyrain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func label(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61, 63, 80, 81: "Rain"
        case 65, 66, 67, 82: "Heavy rain"
        case 95...99: "Thunderstorm"
        default: "Cloudy"
        }
    }
}

/// Chip cuaca di bar atas panel; klik buat prakiraan per jam.
struct WeatherChip: View {
    @ObservedObject private var w = WeatherStore.shared
    @ObservedObject var model: IslandModel
    @State private var hovering = false

    var body: some View {
        if let t = w.temp {
            Button { forecastMenu() } label: {
                HStack(spacing: 5) {
                    Image(systemName: WeatherStore.symbol(w.code, day: w.isDay)).symbolRenderingMode(.multicolor).font(.system(size: 12))
                    Text("\(Int(t.rounded()))°").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 26)
                .background(Capsule().fill(.white.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(Press())
            .onHover { hovering = $0 }
            .help("\(WeatherStore.label(w.code)) · feels \(Int((w.feels ?? t).rounded()))° · \(w.humidity ?? 0)% humidity")
            .accessibilityLabel("Weather \(WeatherStore.label(w.code)), \(Int(t.rounded())) degrees")
        }
    }

    private func forecastMenu() {
        let wasPinned = model.pinned
        model.pinned = true
        let menu = NSMenu()
        let place = model.prayers.place
        menu.addItem(.sectionHeader(title: "\(place.name) · \(WeatherStore.label(w.code)) · feels \(Int((w.feels ?? 0).rounded()))°"))
        let f = DateFormatter()
        f.timeZone = place.timeZone
        f.dateFormat = "HH:mm"
        for h in w.hours where h.time > Date().addingTimeInterval(-1800) {
            let item = NSMenuItem(title: "\(f.string(from: h.time))    \(Int(h.temp.rounded()))°    rain \(h.rain)%", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: WeatherStore.symbol(h.code), accessibilityDescription: nil)
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Data: Open-Meteo"))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.pinned = wasPinned
    }
}

struct RainPopup: View {
    let time: String
    let chance: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "umbrella.fill").font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.multicolor)
                .frame(width: 36, height: 36).background(Circle().fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Rain likely around \(time)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("\(chance)% chance · bring an umbrella").font(.system(size: 11)).foregroundStyle(dim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

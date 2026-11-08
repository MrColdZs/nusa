import AppKit
import Combine
import SwiftUI

struct Media: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var source: String?
    var duration = 0.0
    var elapsed = 0.0
    var timestamp = 0.0
    var rate = 0.0
    var playing = false
    var artId: String?

    var exists: Bool { !title.isEmpty }

    func position(at now: Date) -> Double {
        let moved = playing ? max(0, now.timeIntervalSince1970 - timestamp) * max(rate, 1) : 0
        let p = elapsed + moved
        return duration > 0 ? min(p, duration) : p
    }
}

enum Flash: Equatable {
    case charging(percent: Int, on: Bool)
    case lowBattery(percent: Int)
    case volume(level: Double, muted: Bool)
    case timerDone
    case track
    case prayer(name: String, time: String, soon: Bool)
    case task(id: String, title: String, time: String)
    case rain(time: String, chance: Int)
    case focusEnd(rest: Bool, title: String?)
    case device(name: String, symbol: String, detail: String)
}

enum Presentation: Equatable {
    case idle, music, timer, focus, flash(Flash), expanded

    /// Kunci konten: ganti isi cuma kalau jenisnya berubah, bukan tiap nilai volume berubah.
    var kind: String {
        switch self {
        case .idle: "idle"
        case .music: "music"
        case .timer: "timer"
        case .focus: "focus"
        case .expanded: "expanded"
        case .flash(let f):
            switch f {
            case .charging: "charging"
            case .lowBattery: "low"
            case .volume: "volume"
            case .timerDone: "done"
            case .track: "track"
            case .prayer: "prayer"
            case .task: "task"
            case .rain: "rain"
            case .focusEnd: "focusEnd"
            case .device: "device"
            }
        }
    }
}

enum PanelTab { case home, music, tasks, tray, clips, prayer, quran }

/// Ukuran badan notch. `shoulder` = lengkung cekung yang nyambung ke tepi atas layar.
struct IslandSize: Equatable {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var shoulder: CGFloat = 7

    var totalWidth: CGFloat { width + shoulder * 2 }
}

final class IslandModel: ObservableObject {
    @Published var media = Media()
    @Published var art: NSImage?
    @Published var tint = Color.white
    @Published var flash: Flash?
    @Published var expanded = false
    @Published var hovering = false
    /// Layar penuh tanpa menu bar: tinggal bibir tipis biar tab browser nggak ketutup.
    @Published var slim = false
    @Published var pinned = false
    @Published var tab = PanelTab.home
    @Published var shelf: [URL] = IslandModel.loadShelf()
    @Published var volume = 0.5
    @Published var minutesToFull: Int?
    /// Cover punya warna yang cukup hidup buat jadi aksen panel.
    @Published var tintVivid = false
    @Published var focus: FocusSession?
    var focusWork: DispatchWorkItem?
    /// Dorongan kecil ke samping sebagai tanda swipe kebaca.
    @Published var nudge: CGFloat = 0
    /// Lebar maksimal notch biar nggak numpuk ikon menu bar.
    @Published var compactLimit: CGFloat = .infinity
    let calendar = CalendarModel()
    @Published var prayers = PrayerTimes(place: .named(UserDefaults.standard.string(forKey: "prayerPlace"))) {
        didSet { UserDefaults.standard.set(prayers.place.name, forKey: "prayerPlace") }
    }
    enum PrayerSound: String { case adzan, tone, silent }
    @Published var prayerSound = PrayerSound(rawValue: UserDefaults.standard.string(forKey: "prayerSound") ?? "") ?? .adzan {
        didSet { UserDefaults.standard.set(prayerSound.rawValue, forKey: "prayerSound") }
    }
    @Published var prayerSoon = UserDefaults.standard.object(forKey: "prayerSoon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(prayerSoon, forKey: "prayerSoon") }
    }
    @Published var prayerAlerts = UserDefaults.standard.object(forKey: "prayerAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(prayerAlerts, forKey: "prayerAlerts") }
    }
    @Published var pauseForPrayer = UserDefaults.standard.object(forKey: "pauseForPrayer") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseForPrayer, forKey: "pauseForPrayer") }
    }
    /// File adzan pilihan user; kosong berarti bunyi pengingat bawaan.
    @Published var adzanPath = UserDefaults.standard.string(forKey: "adzanPath") {
        didSet { UserDefaults.standard.set(adzanPath, forKey: "adzanPath") }
    }
    private var alertSound: NSSound?

    /// `preview`: cuplikan 4 detik pas user milih mode suara.
    func playPrayerSound(preview: Bool = false) {
        alertSound?.stop()
        guard prayerSound != .silent else { return }
        // Adzan: file pilihan user kalau ada, kalau nggak rekaman bawaan (assets/CREDITS.md)
        let adzanFile = adzanPath ?? Bundle.main.path(forResource: "adhan", ofType: "mp3")
        let custom = prayerSound == .adzan ? adzanFile.flatMap { NSSound(contentsOfFile: $0, byReference: true) } : nil
        let sound = custom ?? NSSound(named: "Glass")
        alertSound = sound
        sound?.play()
        if preview, custom != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak sound] in
                if self?.alertSound === sound { sound?.stop() }
            }
        }
    }

    func stopPrayerSound() { alertSound?.stop() }

    func dismissPrayer() {
        stopPrayerSound()
        flash = nil
    }
    let clips = ClipHistory()
    var setVolume: (Double) -> Void = { _ in }
    @Published var timerEnd: Date?
    @Published var timerTotal = 0.0
    @Published var batteryPercent = 100
    @Published var charging = false

    var send: (String) -> Void = { _ in }
    private var flashWork: DispatchWorkItem?
    private var timerWork: DispatchWorkItem?

    var timerRunning: Bool { timerEnd != nil }

    var presentation: Presentation {
        if expanded { return .expanded }
        if let flash { return .flash(flash) }
        if slim, !hovering { return .idle }
        if focus != nil { return .focus }
        if media.exists { return .music }
        if timerRunning { return .timer }
        return .idle
    }

    /// Menu bar tingginya 25pt. Notch harus muat di situ biar nggak nutup tab browser.
    /// Hover cuma melebarin dikit; panel gede baru kebuka kalau diklik.
    var size: IslandSize {
        let bump: CGFloat = hovering ? 12 : 0
        func compact(_ width: CGFloat) -> IslandSize {
            IslandSize(width: min(width, compactLimit), height: 24, radius: 9)
        }
        switch presentation {
        case .idle:
            if slim, !hovering { return IslandSize(width: 148, height: 6, radius: 3, shoulder: 3) }
            return compact(150 + bump)
        case .music: return compact((timerRunning ? 268 : 248) + bump)
        case .timer: return compact(168 + bump)
        case .focus: return compact(250 + bump)
        case .flash(let f):
            if f == .track { return IslandSize(width: 318, height: 60, radius: 20, shoulder: 10) }
            if case .prayer = f { return IslandSize(width: 318, height: 60, radius: 20, shoulder: 10) }
            if case .task = f { return IslandSize(width: 340, height: 60, radius: 20, shoulder: 10) }
            if case .rain = f { return IslandSize(width: 318, height: 60, radius: 20, shoulder: 10) }
            if case .focusEnd = f { return IslandSize(width: 360, height: 60, radius: 20, shoulder: 10) }
            if case .device = f { return IslandSize(width: 330, height: 60, radius: 20, shoulder: 10) }
            if case .charging(_, true) = f { return IslandSize(width: 300, height: 58, radius: 20, shoulder: 10) }
            return compact(232)
        case .expanded: return IslandSize(width: 760, height: tab == .prayer ? 204 : tab == .quran ? 400 : tab == .music || tab == .tasks ? 330 : 190, radius: 26, shoulder: 14)
        }
    }

    private static func loadShelf() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "shelf") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func addToShelf(_ url: URL) {
        guard !shelf.contains(url) else { return }
        shelf.append(url)
        saveShelf()
    }

    func removeFromShelf(_ url: URL) {
        shelf.removeAll { $0 == url }
        saveShelf()
    }

    private func saveShelf() {
        UserDefaults.standard.set(shelf.map(\.path), forKey: "shelf")
    }

    func show(_ f: Flash, for seconds: Double = 2) {
        flashWork?.cancel()
        flash = f
        let work = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func startTimer(minutes: Int) {
        let total = Double(minutes) * 60
        timerTotal = total
        timerEnd = Date().addingTimeInterval(total)
        timerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.timerEnd = nil
            NSSound(named: "Glass")?.play()
            self?.show(.timerDone, for: 4)
        }
        timerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: work)
    }

    func stopTimer() {
        timerWork?.cancel()
        timerEnd = nil
    }

    func setArt(_ image: NSImage?) {
        art = image
        let accent = image.flatMap(Self.accent)
        tint = accent ?? .white
        tintVivid = accent != nil
    }

    /// Warna paling hidup dari cover, dicerahin biar kebaca di atas hitam.
    static func accent(from image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 24
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var best: (score: CGFloat, h: CGFloat, s: CGFloat, b: CGFloat)?
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = NSColor(srgbRed: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255, blue: CGFloat(px[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            let score = s * b
            if score > (best?.score ?? 0.12) { best = (score, h, s, b) }
        }
        guard let best else { return nil }
        return Color(hue: Double(best.h), saturation: Double(min(best.s, 0.75)), brightness: Double(max(best.b, 0.88)))
    }
}

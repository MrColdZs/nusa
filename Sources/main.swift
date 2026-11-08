// Nusa: Dynamic Island buat Mac. Jendela transparan di tengah atas layar, isinya kapsul SwiftUI.
import AppKit
import Combine
import SwiftUI

/// Harus lebih gede dari panel terbesar + bayangannya, kalau nggak jendela ikut molor keluar layar.
private let canvas = NSSize(width: 840, height: 440)

private extension String {
    func appendTo(_ path: String) throws {
        let h = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)!
        }()
        h.seekToEndOfFile()
        h.write(Data(utf8))
        h.closeFile()
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class IslandHost: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    private var panel: IslandPanel!
    private var bridge: MediaBridge!
    private var battery: BatteryWatcher!
    private var volume: VolumeWatcher!
    private var prayer: PrayerWatcher!
    private var pending: DispatchWorkItem?
    private var inside = false
    private var swipeDetector = SwipeDetector()
    private var watch: AnyCancellable?
    private var dragBaseline = NSPasteboard(name: .drag).changeCount

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let host = IslandHost(rootView: IslandView(model: model))
        // Ukuran jendela dikunci; SwiftUI nggak boleh ngubahnya sendiri
        host.sizingOptions = []
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            self?.place()
        }
        place()
        panel.orderFrontRegardless()

        bridge = MediaBridge(model: model)
        // Mode tes notch kosong: pembaca lagu nggak dinyalain
        if ProcessInfo.processInfo.environment["NUSA_TEST_IDLE"] == nil { bridge.start() }
        battery = BatteryWatcher(model: model)
        battery.start()
        volume = VolumeWatcher(model: model)
        volume.start()
        model.clips.start()
        prayer = PrayerWatcher(model: model)
        prayer.start()
        TaskStore.shared.onDue = { [weak self] task in
            guard let self else { return }
            if !self.model.pinned { self.model.expanded = false }
            NSSound(named: "Tink")?.play()
            self.model.show(.task(id: task.id, title: task.title, time: task.due.map { dueText($0) } ?? ""), for: 30)
        }
        TaskStore.shared.start()
        WeatherStore.shared.place = { [weak self] in self?.model.prayers.place ?? .cikarang }
        WeatherStore.shared.onRain = { [weak self] hour in
            guard let self, self.model.focus?.phase != .focus else { return }
            let f = DateFormatter()
            f.timeZone = self.model.prayers.place.timeZone
            f.dateFormat = "HH:mm"
            self.model.show(.rain(time: f.string(from: hour.time), chance: hour.rain), for: 8)
        }
        WeatherStore.shared.start()

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] e in self?.track(e) }
        NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] e in self?.track(e); return e }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.swipe(e); return e }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            self.dragBaseline = NSPasteboard(name: .drag).changeCount
            if self.model.expanded, !self.model.pinned { self.model.expanded = false }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.place() }
        let spaces = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            spaces.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.syncSoon() }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.syncVisibility() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        syncVisibility()

        // Mode tes satu tab: buka panel di tab itu, potret, lalu tutup lagi
        if let tab = ProcessInfo.processInfo.environment["NUSA_SHOT_TAB"], let dir = ProcessInfo.processInfo.environment["NUSA_SHOT_DIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                guard tab != "none" else { return } // "none" = potret notch kecil
                if let q = ProcessInfo.processInfo.environment["NUSA_SHOT_QUERY"] { MusicRemote.shared.query = q }
                model.tab = ["home": .home, "music": .music, "tasks": .tasks, "tray": .tray, "clips": .clips, "prayer": .prayer, "quran": .quran][tab] ?? .home
                model.pinned = true
                model.expanded = true
            }
            // Tes pop-up: charging & perangkat Bluetooth
            if ProcessInfo.processInfo.environment["NUSA_TEST_POPUPS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in model.minutesToFull = 74; model.show(.charging(percent: 63, on: true), for: 3.5) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { self.snapTab(dir, "charging") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [self] in
                    model.show(.device(name: "AirPods Pro Quraish", symbol: BluetoothInfo.symbol(for: "AirPods Pro Quraish"), detail: "L 80% · R 78% · Case 52%"), for: 4)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.8) { self.snapTab(dir, "device") }
                if ProcessInfo.processInfo.environment["NUSA_TEST_IDLE"] != nil {
                    for (i, t) in [9.0, 14.0, 19.0].enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.snapTab(dir, "idle-\(i)") }
                    }
                }
                return
            }
            // Tes fokus: sesi pendek, potret pas jalan & pas selesai, terus pop-up hujan
            if let secs = Double(ProcessInfo.processInfo.environment["NUSA_TEST_FOCUS"] ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    model.startFocus(minutes: secs / 60, task: TaskItem(title: "Kirim laporan Cpk"))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.snapTab(dir, "focus-run") }
                DispatchQueue.main.asyncAfter(deadline: .now() + secs + 3) { self.snapTab(dir, "focus-end") }
                DispatchQueue.main.asyncAfter(deadline: .now() + secs + 4) { [self] in model.show(.rain(time: "15:00", chance: 70), for: 8) }
                DispatchQueue.main.asyncAfter(deadline: .now() + secs + 5.5) { self.snapTab(dir, "rain") }
                return
            }
            // Tes murottal: putar dari ayat tertentu, catat ayat yang kebaca tiap detik
            if let spec = ProcessInfo.processInfo.environment["NUSA_TEST_RECITE"] {
                let p = spec.split(separator: ":").compactMap { Int($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { QuranReader.shared.open(p[0]); QuranReader.shared.recite(from: p[0], p[1]) }
                for sec in 3...24 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(sec)) {
                        let r = QuranReader.shared.reciting
                        try? "\(sec)s \(r.map { "\($0.surah):\($0.ayah)" } ?? "stop") playing=\(QuranReader.shared.audioPlaying)\n".appendTo(dir + "/recite.log")
                        if sec == 8 { self.snapTab(dir, "recite") }
                    }
                }
                return
            }
            let shotDelay = Double(ProcessInfo.processInfo.environment["NUSA_SHOT_DELAY"] ?? "") ?? 2.6
            DispatchQueue.main.asyncAfter(deadline: .now() + shotDelay) { [self] in
                if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), .bestResolution),
                   let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tab-\(tab).png"))
                }
                model.pinned = false
                model.expanded = false
            }
        }
        if let dir = ProcessInfo.processInfo.environment["NUSA_TRACE"] {
            let delay = Double(ProcessInfo.processInfo.environment["NUSA_TRACE_DELAY"] ?? "") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in trace(to: dir) }
        }
        if let file = ProcessInfo.processInfo.environment["NUSA_WATCH"] {
            watch = model.$expanded.sink { try? "\($0)\n".appendTo(file) }
        }
    }

    /// Mode tes: buka-tutup sendiri sambil motret tiap frame. Nggak butuh izin Screen Recording.
    private func trace(to dir: String) {
        func snap(_ name: String) {
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), .bestResolution),
                  let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        func film(_ prefix: String, _ open: Bool, after: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in model.expanded = open }
            for i in 0..<10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + after + Double(i) * 0.06) { snap("\(prefix)-\(i)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { snap("rest") }
        film("open", true, after: 2)
        let steps: [(Double, () -> Void, String)] = [
            (3.0, {}, "home"),
            (3.2, { [self] in model.tab = .tray; model.shelf = [URL(fileURLWithPath: "/System/Applications/Music.app"), URL(fileURLWithPath: "/etc/hosts")] }, ""),
            (3.6, {}, "tray"),
            (3.7, { [self] in model.tab = .clips; model.clips.seed(["Link grup Belajar AI Cikarang", "Rapat QC jam 9 pagi di ruang meeting lantai 2", "git push origin main"]) }, ""),
            (4.1, {}, "clips"),
            (4.2, { [self] in model.tab = .prayer }, ""),
            (4.5, {}, "prayer"),
            (4.55, { [self] in model.tab = .quran }, ""),
            (4.95, {}, "quran"),
            (5.0, { [self] in model.tab = .home; model.shelf = [] }, ""),
        ]
        for (t, run, name) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { run(); if !name.isEmpty { snap(name) } }
        }
        film("close", false, after: 5.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.9) { [self] in model.show(.track, for: 2.6) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) { snap("track") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.4) { [self] in model.show(.prayer(name: "Maghrib", time: "17:48", soon: false), for: 3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.1) { snap("prayer-now") }
    }

    func applicationWillTerminate(_ note: Notification) { bridge.stop() }

    /// Layar penuh tanpa menu bar: tab browser naik ke paling atas, jadi island harus menipis.
    private func menuBarHidden() -> Bool {
        guard let screen = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        var menuBar = false
        var firstIcon = CGFloat.infinity
        for w in list {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict) else { continue }
            let layer = w[kCGWindowLayer as String] as? Int
            if layer == 24, w[kCGWindowOwnerName as String] as? String == "Window Server",
               b.minY == 0, b.width >= screen.frame.width { menuBar = true }
            if layer == 25, b.minY == 0, b.minX > screen.frame.midX {
                firstIcon = min(firstIcon, b.minX)
                menuBar = true
            }
        }
        if firstIcon.isFinite {
            // Notch simetris di tengah: setengah lebarnya nggak boleh lewat ikon pertama, sisain 8pt
            let limit = max(96, (firstIcon - screen.frame.midX - 8) * 2 - 14)
            if limit != model.compactLimit { model.compactLimit = limit }
        }
        return !menuBar
    }

    func snapTab(_ dir: String, _ name: String) {
        if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), .bestResolution),
           let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func syncVisibility() {
        let hidden = menuBarHidden()
        if hidden != model.slim { model.slim = hidden }
    }

    /// Pindah Space butuh waktu, jadi dicek beberapa kali di awal biar nggak nunggu timer.
    private func syncSoon() {
        syncVisibility()
        for delay in [0.12, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.syncVisibility() }
        }
    }

    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        let frame = NSRect(x: screen.frame.midX - canvas.width / 2, y: screen.frame.maxY - canvas.height, width: canvas.width, height: canvas.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Klik di luar notch harus tembus ke app di belakangnya.
    private func islandRect() -> NSRect {
        var s = model.size
        // Pop-up lagu cuma buat dilihat: bagian bawahnya tembus klik biar tab tetap bisa dipencet
        if model.flash == .track { s.height = 24 }
        return NSRect(x: panel.frame.midX - s.totalWidth / 2, y: panel.frame.maxY - s.height, width: s.totalWidth, height: s.height)
    }

    /// Usap kiri = lagu berikutnya, usap kanan = lagu sebelumnya.
    private func swipe(_ e: NSEvent) {
        guard !model.expanded, model.media.exists, e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }
        // Natural scrolling ngebalik tanda delta; yang dipakai arah jari aslinya
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        let action = swipeDetector.feed(began: e.phase == .began, ended: e.phase == .ended || e.phase == .cancelled,
                                        dx: e.scrollingDeltaX * sign, dy: e.scrollingDeltaY * sign)
        guard let action else { return }
        model.send(action == .next ? "next" : "prev")
        model.nudge = action == .next ? -7 : 7
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in self?.model.nudge = 0 }
    }

    private func track(_ event: NSEvent) {
        // Waktu masih notch, area hover nggak boleh lewat dari menu bar
        let rect = model.expanded ? islandRect().insetBy(dx: -6, dy: -6) : islandRect()
        let over = panel.isVisible && rect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !over

        // File diseret ke notch: langsung buka Rak
        let drag = NSPasteboard(name: .drag)
        if over, event.type == .leftMouseDragged, drag.changeCount != dragBaseline,
           drag.types?.contains(.fileURL) == true {
            model.tab = .tray
            model.expanded = true
        }

        guard over != inside else { return }
        inside = over
        model.hovering = over
        pending?.cancel()
        guard !over else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.inside, !self.model.pinned else { return }
            self.model.expanded = false
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

/// `Nusa --render <folder>`: gambar tiap keadaan ke PNG buat dicek tanpa perlu layar.
@MainActor func renderStates(to dir: String) {
    func model(_ set: (IslandModel) -> Void) -> IslandModel {
        let m = IslandModel()
        m.batteryPercent = 83
        set(m)
        return m
    }
    let art = CommandLine.arguments.count > 3 ? NSImage(contentsOfFile: CommandLine.arguments[3]) : nil
    func music(_ m: IslandModel) {
        m.media = Media(title: "Manchild", artist: "Sabrina Carpenter", duration: 213, elapsed: 74,
                        timestamp: Date().timeIntervalSince1970, rate: 0, playing: true)
        m.setArt(art)
    }
    let states: [(String, IslandModel)] = [
        ("idle", model { _ in }),
        ("track", model { music($0); $0.flash = .track }),
        ("slim", model { music($0); $0.slim = true }),
        ("music", model(music)),
        ("music-limit", model { music($0); $0.compactLimit = 192 }),
        ("music-limit-timer", model { music($0); $0.compactLimit = 192; $0.timerTotal = 900; $0.timerEnd = Date().addingTimeInterval(600) }),
        ("flash-limit", model { $0.compactLimit = 192; $0.flash = .charging(percent: 83, on: false) }),
        ("music-timer", model { music($0); $0.timerTotal = 1500; $0.timerEnd = Date().addingTimeInterval(900) }),
        ("timer", model { $0.timerTotal = 300; $0.timerEnd = Date().addingTimeInterval(272) }),
        ("charging", model { $0.flash = .charging(percent: 83, on: true) }),
        ("low", model { $0.flash = .lowBattery(percent: 18) }),
        ("volume", model { $0.flash = .volume(level: 0.62, muted: false) }),
        ("expanded-music", model { music($0); $0.expanded = true }),
        ("expanded-empty", model { $0.expanded = true }),
        ("expanded-timer", model { music($0); $0.timerTotal = 1500; $0.timerEnd = Date().addingTimeInterval(900); $0.expanded = true }),
        ("expanded-tray", model { $0.tab = .tray; $0.shelf = []; $0.expanded = true }),
        ("expanded-tray-files", model { $0.tab = .tray; $0.shelf = [URL(fileURLWithPath: "/System/Applications/Music.app"), URL(fileURLWithPath: "/etc/hosts")]; $0.expanded = true }),
        ("expanded-clips", model { $0.tab = .clips; $0.clips.seed(["Link grup Belajar AI Cikarang", "Rapat QC jam 9 pagi di ruang meeting lantai 2", "git push origin main"]); $0.expanded = true }),
    ]
    for (name, m) in states {
        let view = IslandView(model: m).frame(width: canvas.width, height: canvas.height)
            .background(Color(white: 0.86)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { continue }
        let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        try? data?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--render" {
    MainActor.assumeIsolated { renderStates(to: CommandLine.arguments[2]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

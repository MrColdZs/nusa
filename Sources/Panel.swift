import AVFoundation
import AppKit
import EventKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private let today = Color(red: 0.04, green: 0.52, blue: 1)

// MARK: - Data kalender

struct DayEvent: Identifiable {
    let id: String
    let title: String
    let time: String
    let color: Color
}

final class CalendarModel: ObservableObject {
    @Published var selected = Calendar.current.startOfDay(for: Date())
    @Published var events: [DayEvent] = []
    @Published var access = EKEventStore.authorizationStatus(for: .event)
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    var connected: Bool { access == .fullAccess }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    func connect() {
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.access = EKEventStore.authorizationStatus(for: .event)
                self?.reload()
            }
        }
    }

    func select(_ day: Date) {
        selected = day
        reload()
    }

    func reload() {
        guard connected, let end = Calendar.current.date(byAdding: .day, value: 1, to: selected) else {
            events = []
            return
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        events = store.events(matching: store.predicateForEvents(withStart: selected, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                DayEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Untitled",
                         time: e.isAllDay ? "All day" : f.string(from: e.startDate),
                         color: e.calendar.map { Color(nsColor: NSColor(cgColor: $0.cgColor) ?? .systemBlue) } ?? today)
            }
    }
}

// MARK: - Cermin

final class Mirror: ObservableObject {
    enum State { case off, on, denied }
    @Published var state = State.off
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "nusa.mirror")
    private var ready = false

    func toggle() {
        if state == .on { stop(); return }
        NSApp.activate(ignoringOtherApps: true)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else { self.state = .denied; return }
                self.state = .on
                self.queue.async { self.run() }
            }
        }
    }

    private func run() {
        if !ready, let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
            ready = true
        }
        session.startRunning()
    }

    func stop() {
        if state == .on { state = .off }
        queue.async { [session] in session.stopRunning() }
    }
}

private struct CameraView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Panel

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 10) {
            TopBar(model: model)
            Group {
                switch model.tab {
                case .home: HomeTab(model: model)
                case .music: MusicTab(model: model)
                case .tasks: TasksTab(model: model)
                case .tray: TrayTab(model: model, dropping: dropping)
                case .clips: ClipsTab(clips: model.clips)
                case .prayer: PrayerTab(model: model)
                case .quran: QuranTab(model: model)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            model.tab = .tray
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.addToShelf(url) } }
                }
            }
            return true
        }
    }
}

/// Tab aktif nampilin nama; yang lain cuma ikon biar lima tab tetap muat.
private struct TabButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                if selected { Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(selected || hovering ? .white : dim)
            .padding(.horizontal, selected ? 11 : 8)
            .frame(minWidth: 30, minHeight: 26)
            .background(Capsule().fill(.white.opacity(selected ? 0.14 : hovering ? 0.07 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

private struct IconButton: View {
    let symbol: String
    let label: String
    var tint = dim
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? .white : tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

private struct Chip: View {
    let text: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 28, minHeight: 22)
                .padding(.horizontal, 2)
                .background(Capsule().fill(.white.opacity(hovering ? 0.22 : 0.11)))
                .contentShape(Capsule())
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

private struct TopBar: View {
    @ObservedObject var model: IslandModel

    private var batterySymbol: String {
        if model.charging { return "battery.100percent.bolt" }
        switch model.batteryPercent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            TabButton(title: "Home", symbol: "square.grid.2x2.fill", selected: model.tab == .home) { model.tab = .home }
            TabButton(title: "Music", symbol: "music.note.list", selected: model.tab == .music) { model.tab = .music }
            TabButton(title: "Tasks", symbol: "checklist", selected: model.tab == .tasks) { model.tab = .tasks }
            TabButton(title: "Tray", symbol: "tray.fill", selected: model.tab == .tray) { model.tab = .tray }
            TabButton(title: "Clips", symbol: "doc.on.clipboard.fill", selected: model.tab == .clips) { model.tab = .clips }
            TabButton(title: "Prayer", symbol: "moon.stars.fill", selected: model.tab == .prayer) { model.tab = .prayer }
            TabButton(title: "Quran", symbol: "book.closed.fill", selected: model.tab == .quran) { model.tab = .quran }
            Spacer()
            VolumeSlider(model: model)
            Rectangle().fill(hairline).frame(width: 1, height: 14).padding(.horizontal, 6)
            if let end = model.timerEnd {
                Image(systemName: "timer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                Countdown(end: end)
                Chip(text: "Stop", label: "Stop timer") { model.stopTimer() }
            } else {
                Image(systemName: "timer").font(.system(size: 11, weight: .semibold)).foregroundStyle(dim).accessibilityHidden(true)
                ForEach([5, 15, 25], id: \.self) { m in
                    Chip(text: "\(m)m", label: "\(m)-minute timer") { model.startTimer(minutes: m) }
                }
            }
            Rectangle().fill(hairline).frame(width: 1, height: 14).padding(.horizontal, 6)
            WeatherChip(model: model)
            Image(systemName: batterySymbol)
                .font(.system(size: 12))
                .foregroundStyle(model.batteryPercent <= 20 && !model.charging ? .red : model.charging ? .green : .white)
            Text("\(model.batteryPercent)%").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white)
            IconButton(symbol: model.pinned ? "lock.fill" : "lock.open.fill",
                       label: model.pinned ? "Unlock panel" : "Keep panel open",
                       tint: model.pinned ? .white : dim) { model.pinned.toggle() }
                .padding(.leading, 4)
            IconButton(symbol: "gearshape.fill", label: "Settings") { showMenu() }
        }
        .frame(height: 26)
    }

    private func showMenu() {
        let wasPinned = model.pinned
        model.pinned = true
        let menu = NSMenu()
        let enabled = SMAppService.mainApp.status == .enabled
        let login = ActionItem(enabled ? "Don’t open at login" : "Open at login") {
            if enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Nusa") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.pinned = wasPinned
    }
}

private struct VolumeSlider: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(dim)
                .frame(width: 15)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: g.size.width * model.volume)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged {
                    let level = min(max($0.location.x / g.size.width, 0), 1)
                    model.volume = level
                    model.setVolume(level)
                })
            }
            .frame(width: 58, height: 16)
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(model.volume * 100)) percent")
    }
}

private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

private struct HomeTab: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            MusicColumn(model: model).frame(width: 250)
            Rectangle().fill(hairline).frame(width: 1).padding(.horizontal, 14)
            CalendarColumn(calendar: model.calendar)
            Rectangle().fill(hairline).frame(width: 1).padding(.horizontal, 14)
            WeatherColumn(model: model)
        }
    }
}

private struct MusicColumn: View {
    @ObservedObject var model: IslandModel
    @State private var scrub: Double?

    private var sourceURL: URL? {
        model.media.source.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    var body: some View {
        if model.media.exists {
            HStack(spacing: 13) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(image: model.art, side: 100, radius: 16)
                    if let url = sourceURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 30, height: 30)
                            .offset(x: 5, y: 5)
                            .accessibilityHidden(true)
                    }
                }
                .onTapGesture { if let url = sourceURL { NSWorkspace.shared.open(url) } }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.media.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if !model.media.album.isEmpty {
                        Text(model.media.album).font(.system(size: 11.5)).foregroundStyle(dim).lineLimit(1)
                    }
                    Text(model.media.artist).font(.system(size: 11.5)).foregroundStyle(dim).lineLimit(1)
                    HStack(spacing: 0) {
                        RoundButton(symbol: "backward.fill", label: "Previous track") { model.send("prev") }
                        RoundButton(symbol: model.media.playing ? "pause.fill" : "play.fill",
                                    label: model.media.playing ? "Pause" : "Play", size: 17) { model.send("toggle") }
                        RoundButton(symbol: "forward.fill", label: "Next track") { model.send("next") }
                    }
                    .offset(x: -7)
                    .padding(.top, 2)
                    progress
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 24, weight: .medium)).foregroundStyle(dim)
                Text("Nothing playing").font(.system(size: 12)).foregroundStyle(dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let duration = model.media.duration
            let position = scrub ?? model.media.position(at: ctx.date)
            let fraction = duration > 0 ? position / duration : 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(model.tintVivid ? model.tint : .white).frame(width: g.size.width * fraction)
                }
                .frame(height: scrub == nil ? 3 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { scrub = min(max($0.location.x / g.size.width, 0), 1) * duration }
                    .onEnded { _ in
                        if let scrub { model.send("seek \(scrub)") }
                        scrub = nil
                    })
            }
            .frame(height: 12)
            .accessibilityLabel("Track position")
            .accessibilityValue("\(clock(position)) of \(clock(duration))")
        }
    }
}

private struct CalendarColumn: View {
    @ObservedObject var calendar: CalendarModel
    private static let locale = Locale(identifier: "en_US")

    private var days: [Date] {
        let cal = Calendar.current
        let now = cal.startOfDay(for: Date())
        return (-2...4).compactMap { cal.date(byAdding: .day, value: $0, to: now) }
    }

    private func label(_ day: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Self.locale
        f.dateFormat = format
        return f.string(from: day)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(label(calendar.selected, "MMM"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, alignment: .leading)
                ForEach(days, id: \.self) { day in dayCell(day) }
            }
            agenda.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = day == calendar.selected
        return Button { calendar.select(day) } label: {
            VStack(spacing: 2) {
                Text(label(day, "EEE").prefix(3).uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(isToday ? .white : dim)
                Text(label(day, "d"))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(isToday ? today : day < cal.startOfDay(for: Date()) ? dim : .white)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(isSelected ? 0.11 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .accessibilityLabel(label(day, "EEEE, MMMM d"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var agenda: some View {
        if calendar.access == .notDetermined {
            Button { calendar.connect() } label: {
                Label("Connect Calendar", systemImage: "calendar")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(Press())
        } else if !calendar.connected {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                note("calendar.badge.exclamationmark", "Allow in System Settings")
            }
            .buttonStyle(Press())
        } else if calendar.events.isEmpty {
            note("calendar", "No events")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(calendar.events.prefix(3)) { e in
                    HStack(spacing: 6) {
                        Capsule().fill(e.color).frame(width: 3, height: 13)
                        Text(e.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(e.time).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(dim)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(dim)
            Text(text).font(.system(size: 11.5)).foregroundStyle(dim).lineLimit(1)
        }
    }
}

/// Kolom kanan Home: cuaca besar. Cermin kamera tinggal tombol kecil di pojok.
private struct WeatherColumn: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var w = WeatherStore.shared
    @StateObject private var mirror = Mirror()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if mirror.state == .on {
                CameraView(session: mirror.session)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(width: 168, height: 118)
            } else if let t = w.temp {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: WeatherStore.symbol(w.code, day: w.isDay))
                            .symbolRenderingMode(.multicolor).font(.system(size: 26))
                        Text("\(Int(t.rounded()))°").font(.system(size: 34, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    }
                    Text("\(WeatherStore.label(w.code)) · feels \(Int((w.feels ?? t).rounded()))°")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(dim).lineLimit(1)
                    Text(model.prayers.place.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    HStack(spacing: 10) {
                        ForEach(nextHours) { h in
                            VStack(spacing: 2) {
                                Text(hour(h.time)).font(.system(size: 9.5, weight: .medium)).foregroundStyle(dim)
                                Image(systemName: WeatherStore.symbol(h.code)).symbolRenderingMode(.multicolor).font(.system(size: 12))
                                Text(h.rain >= 30 ? "\(h.rain)%" : "\(Int(h.temp.rounded()))°")
                                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(h.rain >= 30 ? Color(red: 0.45, green: 0.75, blue: 1) : .white.opacity(0.8))
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(width: 168, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Loading weather…").font(.system(size: 11)).foregroundStyle(dim)
                }
                .frame(width: 168, height: 118)
            }
            Button { mirror.toggle() } label: {
                Image(systemName: mirror.state == .on ? "xmark" : mirror.state == .denied ? "video.slash.fill" : "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.black.opacity(mirror.state == .on ? 0.5 : 0)).background(Circle().fill(.white.opacity(0.08))))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(Press())
            .help(mirror.state == .on ? "Close mirror" : "Mirror (camera)")
            .accessibilityLabel(mirror.state == .on ? "Turn off mirror" : "Turn on mirror")
            .padding(mirror.state == .on ? 6 : 0)
        }
        .frame(maxHeight: .infinity)
        .onDisappear { mirror.stop() }
        .onChange(of: model.expanded) { _, open in if !open { mirror.stop() } }
    }

    private var nextHours: [WeatherStore.Hour] {
        Array(w.hours.filter { $0.time > Date() }.prefix(4))
    }

    private func hour(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = model.prayers.place.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Rak

private struct TrayTab: View {
    @ObservedObject var model: IslandModel
    let dropping: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.white.opacity(dropping ? 0.6 : 0.16))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(dropping ? 0.07 : 0)))
            if model.shelf.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22)).foregroundStyle(dim)
                    Text("Drop files here to keep them for later").font(.system(size: 12)).foregroundStyle(dim)
                }
            } else {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.shelf, id: \.self) { url in ShelfItem(url: url, model: model) }
                        }
                        .padding(.leading, 12)
                    }
                    Button(action: airDrop) {
                        VStack(spacing: 4) {
                            Image(systemName: "airplayaudio").font(.system(size: 18, weight: .medium))
                            Text("AirDrop").font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 78)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Press())
                    .accessibilityLabel("Send all files with AirDrop")
                    .padding(.trailing, 10)
                }
            }
        }
    }

    private func airDrop() {
        NSApp.activate(ignoringOtherApps: true)
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: model.shelf)
    }
}

private struct ClipsTab: View {
    @ObservedObject var clips: ClipHistory
    @State private var copied: String?

    var body: some View {
        if clips.items.isEmpty {
            VStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 22)).foregroundStyle(dim)
                Text("Text you copy will appear here").font(.system(size: 12)).foregroundStyle(dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(clips.items, id: \.self) { text in card(text) }
                }
            }
        }
    }

    private func card(_ text: String) -> some View {
        Button {
            clips.copy(text)
            copied = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == text { copied = nil } }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(copied == text ? "Copied" : "\(text.count) characters")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copied == text ? .green : dim)
            }
            .padding(10)
            .frame(width: 168)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .accessibilityLabel("Copy again: \(text.prefix(60))")
    }
}

private struct ShelfItem: View {
    let url: URL
    @ObservedObject var model: IslandModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 52, height: 52)
            Text(url.lastPathComponent)
                .font(.system(size: 10.5))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 84)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.09 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { model.removeFromShelf(url) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(url.lastPathComponent) from Tray")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

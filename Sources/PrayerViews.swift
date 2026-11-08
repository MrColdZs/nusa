import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Jam ditampilkan di zona waktu kota yang dipilih (WIB/WITA/WIT).
func prayerClock(_ d: Date, _ zone: TimeZone = PrayerTimes.Place.cikarang.timeZone) -> String {
    let f = DateFormatter()
    f.timeZone = zone
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

/// Ngecek jadwal tiap 15 detik dan munculin pengingat di notch.
final class PrayerWatcher {
    private let model: IslandModel
    private var alarm: PrayerAlarm
    private var timer: Timer?

    init(model: IslandModel) {
        self.model = model
        alarm = PrayerAlarm(schedule: model.prayers)
    }

    func start() {
        _ = alarm.check(at: Date()) // yang udah lewat pas app baru nyala nggak usah dibunyiin
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // Kota diganti: jadwal lama dibuang, yang udah lewat di kota baru nggak dibunyiin
        if alarm.schedule.place.name != model.prayers.place.name {
            alarm = PrayerAlarm(schedule: model.prayers)
            _ = alarm.check(at: Date())
        }
        guard let event = alarm.check(at: Date()), model.prayerAlerts else { return }
        let zone = model.prayers.place.timeZone
        switch event {
        case .soon(let name, let time):
            guard model.prayerSoon else { return }
            model.show(.prayer(name: name.title, time: prayerClock(time, zone), soon: true), for: 6)
        case .now(let name, let time):
            if model.prayerSound != .silent, model.pauseForPrayer, model.media.playing { model.send("pause") }
            model.playPrayerSound()
            model.expanded = false
            model.show(.prayer(name: name.title, time: prayerClock(time, zone), soon: false), for: 45)
        }
    }
}

struct PrayerPopup: View {
    let name: String
    let time: String
    let soon: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(soon ? "\(name) in 10 minutes" : "It’s time for \(name)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(soon ? "Get ready" : "Tap to dismiss").font(.system(size: 11)).foregroundStyle(dim)
            }
            Spacer(minLength: 6)
            Text(time).font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

private let mint = Color(red: 0.36, green: 0.86, blue: 0.66)

struct PrayerTab: View {
    @ObservedObject var model: IslandModel

    private static let hijri: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .islamicUmmAlQura)
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMMM y"
        return f
    }()

    private func remaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func minutesText(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            let p = model.prayers
            let zone = p.place.timeZone
            let today = p.times(on: now)
            let next = p.next(after: now)
            let previous = lastPrayer(before: now)
            let span = next.date.timeIntervalSince(previous)
            let progress = span > 0 ? now.timeIntervalSince(previous) / span : 0
            let mark = { (n: PrayerTimes.Name) in today.first { $0.name == n }.map { prayerClock($0.date, zone) } ?? "" }

            VStack(spacing: 12) {
                HStack(spacing: 22) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                            Circle().trim(from: 0, to: progress)
                                .stroke(mint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 0) {
                                Text(remaining(next.date.timeIntervalSince(now)))
                                    .font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                                Text("left").font(.system(size: 10, weight: .medium)).foregroundStyle(dim)
                            }
                        }
                        .frame(width: 84, height: 84)
                        .accessibilityElement(children: .combine)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("UP NEXT").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(mint)
                            Text(next.name.title).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                            Text("\(prayerClock(next.date, zone)) · in \(minutesText(next.date.timeIntervalSince(now)))")
                                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(dim)
                            Text("\(Self.hijri.string(from: now)) AH").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4)).padding(.top, 4)
                        }
                    }
                    .frame(width: 262, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            Spacer()
                            Text("Imsak \(mark(.imsak))  ·  Sunrise \(mark(.terbit))")
                                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(dim)
                        }
                        DayTrack(times: today, next: next.date, now: now, zone: zone)
                            .frame(height: 76)
                    }
                }

                HStack(spacing: 8) {
                    PillButton(symbol: "mappin.and.ellipse", text: "\(p.place.name) · \(p.place.zoneLabel)") { pickPlace() }
                    QiblaChip(degrees: p.place.qibla, point: p.place.qiblaPoint)
                    PillButton(symbol: "book.closed.fill", text: QuranReader.shared.markLabel.map { "Quran · \($0)" } ?? "Quran") {
                        QuranReader.shared.goToMark()
                        model.tab = .quran
                    }
                    Spacer(minLength: 0)
                    Text("Kemenag method").font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.35))
                    PillButton(symbol: soundIcon, text: soundLabel, trailing: "chevron.down") { soundMenu() }
                }
            }
        }
    }

    /// Waktu sholat terakhir yang udah lewat (sebelum Subuh berarti Isya kemarin).
    private func lastPrayer(before now: Date) -> Date {
        let p = model.prayers
        if let last = p.times(on: now).last(where: { $0.name.isPrayer && $0.date <= now }) { return last.date }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        return p.times(on: yesterday).first { $0.name == .isya }!.date
    }

    private var soundIcon: String {
        switch model.prayerSound {
        case .adzan: "speaker.wave.2.fill"
        case .tone: "bell.fill"
        case .silent: "bell.slash.fill"
        }
    }

    private var soundLabel: String {
        switch model.prayerSound {
        case .adzan: "Adzan"
        case .tone: "Tone"
        case .silent: "Silent"
        }
    }

    private func soundMenu() {
        let wasPinned = model.pinned
        model.pinned = true
        let menu = NSMenu()
        for (mode, title) in [(IslandModel.PrayerSound.adzan, "Adzan"), (.tone, "Tone"), (.silent, "Silent")] {
            let item = MenuAction(title) {
                model.prayerSound = mode
                model.playPrayerSound(preview: true)
            }
            item.state = model.prayerSound == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction(model.adzanPath == nil ? "Use my own adzan file…" : "Change adzan file…") {
            if chooseAdzan() { model.prayerSound = .adzan }
        })
        if model.adzanPath != nil {
            menu.addItem(MenuAction("Use built-in adzan") { model.adzanPath = nil })
        }
        menu.addItem(.separator())
        let soon = MenuAction("Remind me 10 minutes before") { model.prayerSoon.toggle() }
        soon.state = model.prayerSoon ? .on : .off
        menu.addItem(soon)
        menu.addItem(MenuAction("Stop sound") { model.stopPrayerSound() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.pinned = wasPinned
    }

    private func chooseAdzan() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose an adzan sound"
        panel.allowedContentTypes = [.audio]
        let wasPinned = model.pinned
        model.pinned = true
        defer { model.pinned = wasPinned }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        model.adzanPath = url.path
        return true
    }

    private func pickPlace() {
        let wasPinned = model.pinned
        model.pinned = true
        let menu = NSMenu()
        for place in PrayerTimes.Place.all {
            let item = MenuAction("\(place.name)  ·  \(place.zoneLabel)") { model.prayers = PrayerTimes(place: place) }
            item.state = place.name == model.prayers.place.name ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.pinned = wasPinned
    }
}

private final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// Garis waktu hari ini: posisi tiap waktu sholat sesuai jamnya, plus penanda "sekarang".
private struct DayTrack: View {
    let times: [(name: PrayerTimes.Name, date: Date)]
    let next: Date
    let now: Date
    let zone: TimeZone

    var body: some View {
        GeometryReader { g in
            let prayers = times.filter { $0.name.isPrayer }
            let start = (times.first?.date ?? now).addingTimeInterval(-1800)
            let end = (prayers.last?.date ?? now).addingTimeInterval(3600)
            let total = end.timeIntervalSince(start)
            let pad: CGFloat = 26
            let usable = g.size.width - pad * 2
            let x = { (d: Date) -> CGFloat in pad + usable * CGFloat(min(max(d.timeIntervalSince(start) / total, 0), 1)) }
            let lineY: CGFloat = 38
            let nowX = x(now)

            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(width: usable, height: 4).position(x: pad + usable / 2, y: lineY)
                Capsule().fill(mint.opacity(0.85)).frame(width: max(0, nowX - pad), height: 4).position(x: pad + (nowX - pad) / 2, y: lineY)

                ForEach(prayers.indices, id: \.self) { i in
                    let t = prayers[i]
                    let isNext = t.date == next
                    let past = t.date <= now
                    let px = x(t.date)
                    Circle()
                        .fill(isNext ? mint : past ? mint.opacity(0.85) : Color.white.opacity(0.35))
                        .frame(width: isNext ? 12 : 8, height: isNext ? 12 : 8)
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        .position(x: px, y: lineY)
                    // Label selang-seling atas/bawah biar Maghrib & Isha yang mepet nggak tabrakan
                    VStack(spacing: 0) {
                        Text(t.name.title).font(.system(size: 10.5, weight: isNext ? .bold : .medium))
                        Text(prayerClock(t.date, zone)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(isNext ? mint : Color.white.opacity(past ? 0.42 : 0.8))
                    .fixedSize()
                    .position(x: px, y: i.isMultiple(of: 2) ? lineY + 24 : lineY - 24)
                    .accessibilityElement(children: .combine)
                }

                Rectangle().fill(Color.white).frame(width: 2, height: 16).position(x: nowX, y: lineY)
            }
        }
    }
}

/// Panah kompas yang beneran nunjuk arah kiblat (utara = atas).
private struct QiblaChip: View {
    let degrees: Double
    let point: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(degrees))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.1)))
            Text("Qibla \(Int(degrees.rounded()))° \(point)").monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(height: 25)
        .background(Capsule().fill(.white.opacity(0.09)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Qibla direction \(Int(degrees.rounded())) degrees, \(point)")
    }
}

private struct PillButton: View {
    let symbol: String?
    let text: String
    var trailing: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(text).lineLimit(1)
                if let trailing { Image(systemName: trailing).font(.system(size: 8, weight: .bold)).opacity(0.6) }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 25)
            .background(Capsule().fill(.white.opacity(hovering ? 0.16 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
    }
}

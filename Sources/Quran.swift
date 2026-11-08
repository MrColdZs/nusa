import AVFoundation
import AppKit
import MediaPlayer
import SwiftUI

/// Mushaf mini: teks Tanzil + terjemahan Kemenag/Saheeh, dibaca dari bundel (offline).
final class QuranReader: ObservableObject {
    static let shared = QuranReader()

    struct Surah: Decodable {
        let n: Int
        let ar: String
        let tr: String
        let en: String
        let t: String
        /// Tiap ayat: [arab, indonesia, inggris]
        let v: [[String]]
    }

    struct Book: Decodable {
        let bismillah: String
        let surahs: [Surah]
    }

    @Published private(set) var book: Book?
    @Published var surah: Int {
        didSet { UserDefaults.standard.set(surah, forKey: "quranSurah") }
    }
    /// Ayat paling atas yang lagi kebaca, buat lanjut baca nanti.
    @Published var ayah: Int {
        didSet { UserDefaults.standard.set(ayah, forKey: "quranAyah") }
    }
    @Published var english: Bool {
        didSet { UserDefaults.standard.set(english, forKey: "quranEnglish") }
    }
    /// Font Arab. Scheherazade New paling gampang dibaca; dua font pertama ikut dibundel.
    static let fonts = ["Scheherazade New", "Amiri Quran", "Geeza Pro", "Mishafi"]
    @Published var font: String {
        didSet { UserDefaults.standard.set(font, forKey: "quranFont") }
    }
    /// Tanda "terakhir baca" yang dipasang user (klik ayat), beda dari posisi gulir.
    @Published private(set) var mark: (surah: Int, ayah: Int)?
    /// Naik tiap kali tampilan harus lompat ke `ayah`.
    @Published private(set) var jump = 0

    // MARK: Murottal (streaming per ayat dari cdn.islamic.network)
    static let reciters: [(id: String, name: String)] = [
        ("ar.alafasy", "Mishary Alafasy"), ("ar.husary", "Mahmoud Al-Husary"),
        ("ar.minshawi", "Al-Minshawi"), ("ar.mahermuaiqly", "Maher Al-Muaiqly"),
    ]
    @Published var reciter: String {
        didSet { UserDefaults.standard.set(reciter, forKey: "quranReciter") }
    }
    /// Ayat yang lagi dibacain (surah, ayat).
    @Published private(set) var reciting: (surah: Int, ayah: Int)?
    @Published private(set) var audioPlaying = false
    private let player: AVQueuePlayer = {
        let p = AVQueuePlayer()
        if ProcessInfo.processInfo.environment["NUSA_MUTE"] != nil { p.volume = 0 } // mode tes
        return p
    }()
    private var queued: [ObjectIdentifier: (Int, Int)] = [:]
    private var endObserver: NSObjectProtocol?

    private init() {
        let d = UserDefaults.standard
        surah = min(max(d.integer(forKey: "quranSurah"), 1), 114)
        ayah = max(d.integer(forKey: "quranAyah"), 1)
        english = d.bool(forKey: "quranEnglish")
        font = Self.fonts.contains(d.string(forKey: "quranFont") ?? "") ? d.string(forKey: "quranFont")! : Self.fonts[0]
        reciter = Self.reciters.contains { $0.id == d.string(forKey: "quranReciter") } ? d.string(forKey: "quranReciter")! : Self.reciters[0].id
        let ms = d.integer(forKey: "quranMarkSurah"), ma = d.integer(forKey: "quranMarkAyah")
        mark = ms > 0 && ma > 0 ? (ms, ma) : nil
        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = Bundle.main.url(forResource: "quran", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let book = try? JSONDecoder().decode(Book.self, from: data) else { return }
            DispatchQueue.main.async { self.book = book }
        }
    }

    var current: Surah? { book?.surahs[surah - 1] }

    func open(_ n: Int) {
        surah = min(max(n, 1), 114)
        ayah = 1
        jump += 1
    }

    func setMark(_ surah: Int, _ ayah: Int) {
        mark = (surah, ayah)
        UserDefaults.standard.set(surah, forKey: "quranMarkSurah")
        UserDefaults.standard.set(ayah, forKey: "quranMarkAyah")
    }

    func goToMark() {
        guard let mark else { return }
        surah = mark.surah
        ayah = mark.ayah
        jump += 1
    }

    private func globalNumber(_ surah: Int, _ ayah: Int) -> Int? {
        guard let book, surah >= 1, surah <= 114, ayah >= 1, ayah <= book.surahs[surah - 1].v.count else { return nil }
        return book.surahs[..<(surah - 1)].reduce(0) { $0 + $1.v.count } + ayah
    }

    private func item(_ surah: Int, _ ayah: Int) -> AVPlayerItem? {
        guard let n = globalNumber(surah, ayah),
              let url = URL(string: "https://cdn.islamic.network/quran/audio/128/\(reciter)/\(n).mp3") else { return nil }
        let item = AVPlayerItem(url: url)
        queued[ObjectIdentifier(item)] = (surah, ayah)
        return item
    }

    /// Mulai baca dari ayat ini, lanjut terus sampai akhir surah.
    func recite(from surah: Int, _ ayah: Int) {
        player.removeAllItems()
        queued = [:]
        guard let first = item(surah, ayah) else { return }
        player.insert(first, after: nil)
        if let second = item(surah, ayah + 1) { player.insert(second, after: first) }
        reciting = (surah, ayah)
        setupRemote()
        player.play()
        audioPlaying = true
        publishNowPlaying()
        endObserver = endObserver ?? NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            self?.finished(note.object as? AVPlayerItem)
        }
    }

    private func finished(_ done: AVPlayerItem?) {
        guard let done, let pos = queued.removeValue(forKey: ObjectIdentifier(done)) else { return }
        let nextAyah = pos.1 + 1
        // Akhir surah: berhenti
        guard globalNumber(pos.0, nextAyah) != nil else { return stopRecitation() }
        reciting = (pos.0, nextAyah)
        // Selalu siapin satu ayat di depan biar nyambung tanpa jeda
        if let last = player.items().last, let after = item(pos.0, nextAyah + 1) { player.insert(after, after: last) }
        publishNowPlaying()
    }

    func toggleRecitation() {
        guard reciting != nil else { return recite(from: surah, max(ayah, 1)) }
        if audioPlaying { player.pause() } else { player.play() }
        audioPlaying.toggle()
        publishNowPlaying()
    }

    func stopRecitation() {
        player.removeAllItems()
        queued = [:]
        reciting = nil
        audioPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func skip(_ delta: Int) {
        guard let r = reciting else { return }
        recite(from: r.surah, max(1, r.ayah + delta))
    }

    /// Muncul di Now Playing macOS, jadi notch & tombol media keyboard ikut ngontrol.
    private func publishNowPlaying() {
        guard let r = reciting, let s = book?.surahs[r.surah - 1] else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "\(s.tr) · \(r.ayah)",
            MPMediaItemPropertyArtist: Self.reciters.first { $0.id == reciter }?.name ?? "Quran",
            MPMediaItemPropertyAlbumTitle: "Quran",
            MPNowPlayingInfoPropertyPlaybackRate: audioPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = audioPlaying ? .playing : .paused
    }

    private var remoteReady = false
    private func setupRemote() {
        guard !remoteReady else { return }
        remoteReady = true
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggleRecitation(); return .success }
        c.playCommand.addTarget { [weak self] _ in if self?.audioPlaying == false { self?.toggleRecitation() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in if self?.audioPlaying == true { self?.toggleRecitation() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skip(1); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.skip(-1); return .success }
    }

    /// Contoh: "Al-Baqarah 255", buat label tombol.
    var markLabel: String? {
        guard let mark, let s = book?.surahs[mark.surah - 1] else { return nil }
        return "\(s.tr) \(mark.ayah)"
    }
}

private let mint = Color(red: 0.36, green: 0.86, blue: 0.66)

struct QuranTab: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var q = QuranReader.shared
    @State private var top: Int?

    var body: some View {
        if let s = q.current, let book = q.book {
            VStack(spacing: 8) {
                header(s)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if s.n != 1, s.n != 9 {
                                Text(book.bismillah)
                                    .font(.custom(q.font, size: 34))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .id(0)
                            }
                            ForEach(s.v.indices, id: \.self) { i in
                                AyahRow(number: i + 1, arabic: s.v[i][0], meaning: s.v[i][q.english ? 2 : 1], font: q.font,
                                        marked: q.mark?.surah == s.n && q.mark?.ayah == i + 1,
                                        reciting: q.reciting?.surah == s.n && q.reciting?.ayah == i + 1) {
                                    startRecitation(s.n, i + 1)
                                }
                                    .id(i + 1)
                                    .onTapGesture { q.setMark(s.n, i + 1) }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $top, anchor: .top)
                    .onAppear { scroll(proxy, s) }
                    .onChange(of: q.jump) { _, _ in DispatchQueue.main.async { scroll(proxy, s) } }
                    .onChange(of: q.reciting?.ayah) { _, a in
                        // Ayat yang lagi dibaca ikut kelihatan
                        if let a, q.reciting?.surah == s.n { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(a, anchor: .center) } }
                    }
                    .onChange(of: top) { _, id in if let id, id > 0 { q.ayah = id } }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func startRecitation(_ surah: Int, _ ayah: Int) {
        // Musik lain dijeda dulu sebelum Nusa jadi pemutar utama
        if model.media.playing, model.media.source != Bundle.main.bundleIdentifier { model.send("pause") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { q.recite(from: surah, ayah) }
    }

    /// Ayat 1 berarti mulai dari atas, termasuk Bismillah pembuka.
    private func scroll(_ proxy: ScrollViewProxy, _ s: QuranReader.Surah) {
        proxy.scrollTo(q.ayah <= 1 && s.n != 1 && s.n != 9 ? 0 : q.ayah, anchor: .top)
    }

    private func header(_ s: QuranReader.Surah) -> some View {
        HStack(spacing: 8) {
            Button { surahMenu() } label: {
                HStack(spacing: 6) {
                    Text("\(s.n)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24).background(Capsule().fill(mint)).foregroundStyle(.black)
                    Text(s.tr).font(.system(size: 15, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
                }
                .foregroundStyle(.white)
                .padding(.leading, 3).padding(.trailing, 12)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(0.09)))
                .contentShape(Capsule())
            }
            .buttonStyle(Press())
            Text("\(s.en) · \(s.v.count) verses · \(s.t == "Meccan" ? "Makkah" : "Madinah")")
                .font(.system(size: 12.5)).foregroundStyle(dim).lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 6)
            if let label = q.markLabel {
                Button { q.goToMark() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bookmark.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(mint)
                        Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Capsule().fill(.white.opacity(0.09)))
                    .contentShape(Capsule())
                }
                .buttonStyle(Press())
                .help("Jump to your last read verse")
            }
            Text(s.ar).font(.custom(q.font, size: 22)).foregroundStyle(.white.opacity(0.85))
            Button {
                if q.reciting == nil { startRecitation(s.n, max(top ?? q.ayah, 1)) } else { q.toggleRecitation() }
            } label: {
                Image(systemName: q.audioPlaying ? "pause.fill" : "play.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30).background(Circle().fill(mint))
            }
            .buttonStyle(Press())
            .help(q.audioPlaying ? "Pause recitation" : "Listen from here")
            .accessibilityLabel(q.audioPlaying ? "Pause recitation" : "Play recitation")
            if q.reciting != nil {
                NavButton(symbol: "stop.fill", label: "Stop recitation", enabled: true) { q.stopRecitation() }
            }
            Button { fontMenu() } label: {
                Text("Aa").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.09)))
            }
            .buttonStyle(Press())
            .help("Arabic font")
            HStack(spacing: 2) {
                ForEach([false, true], id: \.self) { en in
                    Button { q.english = en } label: {
                        Text(en ? "EN" : "ID").font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(q.english == en ? .black : .white.opacity(0.6))
                            .frame(width: 32, height: 26)
                            .background(Capsule().fill(q.english == en ? Color.white : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(en ? "English translation" : "Indonesian translation")
                }
            }
            .padding(2)
            .background(Capsule().fill(.white.opacity(0.08)))
            NavButton(symbol: "chevron.left", label: "Previous surah", enabled: s.n > 1) { q.open(s.n - 1) }
            NavButton(symbol: "chevron.right", label: "Next surah", enabled: s.n < 114) { q.open(s.n + 1) }
        }
    }

    private func fontMenu() {
        let wasPinned = model.pinned
        model.pinned = true
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Arabic font"))
        for f in QuranReader.fonts {
            let item = SurahItem(title: f) { q.font = f }
            item.state = f == q.font ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Reciter"))
        for r in QuranReader.reciters {
            let item = SurahItem(title: r.name) {
                q.reciter = r.id
                if let cur = q.reciting { q.recite(from: cur.surah, cur.ayah) }
            }
            item.state = r.id == q.reciter ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.pinned = wasPinned
    }

    private func surahMenu() {
        guard let book = q.book else { return }
        let wasPinned = model.pinned
        model.pinned = true
        let menu = NSMenu()
        for s in book.surahs {
            let item = SurahItem(title: "\(s.n).  \(s.tr)  ·  \(s.en)") { q.open(s.n) }
            item.state = s.n == q.surah ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.item(at: q.surah - 1), at: NSEvent.mouseLocation, in: nil)
        model.pinned = wasPinned
    }
}

private final class SurahItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

private struct NavButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.09)))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
        }
        .buttonStyle(Press())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct AyahRow: View {
    let number: Int
    let arabic: String
    let meaning: String
    let font: String
    let marked: Bool
    let reciting: Bool
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(marked ? mint : .white.opacity(0.08))
                    if marked {
                        Image(systemName: "bookmark.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                    } else {
                        Text("\(number)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                    }
                }
                .frame(width: 32, height: 32)
                // Tombol dengerin ayat: kelihatan pas disorot atau lagi dibaca
                Button(action: play) {
                    Image(systemName: reciting ? "waveform" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .symbolEffect(.variableColor.iterative, isActive: reciting)
                        .foregroundStyle(reciting ? .black : .white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(reciting ? mint : .white.opacity(0.1)))
                }
                .buttonStyle(Press())
                .opacity(reciting || hovering ? 1 : 0)
                .help("Listen from this verse")
                .accessibilityLabel("Listen from verse \(number)")
            }
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                Text(arabic)
                    .font(.custom(font, size: 34))
                    .lineSpacing(10)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    // Ayat nggak boleh kepotong: tinggi teks ngikutin isinya
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(meaning)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(reciting ? mint.opacity(0.1) : .white.opacity(marked ? 0.07 : hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(marked ? "Your last read verse" : "Click to mark as last read")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verse \(number)\(marked ? ", last read" : ""). \(meaning)")
        .accessibilityAddTraits(.isButton)
    }
}

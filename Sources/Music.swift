import AppKit
import SwiftUI

/// Remote ke Senandung (server lokal 127.0.0.1:5560): baca antrean, cari lagu, suruh muter.
final class MusicRemote: ObservableObject {
    static let shared = MusicRemote()

    struct Song: Identifiable {
        let raw: [String: Any]
        var vid: String { raw["vid"] as? String ?? "" }
        var title: String { raw["title"] as? String ?? "Untitled" }
        var artist: String { raw["artist"] as? String ?? "" }
        var art: String? { raw["art"] as? String }
        var duration: Double { (raw["duration"] as? NSNumber)?.doubleValue ?? 0 }
        var index: Int? { raw["i"] as? Int }
        var id: String { "\(vid)-\(index ?? -1)" }
    }

    let base = URL(string: ProcessInfo.processInfo.environment["NUSA_SENANDUNG"] ?? "http://127.0.0.1:5560")!
    @Published private(set) var queue: [Song] = []
    @Published private(set) var current = -1
    @Published private(set) var playing = false
    @Published private(set) var online = false
    @Published private(set) var results: [Song] = []
    @Published private(set) var searching = false
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    private var timer: Timer?
    private var searchWork: DispatchWorkItem?

    func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("api/remote/state")) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            DispatchQueue.main.async {
                guard let self else { return }
                self.online = ok
                guard let obj else { return }
                self.current = obj["idx"] as? Int ?? -1
                self.playing = obj["playing"] as? Bool ?? false
                self.queue = (obj["queue"] as? [[String: Any]] ?? []).map(Song.init)
            }
        }.resume()
    }

    private func scheduleSearch() {
        searchWork?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; searching = false; return }
        searching = true
        let work = DispatchWorkItem { [weak self] in self?.search(q) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func search(_ q: String) {
        var c = URLComponents(url: base.appendingPathComponent("api/yt/search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "type", value: "songs")]
        URLSession.shared.dataTask(with: c.url!) { [weak self] data, _, _ in
            let list = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []
            DispatchQueue.main.async {
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == q else { return }
                self.results = list.filter { $0["vid"] is String }.prefix(25).map(Song.init)
                self.searching = false
            }
        }.resume()
    }

    /// play = putar sekarang, queue = putar berikutnya, jump = pindah ke lagu di antrean.
    func send(_ body: [String: Any]) {
        var req = URLRequest(url: base.appendingPathComponent("api/remote/cmd"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Senandung-Remote")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.refresh() }
        }.resume()
    }

    /// Sampul lewat proxy gambar Senandung (udah ke-cache di sana).
    func artURL(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("/") { return URL(string: s, relativeTo: base) }
        var c = URLComponents(url: base.appendingPathComponent("api/yt/img"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "u", value: s)]
        return c.url
    }
}

private let mint = Color(red: 0.36, green: 0.86, blue: 0.66)

struct MusicTab: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var remote = MusicRemote.shared
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            // Senandung nggak jalan: pemutar dari app apa aja (Spotify, Apple Music, browser, ...), sama kayak versi Windows
            if remote.online { senandung } else { SystemPlayer(model: model) }
        }
        .onAppear { remote.start() }
        .onDisappear { remote.stop() }
    }

    private var senandung: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(dim)
                    TextField("Search songs, artists…", text: $remote.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .focused($focused)
                    if !remote.query.isEmpty {
                        Button { remote.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(dim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(.white.opacity(focused ? 0.14 : 0.09)))
                .onTapGesture { focused = true }
            }

            if remote.query.trimmingCharacters(in: .whitespaces).isEmpty {
                list(title: "Up next", empty: "Nothing queued in Senandung yet.") {
                    ForEach(remote.queue) { s in
                        SongRow(song: s, art: remote.artURL(s.art), now: s.index == remote.current, playing: remote.playing, action: nil) {
                            if let i = s.index { remote.send(["cmd": "jump", "index": i]) }
                        }
                    }
                }
            } else if remote.searching && remote.results.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(title: "Results", empty: "No songs found.") {
                    ForEach(remote.results) { s in
                        SongRow(song: s, art: remote.artURL(s.art), now: false, playing: false,
                                action: ("text.line.first.and.arrowtriangle.forward", "Play next", { remote.send(["cmd": "queue", "item": s.raw]) })) {
                            remote.send(["cmd": "play", "item": s.raw])
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func list<Rows: View>(title: String, empty: String, @ViewBuilder rows: () -> Rows) -> some View {
        let isEmpty = title == "Up next" ? remote.queue.isEmpty : remote.results.isEmpty
        if isEmpty {
            note(empty, "")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(mint).padding(.leading, 4)
                ScrollView { LazyVStack(spacing: 2) { rows() } }
            }
        }
    }

    private func note(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "music.note.list").font(.system(size: 20)).foregroundStyle(dim)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(dim) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pemutar gede buat lagu dari app apa aja (dibaca helper Now Playing), dipakai kalau Senandung nggak jalan.
private struct SystemPlayer: View {
    @ObservedObject var model: IslandModel
    @State private var scrub: Double?

    private var appURL: URL? {
        model.media.source.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    private var appName: String? {
        appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    var body: some View {
        if model.media.exists {
            HStack(spacing: 20) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(image: model.art, side: 200, radius: 20)
                        .shadow(color: .black.opacity(0.45), radius: 15, y: 10)
                    if let url = appURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 40, height: 40)
                            .offset(x: 7, y: 7)
                            .accessibilityHidden(true)
                    }
                }
                .onTapGesture { if let url = appURL { NSWorkspace.shared.open(url) } }
                .help(appName.map { "Open \($0)" } ?? "")

                VStack(alignment: .leading, spacing: 2) {
                    if let name = appName {
                        Text("\(model.media.playing ? "Playing" : "Paused") · \(name)".uppercased())
                            .font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(mint).lineLimit(1)
                    }
                    Text(model.media.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).lineLimit(1).padding(.top, 6)
                    Text(model.media.artist).font(.system(size: 13)).foregroundStyle(dim).lineLimit(1)
                    if !model.media.album.isEmpty {
                        Text(model.media.album).font(.system(size: 13)).foregroundStyle(dim).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        RoundButton(symbol: "backward.fill", label: "Previous track", size: 17) { model.send("prev") }
                        RoundButton(symbol: model.media.playing ? "pause.fill" : "play.fill",
                                    label: model.media.playing ? "Pause" : "Play", size: 23) { model.send("toggle") }
                        RoundButton(symbol: "forward.fill", label: "Next track", size: 17) { model.send("next") }
                    }
                    .offset(x: -8)
                    .padding(.vertical, 8)
                    if model.media.duration > 0 { progress }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "music.note.list").font(.system(size: 20)).foregroundStyle(dim)
                Text("Nothing playing").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("Play something in Spotify, Apple Music, or any music app — it’ll show up here.")
                    .font(.system(size: 12)).foregroundStyle(dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Bar posisi lagu yang bisa digeser + waktu jalan / total.
    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let duration = model.media.duration
            let position = scrub ?? model.media.position(at: ctx.date)
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
            VStack(spacing: 5) {
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
                HStack {
                    Text(clock(position))
                    Spacer()
                    Text(clock(duration))
                }
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.4))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Track position")
            .accessibilityValue("\(clock(position)) of \(clock(duration))")
        }
    }
}

private struct SongRow: View {
    let song: MusicRemote.Song
    let art: URL?
    let now: Bool
    let playing: Bool
    let action: (symbol: String, label: String, run: () -> Void)?
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            AsyncImage(url: art) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                Color.white.opacity(0.08).overlay(Image(systemName: "music.note").font(.system(size: 13)).foregroundStyle(dim))
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(now ? mint : .white).lineLimit(1)
                Text(song.artist).font(.system(size: 11.5)).foregroundStyle(dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if now {
                Image(systemName: playing ? "waveform" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(mint)
                    .symbolEffect(.variableColor.iterative, isActive: playing)
            }
            if song.duration > 0 {
                Text(clock(song.duration)).font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(dim)
            }
            if let action {
                Button(action: action.run) {
                    Image(systemName: action.symbol).font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0.07)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(Press())
                .help(action.label)
                .accessibilityLabel(action.label)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(now ? 0.07 : hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: tap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.title), \(song.artist)\(now ? ", now playing" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

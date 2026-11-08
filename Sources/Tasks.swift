import AppKit
import Foundation

struct TaskItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var due: Date?
    var done = false
    var doneAt: Date?
    /// Udah dimunculin di notch buat waktu `due` yang sekarang.
    var notified = false
    var created = Date()
}

/// Baca waktu dari kalimat: bahasa Inggris lewat NSDataDetector, bahasa Indonesia lewat aturan sendiri.
enum TaskParser {
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> (title: String, due: Date?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = indonesian(text, now: now, cal: calendar) { return id }
        if let en = english(text, now: now) { return en }
        return (text, nil)
    }

    private static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
        // Kata sambung yang ketinggalan di ujung
        for tail in [" at", " on", " by", " in", " pada", " pas", " sekitar", " untuk", " buat", " dalam", " di"] where t.lowercased().hasSuffix(tail) {
            t = String(t.dropLast(tail.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func english(_ text: String, now: Date) -> (String, Date?)? {
        // Relatif: "in 30 min", "in 2 hours" (NSDataDetector nggak ngenalin ini)
        if let r = try? NSRegularExpression(pattern: #"\bin\s+(\d{1,3})\s*(m|min|mins|minutes?|h|hr|hrs|hours?)\b"#, options: .caseInsensitive),
           let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(m.range, in: text), let nr = Range(m.range(at: 1), in: text), let ur = Range(m.range(at: 2), in: text),
           let n = Double(text[nr]) {
            let secs = text[ur].lowercased().hasPrefix("h") ? n * 3600 : n * 60
            var rest = text
            rest.removeSubrange(whole)
            return (tidy(rest), now.addingTimeInterval(secs))
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = m.date, date > now.addingTimeInterval(-60),
              let range = Range(m.range, in: text) else { return nil }
        var rest = text
        rest.removeSubrange(range)
        let title = tidy(rest)
        return (title.isEmpty ? text : title, date)
    }

    private static func indonesian(_ text: String, now: Date, cal: Calendar) -> (String, Date?)? {
        let lower = text.lowercased()
        var rest = text
        var matched = false
        func cut(_ pattern: String) -> [String]? {
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = r.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let whole = Range(m.range, in: rest) else { return nil }
            let groups = (0..<m.numberOfRanges).map { i -> String in
                Range(m.range(at: i), in: rest).map { String(rest[$0]) } ?? ""
            }
            rest.removeSubrange(whole)
            matched = true
            return groups
        }

        // Relatif: "30 menit lagi", "2 jam lagi", "dalam 30 menit"
        if let g = cut(#"\b(?:dalam\s+)?(\d{1,3})\s*(menit|mnt|jam)\s+lagi\b"#) ?? cut(#"\bdalam\s+(\d{1,3})\s*(menit|mnt|jam)\b"#),
           let n = Double(g[1]) {
            let secs = g[2].lowercased().hasPrefix("j") ? n * 3600 : n * 60
            return (tidy(rest), now.addingTimeInterval(secs))
        }

        var dayOffset: Int?
        if cut(#"\blusa\b"#) != nil { dayOffset = 2 }
        else if cut(#"\bbesok\b"#) != nil { dayOffset = 1 }
        else if cut(#"\bhari ini\b"#) != nil { dayOffset = 0 }

        var hour: Int?, minute = 0
        if let g = cut(#"\b(?:jam|pukul)\s*(\d{1,2})(?:[.:](\d{2}))?\b"#) {
            hour = Int(g[1]); minute = Int(g[2]) ?? 0
        }
        var part: String?
        if let g = cut(#"\b(?:nanti\s+)?(pagi|siang|sore|malam)\b"#) { part = g[1].lowercased() }
        if !matched { return nil }
        _ = cut(#"\bnanti\b"#)

        if var h = hour {
            switch part {
            case "siang": if h < 11 { h += 12 }
            case "sore": if h < 12 { h += 12 }
            case "malam": if h == 12 { h = 0 } else if h < 12 { h += 12 }
            default: break
            }
            hour = h
        } else if let part {
            hour = ["pagi": 8, "siang": 12, "sore": 16, "malam": 20][part]
        } else if dayOffset != nil {
            hour = 9
        }
        guard let h = hour, h < 24, minute < 60 else { return nil }

        let start = cal.startOfDay(for: now)
        var due = cal.date(bySettingHour: h, minute: minute, second: 0, of: cal.date(byAdding: .day, value: dayOffset ?? 0, to: start)!)!
        // "jam 7" yang udah lewat hari ini berarti besok
        if dayOffset == nil, due <= now { due = cal.date(byAdding: .day, value: 1, to: due)! }
        let title = tidy(rest)
        _ = lower
        return (title.isEmpty ? text : title, due)
    }
}

/// Simpan tugas ke JSON di Application Support, dan munculin pengingat pas waktunya.
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published private(set) var items: [TaskItem] = []
    let file: URL
    var onDue: ((TaskItem) -> Void)?
    private var timer: Timer?

    private init() {
        if let custom = ProcessInfo.processInfo.environment["NUSA_TASKS_FILE"] {
            file = URL(fileURLWithPath: custom)
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nusa")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            file = dir.appendingPathComponent("tasks.json")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        items = (try? Data(contentsOf: file)).flatMap { try? dec.decode([TaskItem].self, from: $0) } ?? []
    }

    func start() {
        // Cek pertama nunggu notch siap, kalau nggak pop-up yang muncul pas app baru nyala bisa kepotong
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.check() }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Satu pengingat per cek; sisanya nyusul di cek berikutnya biar nggak numpuk.
    func check(now: Date = Date()) {
        // Tugas selesai disimpen sehari, abis itu dibersihin
        let stale = items.filter { $0.done && ($0.doneAt ?? .distantPast) < now.addingTimeInterval(-86400) }
        if !stale.isEmpty { items.removeAll { stale.contains($0) }; save() }
        guard let i = items.firstIndex(where: { !$0.done && !$0.notified && ($0.due.map { $0 <= now } ?? false) }) else { return }
        items[i].notified = true
        save()
        onDue?(items[i])
    }

    @discardableResult
    func add(_ text: String, due override: Date? = nil) -> TaskItem? {
        let parsed = TaskParser.parse(text)
        guard !parsed.title.isEmpty else { return nil }
        let item = TaskItem(title: parsed.title, due: override ?? parsed.due)
        items.append(item)
        save()
        return item
    }

    func toggle(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        items[i].doneAt = items[i].done ? Date() : nil
        save()
    }

    func snooze(_ id: String, minutes: Double = 10) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].due = Date().addingTimeInterval(minutes * 60)
        items[i].notified = false
        save()
    }

    func setDue(_ id: String, _ date: Date?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].due = date
        items[i].notified = false
        save()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Belum selesai dulu (yang telat & paling dekat di atas), yang tanpa waktu di bawahnya, selesai paling bawah.
    var sorted: [TaskItem] {
        items.sorted { a, b in
            if a.done != b.done { return !a.done }
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.created < b.created
            }
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(items).write(to: file, options: .atomic)
    }
}

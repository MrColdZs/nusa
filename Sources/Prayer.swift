import Foundation

/// Jadwal sholat dihitung lokal (rumus astronomi PrayTimes) pakai kriteria Kemenag RI:
/// Subuh 20°, Isya 18°, Ashar mazhab Syafi'i, Imsak 10 menit sebelum Subuh, ihtiyat 2 menit.
struct PrayerTimes {
    enum Name: String, CaseIterable {
        case imsak = "Imsak", subuh = "Subuh", terbit = "Terbit", dzuhur = "Dzuhur", ashar = "Ashar", maghrib = "Maghrib", isya = "Isya"
        /// Waktu sholat wajib (Imsak & Terbit cuma penanda).
        var isPrayer: Bool { ![.imsak, .terbit].contains(self) }

        /// Nama yang tampil di UI (bahasa Inggris).
        var title: String {
            switch self {
            case .imsak: "Imsak"
            case .subuh: "Fajr"
            case .terbit: "Sunrise"
            case .dzuhur: "Dhuhr"
            case .ashar: "Asr"
            case .maghrib: "Maghrib"
            case .isya: "Isha"
            }
        }
    }

    struct Place {
        var name: String
        var latitude: Double
        var longitude: Double
        var timeZone: TimeZone
        static let cikarang = Place(name: "Cikarang", latitude: -6.2615, longitude: 107.1528, timeZone: TimeZone(identifier: "Asia/Jakarta")!)

        private static func city(_ name: String, _ lat: Double, _ lon: Double, _ zone: String) -> Place {
            Place(name: name, latitude: lat, longitude: lon, timeZone: TimeZone(identifier: zone)!)
        }

        static let all: [Place] = [
            cikarang,
            city("Bekasi", -6.2383, 106.9756, "Asia/Jakarta"),
            city("Jakarta", -6.2088, 106.8456, "Asia/Jakarta"),
            city("Bogor", -6.5971, 106.8060, "Asia/Jakarta"),
            city("Bandung", -6.9175, 107.6191, "Asia/Jakarta"),
            city("Semarang", -6.9667, 110.4167, "Asia/Jakarta"),
            city("Yogyakarta", -7.7956, 110.3695, "Asia/Jakarta"),
            city("Surabaya", -7.2575, 112.7521, "Asia/Jakarta"),
            city("Palembang", -2.9761, 104.7754, "Asia/Jakarta"),
            city("Medan", 3.5952, 98.6722, "Asia/Jakarta"),
            city("Denpasar", -8.6705, 115.2126, "Asia/Makassar"),
            city("Balikpapan", -1.2379, 116.8529, "Asia/Makassar"),
            city("Makassar", -5.1477, 119.4327, "Asia/Makassar"),
            city("Jayapura", -2.5337, 140.7181, "Asia/Jayapura"),
        ]

        static func named(_ name: String?) -> Place { all.first { $0.name == name } ?? cikarang }

        /// Arah kiblat dari utara searah jarum jam, ke Ka'bah.
        var qibla: Double {
            let k = (lat: 21.4225 * .pi / 180, lon: 39.8262 * .pi / 180)
            let p = (lat: latitude * .pi / 180, lon: longitude * .pi / 180)
            let d = k.lon - p.lon
            let b = atan2(sin(d) * cos(k.lat), cos(p.lat) * sin(k.lat) - sin(p.lat) * cos(k.lat) * cos(d)) * 180 / .pi
            return (b + 360).truncatingRemainder(dividingBy: 360)
        }

        var qiblaPoint: String {
            let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
            return points[Int((qibla / 22.5).rounded()) % 16]
        }

        var zoneLabel: String {
            switch timeZone.identifier {
            case "Asia/Makassar": "WITA"
            case "Asia/Jayapura": "WIT"
            default: "WIB"
            }
        }
    }

    let place: Place
    /// Menit pengaman yang ditambahin ke tiap waktu (Terbit dikurangi), standar Kemenag 2 menit.
    var ihtiyat = 2.0

    /// Waktu-waktu buat tanggal kalender `day` di zona waktu tempat itu.
    func times(on day: Date) -> [(name: Name, date: Date)] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = place.timeZone
        let c = cal.dateComponents([.year, .month, .day], from: day)
        let midnight = cal.date(from: c)!
        let raw = rawHours(year: c.year!, month: c.month!, day: c.day!)
        func at(_ hours: Double, _ shift: Double) -> Date {
            // Dibulatkan ke menit terdekat, sama kayak jadwal yang dicetak
            midnight.addingTimeInterval((hours * 60 + shift).rounded() * 60)
        }
        let subuh = at(raw.fajr, ihtiyat)
        return [
            (.imsak, subuh.addingTimeInterval(-600)),
            (.subuh, subuh),
            (.terbit, at(raw.sunrise, -ihtiyat)),
            (.dzuhur, at(raw.dhuhr, ihtiyat)),
            (.ashar, at(raw.asr, ihtiyat)),
            (.maghrib, at(raw.maghrib, ihtiyat)),
            (.isya, at(raw.isha, ihtiyat)),
        ]
    }

    /// Waktu sholat wajib berikutnya setelah `now` (bisa nyebrang ke Subuh besok).
    func next(after now: Date) -> (name: Name, date: Date) {
        let today = times(on: now).filter { $0.name.isPrayer && $0.date > now }
        if let first = today.first { return first }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        return times(on: tomorrow).first { $0.name == .subuh }!
    }

    // MARK: - Astronomi

    private struct Raw { var fajr, sunrise, dhuhr, asr, maghrib, isha: Double }

    private func rawHours(year: Int, month: Int, day: Int) -> Raw {
        let jDate = julian(year, month, day) - place.longitude / (15 * 24)
        let lat = place.latitude
        let zone = Double(place.timeZone.secondsFromGMT(for: Date())) / 3600

        func sun(_ jd: Double) -> (decl: Double, eqt: Double) {
            let d = jd - 2451545
            let g = fixAngle(357.529 + 0.98560028 * d)
            let q = fixAngle(280.459 + 0.98564736 * d)
            let l = fixAngle(q + 1.915 * sin(g.rad) + 0.020 * sin((2 * g).rad))
            let e = 23.439 - 0.00000036 * d
            let ra = fixHour(atan2(cos(e.rad) * sin(l.rad), cos(l.rad)).deg / 15)
            return (asin(sin(e.rad) * sin(l.rad)).deg, q / 15 - ra)
        }
        func noon(_ t: Double) -> Double { fixHour(12 - sun(jDate + t).eqt) }
        func angleTime(_ angle: Double, _ t: Double, ccw: Bool) -> Double {
            let decl = sun(jDate + t).decl
            let x = (-sin(angle.rad) - sin(decl.rad) * sin(lat.rad)) / (cos(decl.rad) * cos(lat.rad))
            let h = acos(max(-1, min(1, x))).deg / 15
            return noon(t) + (ccw ? -h : h)
        }
        func asrTime(_ t: Double) -> Double {
            let decl = sun(jDate + t).decl
            let angle = -atan(1 / (1 + tan(abs(lat - decl).rad))).deg
            return angleTime(angle, t, ccw: false)
        }

        // Dua putaran: tebakan awal pakai jam kira-kira, terus diperbaiki pakai hasil sebelumnya
        var r = Raw(fajr: 5, sunrise: 6, dhuhr: 12, asr: 13, maghrib: 18, isha: 18)
        for _ in 0..<2 {
            r = Raw(fajr: angleTime(20, r.fajr / 24, ccw: true),
                    sunrise: angleTime(0.833, r.sunrise / 24, ccw: true),
                    dhuhr: noon(r.dhuhr / 24),
                    asr: asrTime(r.asr / 24),
                    maghrib: angleTime(0.833, r.maghrib / 24, ccw: false),
                    isha: angleTime(18, r.isha / 24, ccw: false))
        }
        let shift = zone - place.longitude / 15
        return Raw(fajr: r.fajr + shift, sunrise: r.sunrise + shift, dhuhr: r.dhuhr + shift,
                   asr: r.asr + shift, maghrib: r.maghrib + shift, isha: r.isha + shift)
    }

    private func julian(_ y: Int, _ m: Int, _ d: Int) -> Double {
        var year = y, month = m
        if month <= 2 { year -= 1; month += 12 }
        let a = floor(Double(year) / 100)
        let b = 2 - a + floor(a / 4)
        return floor(365.25 * Double(year + 4716)) + floor(30.6001 * Double(month + 1)) + Double(d) + b - 1524.5
    }

    private func fixAngle(_ a: Double) -> Double { a - 360 * floor(a / 360) }
    private func fixHour(_ h: Double) -> Double { h - 24 * floor(h / 24) }
}

private extension Double {
    var rad: Double { self * .pi / 180 }
    var deg: Double { self * 180 / .pi }
}

/// Nentuin kapan pengingat muncul. Dipisah dari timer biar bisa dites pakai jam palsu.
struct PrayerAlarm {
    enum Event: Equatable {
        case soon(PrayerTimes.Name, Date)
        case now(PrayerTimes.Name, Date)
    }

    let schedule: PrayerTimes
    var lead: TimeInterval = 600
    /// Kalau Mac baru bangun dan waktunya udah lewat lebih dari ini, nggak usah bunyi lagi.
    var grace: TimeInterval = 120
    private(set) var fired = Set<String>()

    init(schedule: PrayerTimes) { self.schedule = schedule }

    mutating func check(at now: Date) -> Event? {
        for (name, time) in schedule.times(on: now) where name.isPrayer {
            let key = "\(Int(time.timeIntervalSince1970))-\(name.rawValue)"
            let until = time.timeIntervalSince(now)
            if until <= 0, -until < grace, !fired.contains(key + "-now") {
                fired.insert(key + "-now")
                fired.insert(key + "-soon")
                return .now(name, time)
            }
            if until > 0, until <= lead, !fired.contains(key + "-soon") {
                fired.insert(key + "-soon")
                return .soon(name, time)
            }
        }
        return nil
    }
}

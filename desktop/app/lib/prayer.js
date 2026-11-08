// Jadwal sholat, dihitung lokal (rumus PrayTimes) pakai kriteria Kemenag RI:
// Subuh 20°, Isya 18°, Ashar Syafi'i, Imsak 10 menit sebelum Subuh, ihtiyat 2 menit.
// Sama persis dengan Sources/Prayer.swift versi Mac.
(function (root) {
  const rad = (d) => (d * Math.PI) / 180;
  const deg = (r) => (r * 180) / Math.PI;
  const fixAngle = (a) => a - 360 * Math.floor(a / 360);
  const fixHour = (h) => h - 24 * Math.floor(h / 24);

  const CITIES = [
    ['Cikarang', -6.2615, 107.1528, 'Asia/Jakarta'], ['Bekasi', -6.2383, 106.9756, 'Asia/Jakarta'],
    ['Jakarta', -6.2088, 106.8456, 'Asia/Jakarta'], ['Bogor', -6.5971, 106.806, 'Asia/Jakarta'],
    ['Bandung', -6.9175, 107.6191, 'Asia/Jakarta'], ['Semarang', -6.9667, 110.4167, 'Asia/Jakarta'],
    ['Yogyakarta', -7.7956, 110.3695, 'Asia/Jakarta'], ['Surabaya', -7.2575, 112.7521, 'Asia/Jakarta'],
    ['Palembang', -2.9761, 104.7754, 'Asia/Jakarta'], ['Medan', 3.5952, 98.6722, 'Asia/Jakarta'],
    ['Denpasar', -8.6705, 115.2126, 'Asia/Makassar'], ['Balikpapan', -1.2379, 116.8529, 'Asia/Makassar'],
    ['Makassar', -5.1477, 119.4327, 'Asia/Makassar'], ['Jayapura', -2.5337, 140.7181, 'Asia/Jayapura'],
  ].map(([name, lat, lon, tz]) => ({ name, lat, lon, tz, zone: { 'Asia/Makassar': 'WITA', 'Asia/Jayapura': 'WIT' }[tz] || 'WIB' }));

  const NAMES = [['imsak', 'Imsak', false], ['subuh', 'Fajr', true], ['terbit', 'Sunrise', false], ['dzuhur', 'Dhuhr', true],
    ['ashar', 'Asr', true], ['maghrib', 'Maghrib', true], ['isya', 'Isha', true]];

  // Offset zona (jam) buat kota itu di tanggal tertentu
  function zoneHours(tz, date) {
    const f = new Intl.DateTimeFormat('en-US', { timeZone: tz, timeZoneName: 'shortOffset' }).formatToParts(date);
    const m = (f.find((p) => p.type === 'timeZoneName')?.value || 'GMT+0').match(/GMT([+-]\d+)(?::(\d+))?/);
    return m ? +m[1] + (m[2] ? Math.sign(+m[1]) * (+m[2] / 60) : 0) : 0;
  }

  // Tanggal kalender (y, m, d) di zona kota
  function ymd(tz, date) {
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' })
      .formatToParts(date).filter((x) => x.type !== 'literal').map((x) => [x.type, +x.value]));
    return [p.year, p.month, p.day];
  }

  function julian(y, m, d) {
    if (m <= 2) { y -= 1; m += 12; }
    const a = Math.floor(y / 100), b = 2 - a + Math.floor(a / 4);
    return Math.floor(365.25 * (y + 4716)) + Math.floor(30.6001 * (m + 1)) + d + b - 1524.5;
  }

  function rawHours(place, y, m, d, zone) {
    const jDate = julian(y, m, d) - place.lon / (15 * 24);
    const lat = place.lat;
    const sun = (jd) => {
      const D = jd - 2451545;
      const g = fixAngle(357.529 + 0.98560028 * D);
      const q = fixAngle(280.459 + 0.98564736 * D);
      const L = fixAngle(q + 1.915 * Math.sin(rad(g)) + 0.02 * Math.sin(rad(2 * g)));
      const e = 23.439 - 0.00000036 * D;
      const ra = fixHour(deg(Math.atan2(Math.cos(rad(e)) * Math.sin(rad(L)), Math.cos(rad(L)))) / 15);
      return { decl: deg(Math.asin(Math.sin(rad(e)) * Math.sin(rad(L)))), eqt: q / 15 - ra };
    };
    const noon = (t) => fixHour(12 - sun(jDate + t).eqt);
    const angleTime = (angle, t, ccw) => {
      const decl = sun(jDate + t).decl;
      const x = (-Math.sin(rad(angle)) - Math.sin(rad(decl)) * Math.sin(rad(lat))) / (Math.cos(rad(decl)) * Math.cos(rad(lat)));
      const h = deg(Math.acos(Math.max(-1, Math.min(1, x)))) / 15;
      return noon(t) + (ccw ? -h : h);
    };
    const asrTime = (t) => {
      const decl = sun(jDate + t).decl;
      return angleTime(-deg(Math.atan(1 / (1 + Math.tan(rad(Math.abs(lat - decl)))))), t, false);
    };
    let r = { fajr: 5, sunrise: 6, dhuhr: 12, asr: 13, maghrib: 18, isha: 18 };
    for (let i = 0; i < 2; i++) {
      r = { fajr: angleTime(20, r.fajr / 24, true), sunrise: angleTime(0.833, r.sunrise / 24, true), dhuhr: noon(r.dhuhr / 24),
        asr: asrTime(r.asr / 24), maghrib: angleTime(0.833, r.maghrib / 24, false), isha: angleTime(18, r.isha / 24, false) };
    }
    const shift = zone - place.lon / 15;
    for (const k in r) r[k] += shift;
    return r;
  }

  /** Waktu-waktu hari itu: [{key, title, prayer, date}] */
  function times(place, date = new Date(), ihtiyat = 2) {
    const zone = zoneHours(place.tz, date);
    const [y, m, d] = ymd(place.tz, date);
    const midnightUtc = Date.UTC(y, m - 1, d) - zone * 3600000;
    const raw = rawHours(place, y, m, d, zone);
    const at = (h, shift) => new Date(midnightUtc + Math.round(h * 60 + shift) * 60000);
    const subuh = at(raw.fajr, ihtiyat);
    const list = [new Date(subuh - 600000), subuh, at(raw.sunrise, -ihtiyat), at(raw.dhuhr, ihtiyat), at(raw.asr, ihtiyat), at(raw.maghrib, ihtiyat), at(raw.isha, ihtiyat)];
    return NAMES.map(([key, title, prayer], i) => ({ key, title, prayer, date: list[i] }));
  }

  function next(place, now = new Date()) {
    const t = times(place, now).filter((x) => x.prayer && x.date > now);
    return t[0] || times(place, new Date(+now + 86400000)).find((x) => x.key === 'subuh');
  }

  function qibla(place) {
    const k = { lat: rad(21.4225), lon: rad(39.8262) }, p = { lat: rad(place.lat), lon: rad(place.lon) };
    const d = k.lon - p.lon;
    const b = deg(Math.atan2(Math.sin(d) * Math.cos(k.lat), Math.cos(p.lat) * Math.sin(k.lat) - Math.sin(p.lat) * Math.cos(k.lat) * Math.cos(d)));
    const deg360 = (b + 360) % 360;
    const pts = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
    return { deg: deg360, point: pts[Math.round(deg360 / 22.5) % 16] };
  }

  /** Pengingat: 10 menit sebelum (soon) dan pas masuk waktu (now); sekali tiap waktu. */
  class Alarm {
    constructor(place) { this.place = place; this.fired = new Set(); this.lead = 600000; this.grace = 120000; }
    check(now = new Date()) {
      for (const t of times(this.place, now)) {
        if (!t.prayer) continue;
        const key = `${+t.date}-${t.key}`, until = t.date - now;
        if (until <= 0 && -until < this.grace && !this.fired.has(key + 'now')) { this.fired.add(key + 'now'); this.fired.add(key + 'soon'); return { type: 'now', ...t }; }
        if (until > 0 && until <= this.lead && !this.fired.has(key + 'soon')) { this.fired.add(key + 'soon'); return { type: 'soon', ...t }; }
      }
      return null;
    }
  }

  root.Prayer = { CITIES, times, next, qibla, Alarm, city: (name) => CITIES.find((c) => c.name === name) || CITIES[0] };
})(typeof window !== 'undefined' ? window : globalThis);

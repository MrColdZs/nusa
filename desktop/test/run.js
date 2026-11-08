// node test/run.js — cek jadwal sholat & pembaca tugas
require('../app/lib/prayer.js');
require('../app/lib/tasks.js');
const { Prayer, TaskParser } = globalThis;
let fail = 0;
const ok = (name, cond, extra = '') => { console.log(cond ? 'ok  ' : 'FAIL', name, extra); if (!cond) fail++; };
const hm = (d) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Jakarta', hour: '2-digit', minute: '2-digit' }).format(d);

// Acuan Aladhan metode 20 (Kemenag, tanpa ihtiyat), sama kayak tes versi Mac
const ref = [['2026-11-08T12:00:00+07:00', ['03:53', '04:03', '05:24', '11:35', '14:55', '17:46', '18:59']],
  ['2027-01-15T12:00:00+07:00', ['04:13', '04:23', '05:47', '12:01', '15:25', '18:14', '19:29']],
  ['2027-06-20T12:00:00+07:00', ['04:26', '04:36', '06:00', '11:53', '15:15', '17:46', '19:01']]];
let worst = 0;
for (const [d, exp] of ref) {
  const got = Prayer.times(Prayer.city('Cikarang'), new Date(d), 0).map((t) => hm(t.date));
  got.forEach((g, i) => { const [a, b] = [g, exp[i]].map((s) => s.split(':').map(Number)); worst = Math.max(worst, Math.abs(a[0] * 60 + a[1] - b[0] * 60 - b[1])); });
}
ok('jadwal sholat cocok Kemenag/Aladhan', worst <= 1, `(maks selisih ${worst} menit)`);
ok('kiblat Jakarta ~295° WNW', Math.round(Prayer.qibla(Prayer.city('Jakarta')).deg) === 295 && Prayer.qibla(Prayer.city('Jakarta')).point === 'WNW');
const mk = Prayer.times(Prayer.city('Makassar'), new Date('2026-11-08T12:00:00+08:00')).find((t) => t.key === 'maghrib');
ok('Makassar pakai WITA', new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Makassar', hour: '2-digit', minute: '2-digit' }).format(mk.date) === '17:58');

const maghrib = Prayer.times(Prayer.city('Cikarang'), new Date('2026-11-08T12:00:00+07:00')).find((t) => t.key === 'maghrib').date;
const a = new Prayer.Alarm(Prayer.city('Cikarang'));
ok('alarm: 10 menit sebelum', a.check(new Date(+maghrib - 590000))?.type === 'soon');
ok('alarm: nggak dobel', a.check(new Date(+maghrib - 300000)) === null);
ok('alarm: masuk waktu', a.check(new Date(+maghrib + 5000))?.type === 'now');
ok('alarm: Mac/PC bangun telat diem', new Prayer.Alarm(Prayer.city('Cikarang')).check(new Date(+maghrib + 300000)) === null);

// Pembaca tugas: "sekarang" = Minggu 8 Nov 2026 17:30 (jam lokal mesin tes)
const now = new Date(2026, 10, 8, 17, 30);
const fmt = (d) => d ? `${['Sun', 'Mon', 'Tue'][d.getDay()]} ${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}` : '-';
for (const [input, title, due] of [
  ['meeting besok jam 2 siang', 'meeting', 'Mon 9 14:00'], ['Rapat QC besok jam 9', 'Rapat QC', 'Mon 9 09:00'],
  ['minum obat 30 menit lagi', 'minum obat', 'Sun 8 18:00'], ['telpon ibu nanti malam', 'telpon ibu', 'Sun 8 20:00'],
  ['upload video jam 7 malam', 'upload video', 'Sun 8 19:00'], ['bayar listrik jam 9', 'bayar listrik', 'Mon 9 09:00'],
  ['beli galon lusa', 'beli galon', 'Tue 10 09:00'], ['cek mesin jam 15.30', 'cek mesin', 'Mon 9 15:30'],
  ['beresin laporan', 'beresin laporan', '-'], ['Call Budi tomorrow at 9am', 'Call Budi', 'Mon 9 09:00'],
  ['Submit report in 2 hours', 'Submit report', 'Sun 8 19:30'], ['Rekap journal untuk 1 jam lagi', 'Rekap journal', 'Sun 8 18:30'],
  ['cek email dalam 30 menit', 'cek email', 'Sun 8 18:00'], ['Gym tonight', 'Gym', 'Sun 8 20:00'],
]) {
  const r = TaskParser.parse(input, now);
  ok(`"${input}"`, r.title === title && fmt(r.due) === due, `-> "${r.title}" @ ${fmt(r.due)}`);
}
process.exit(fail ? 1 : 0);

// Salin aset bersama (Quran, adzan, font) dari ../assets ke app/assets biar ikut dibundel.
const fs = require('fs');
const path = require('path');
const src = path.join(__dirname, '..', '..', 'assets');
const dst = path.join(__dirname, '..', 'app', 'assets');
fs.mkdirSync(path.join(dst, 'fonts'), { recursive: true });
for (const f of ['quran.json', 'adhan.mp3', 'CREDITS.md']) fs.copyFileSync(path.join(src, f), path.join(dst, f));
for (const f of fs.readdirSync(path.join(src, 'fonts'))) fs.copyFileSync(path.join(src, 'fonts', f), path.join(dst, 'fonts', f));
console.log('aset disalin ke app/assets');

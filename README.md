# Nusa

Dynamic Island buat MacBook: notch di tengah menu bar yang nampilin lagu, pengingat tugas, waktu sholat, cuaca, dan fokus, lalu kebuka jadi panel kalau diklik.

## Build (macOS)

```sh
./build.sh            # build, pasang ke ~/Applications, buka ulang
./build.sh --no-install
```

Butuh Xcode Command Line Tools (swiftc, clang) dan Python 3 + Pillow buat ikon.

## Isi

- `Sources/` — app SwiftUI (notch, panel, tab Home/Music/Tasks/Tray/Clips/Prayer/Quran)
- `helper/` — pembaca Now Playing (dylib yang dimuat `/usr/bin/perl`, karena macOS 15.4+ ngeblok MediaRemote buat app biasa)
- `assets/` — adzan, data Quran, font Arab; sumber & lisensinya di `assets/CREDITS.md`
- `desktop/` — versi Windows & Linux (Electron)

## Windows & Linux (`desktop/`)

Versi Electron, logikanya sama dengan versi Mac (jadwal sholat, Quran, tugas, fokus, cuaca).

```sh
cd desktop
npm install          # di Mac ini: kalau Electron belum keunduh, jalanin node node_modules/electron/install.js
npm test             # tes jadwal sholat & pembaca tugas
npm start            # jalanin buat development
npm run dist:win     # installer Windows (wizard), hasil di desktop/dist
npm run dist:linux   # AppImage + .deb
```

Di Windows & Linux notch-nya mode tipis di tepi atas (biar nggak nutup tab browser), membesar pas di-hover.
Info lagu: Windows dari media controls sistem, Linux dari `playerctl` (MPRIS), cadangannya antrean Senandung.

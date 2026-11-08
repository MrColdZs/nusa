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

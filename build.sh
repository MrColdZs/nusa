#!/bin/sh
# Bikin Nusa.app, pasang ke ~/Applications, lalu buka ulang. Pakai --no-install buat build doang.
set -e
cd "$(dirname "$0")"
APP=dist/Nusa.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist/AppIcon.iconset

# Universal: jalan di Mac Apple Silicon (arm64) & Intel (x86_64)
FRAMEWORKS="-framework AppKit -framework SwiftUI -framework AudioToolbox -framework CoreAudio -framework IOKit -framework ServiceManagement -framework EventKit -framework AVFoundation -framework MediaPlayer"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $ARCH-apple-macos14 Sources/*.swift -o "dist/Nusa-$ARCH" $FRAMEWORKS
done
lipo -create dist/Nusa-arm64 dist/Nusa-x86_64 -output "$APP/Contents/MacOS/Nusa"
rm dist/Nusa-arm64 dist/Nusa-x86_64

# /usr/bin/perl jalan sebagai arm64e, helper harus punya arsitektur yang sama
clang -O2 -dynamiclib -fobjc-arc -arch arm64 -arch arm64e -arch x86_64 -framework Foundation \
  helper/media.m -o "$APP/Contents/Resources/media.dylib"
cp helper/run.pl "$APP/Contents/Resources/"
cp assets/adhan.mp3 assets/quran.json assets/CREDITS.md "$APP/Contents/Resources/"
cp -R assets/fonts "$APP/Contents/Resources/"

python3 - <<'PY'
from PIL import Image, ImageDraw
S = 4096
c = Image.new('RGBA', (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(c)
d.rounded_rectangle((400, 400, S - 401, S - 401), radius=740, fill=(242, 242, 247, 255))
d.rounded_rectangle((1000, 1160, S - 1001, 1720), radius=280, fill=(0, 0, 0, 255))
for s in (16, 32, 128, 256, 512):
    c.resize((s, s), Image.LANCZOS).save(f'dist/AppIcon.iconset/icon_{s}x{s}.png')
    c.resize((s * 2, s * 2), Image.LANCZOS).save(f'dist/AppIcon.iconset/icon_{s}x{s}@2x.png')
PY
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nusa</string>
  <key>CFBundleDisplayName</key><string>Nusa</string>
  <key>CFBundleIdentifier</key><string>site.faquloh.nusa</string>
  <key>CFBundleExecutable</key><string>Nusa</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>ATSApplicationFontsPath</key><string>fonts</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Nusa shows your calendar events in the panel.</string>
  <key>NSCalendarsUsageDescription</key><string>Nusa shows your calendar events in the panel.</string>
  <key>NSCameraUsageDescription</key><string>The camera powers the mirror in the panel and only turns on when you click it.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force -s - "$APP/Contents/Resources/media.dylib"
codesign --force -s - "$APP"
(cd dist && ditto -c -k --keepParent Nusa.app Nusa-macOS.zip)
[ "$1" = "--no-install" ] && exit 0

osascript -e 'tell application "Nusa" to quit' 2>/dev/null || true
rm -rf "$HOME/Applications/Nusa.app"
cp -R "$APP" "$HOME/Applications/"
open "$HOME/Applications/Nusa.app"
echo "Terpasang: $HOME/Applications/Nusa.app"

#!/bin/bash
# Musica: mette mediaremote-adapter (https://github.com/ungive/mediaremote-adapter, BSD-3-Clause)
# dentro Isola.app.
#   bash tools/embed-music.sh "<percorso di Isola.app>"
#
# Su macOS 15.4+ il framework privato MediaRemote non risponde più alle app di terzi:
# l'adattatore gira dentro /usr/bin/perl (che ha il permesso) e carica un piccolo framework
# nostro. Qui il framework viene compilato dai sorgenti, con clang (niente CMake, niente binari
# scaricati), e copiato in Contents/Frameworks; lo script perl e la licenza vanno in
# Contents/Resources. I sorgenti e la build stanno in ~/Library/Caches/isola-build (fuori da iCloud).
#
# Variabili facoltative:
#   MEDIAREMOTE_ADAPTER_SRC   cartella del clone (predefinita: ~/Library/Caches/isola-build/mediaremote-adapter)
#   MEDIAREMOTE_ADAPTER_REBUILD=1   ricompila anche se la build c'è già
set -euo pipefail

APP="${1:?Uso: embed-music.sh <percorso di Isola.app>}"
[ -d "$APP/Contents" ] || { echo "embed-music: $APP non sembra un'app" >&2; exit 1; }

REPO="https://github.com/ungive/mediaremote-adapter.git"
# Versione provata con Isola (11 novembre 2026). Per aggiornare: cambia il commit e ricompila.
PIN="14eed9389241d06e29f7326c19e9ebc6ec8a5f36"
CACHE="$HOME/Library/Caches/isola-build"
SRC="${MEDIAREMOTE_ADAPTER_SRC:-$CACHE/mediaremote-adapter}"
OUT="$CACHE/mediaremote-adapter-build"
NAME="MediaRemoteAdapter"
FW="$OUT/$NAME.framework"
STAMP="$OUT/.built-from"

# 1. Sorgenti: clone al commit fissato, se mancano.
if [ ! -d "$SRC/.git" ]; then
  echo "embed-music: scarico i sorgenti di mediaremote-adapter"
  mkdir -p "$(dirname "$SRC")"
  git clone --quiet "$REPO" "$SRC"
  git -C "$SRC" checkout --quiet "$PIN"
fi
HEAD="$(git -C "$SRC" rev-parse HEAD)"
[ "$HEAD" = "$PIN" ] || echo "embed-music: attenzione, i sorgenti sono a $HEAD (provato: $PIN)" >&2

# 2. Framework universale (arm64 + x86_64), come il CMakeLists.txt del progetto.
if [ "${MEDIAREMOTE_ADAPTER_REBUILD:-0}" = "1" ] || [ ! -f "$FW/Versions/A/$NAME" ] \
   || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$HEAD" ]; then
  echo "embed-music: compilo $NAME.framework"
  rm -rf "$FW"
  mkdir -p "$FW/Versions/A/Resources" "$FW/Versions/A/Headers"
  SOURCES=(
    src/adapter/env.m src/adapter/get.m src/adapter/globals.m src/adapter/keys.m
    src/adapter/now_playing.m src/adapter/repeat.m src/adapter/seek.m src/adapter/send.m
    src/adapter/shuffle.m src/adapter/speed.m src/adapter/stream.m src/adapter/test.m
    src/private/MediaRemote.m src/utility/Debounce.m src/utility/helpers.m
  )
  ABS=()
  for s in "${SOURCES[@]}"; do ABS+=("$SRC/$s"); done
  clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 \
    -fobjc-arc -fvisibility=default \
    -I "$SRC/include" -I "$SRC/src" \
    "${ABS[@]}" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name "@rpath/$NAME.framework/Versions/A/$NAME" \
    -current_version 0.1.0 -compatibility_version 0.1.0 \
    -o "$FW/Versions/A/$NAME"
  cp "$SRC/include/MediaRemoteAdapter.h" "$FW/Versions/A/Headers/"
  cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.vandenbe.$NAME</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST
  ln -s A "$FW/Versions/Current"
  ln -s "Versions/Current/$NAME" "$FW/$NAME"
  ln -s Versions/Current/Resources "$FW/Resources"
  ln -s Versions/Current/Headers "$FW/Headers"
  codesign --force --sign - --timestamp=none "$FW" >/dev/null 2>&1
  echo "$HEAD" > "$STAMP"
fi

# 3. Nel pacchetto. build-app.sh firma poi tutto Contents/Frameworks con la sua identità.
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources"
rm -rf "$APP/Contents/Frameworks/$NAME.framework"
cp -R "$FW" "$APP/Contents/Frameworks/"
cp "$SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/mediaremote-adapter.pl"
cp "$SRC/LICENSE" "$APP/Contents/Resources/mediaremote-adapter-LICENSE.txt"
echo "embed-music: mediaremote-adapter nel pacchetto"

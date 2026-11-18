#!/bin/bash
# Crea Isola.app e (con --install) la mette in ~/Applications e la avvia.
#   bash tools/build-app.sh            # solo build/Isola.app
#   bash tools/build-app.sh --install  # e installa
# I file di compilazione stanno in ~/Library/Caches/isola-build: la cartella Documenti
# è su iCloud e non deve sincronizzare gigabyte di file temporanei.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SCRATCH="$HOME/Library/Caches/isola-build/app"
OUT="$HOME/Library/Caches/isola-build/Isola.app"

[ -f Resources/AppIcon.icns ] || swift tools/make-icon.swift

swift build -c release --product Isola --scratch-path "$SCRATCH"
BIN="$(swift build -c release --product Isola --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"
cp "$BIN/Isola" "$OUT/Contents/MacOS/Isola"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
# Risorse dei moduli (Bundle.module).
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$OUT/Contents/Resources/"; done
# Ogni modulo può aggiungere roba al pacchetto con tools/embed-<nome>.sh "<percorso di Isola.app>".
for s in tools/embed-*.sh; do [ -e "$s" ] && bash "$s" "$OUT"; done

# Firma: il certificato Apple Development se c'è (così i permessi di macOS restano dopo
# ogni build), altrimenti ad hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
SIGN="${IDENTITY:--}"
find "$OUT/Contents/Frameworks" -mindepth 1 -maxdepth 1 -exec codesign --force --sign "$SIGN" --timestamp=none {} \; 2>/dev/null || true
codesign --force --sign "$SIGN" --timestamp=none --options runtime \
  --entitlements Resources/Isola.entitlements "$OUT"
echo "Pronta: $OUT (firma: ${IDENTITY:-ad hoc})"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/Isola.app"
  mkdir -p "$HOME/Applications"
  pkill -x Isola 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST"
  cp -R "$OUT" "$DEST"
  open "$DEST"
  echo "Installata in $DEST e avviata"
fi

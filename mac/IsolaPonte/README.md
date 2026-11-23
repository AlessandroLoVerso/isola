# Isola Ponte per macOS

App della barra dei menu che condivide gli appunti (testo e immagini) tra questo Mac e Isola su
Windows, attraverso Tailscale. Specifica: [`docs/isola-ponte-mac.md`](../../docs/isola-ponte-mac.md);
protocollo: [`docs/appunti-condivisi.md`](../../docs/appunti-condivisi.md).

## Costruire

```bash
swift test --scratch-path ~/Library/Caches/isola-build/ponte   # test, firme comprese
./build-app.sh             # crea IsolaPonte.app qui accanto (firma ad-hoc)
./build-app.sh --install   # e la copia in /Applications
```

Il build gira in `~/Library/Caches/isola-build/ponte`, fuori da iCloud Drive: iCloud aggiunge
attributi ai file che `codesign` rifiuta.

## Struttura

- `Sources/PonteCore`: il protocollo senza interfaccia (chiave base32, firma HMAC-SHA256, JSON
  rigoroso come `JsonDocument` di .NET, server HTTP minimo, client). È la parte coperta dai test.
- `Sources/IsolaPonte`: l'app (barra dei menu, impostazioni in SwiftUI, Portachiavi, appunti).
- `Tests/PonteCoreTests`: le firme e i corpi devono uscire uguali byte per byte a
  `docs/appunti-condivisi.esempio.json`; più parsing, codici di risposta e server vero in locale.

## Note

- Il server usa socket BSD e non `NWListener`: su questo Mac un `NWListener` non riceve le
  connessioni che arrivano dal tunnel di Tailscale (`utun`). Il test
  `testListensOnTailscaleAddress` lo controlla quando Tailscale è attivo.
- Ascolta solo sull'indirizzo Tailscale IPv4 del Mac, porta 47323, e accetta solo connessioni
  da indirizzi Tailscale.
- I file copiati nel Finder non vengono inviati: il protocollo prevede solo testo e immagini.
- La firma è ad-hoc: dopo una ricostruzione macOS può chiedere di nuovo il permesso di leggere la
  chiave nel Portachiavi.

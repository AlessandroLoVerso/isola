# Isola per macOS: il contratto dei moduli

Swift 5 (modalità linguaggio 5, compilatore 6.2), SwiftUI + AppKit, macOS 14+. Il Mac di
riferimento è un MacBook Air M3 con macOS 15, notch di 179 × 32 punti.

Ogni funzione è un **modulo**, un target Swift a sé in `Sources/Modules/<Nome>/`
(prodotto `Isola<Nome>`). Il core (`Sources/IsolaCore`, `Sources/IsolaApp`) non sa niente dei
moduli: li trova nel registro `Sources/IsolaApp/ModuleRegistry.swift`.

## Regole d'oro

1. **Lavora solo nella tua cartella** `Sources/Modules/<Nome>/`. Non toccare `IsolaCore`,
   `IsolaApp`, `Package.swift`, né le cartelle degli altri moduli. Se ti serve qualcosa dal core,
   scrivilo nel resoconto: il contratto resta stabile.
2. **Una classe** `public final class <Nome>Module: IslandModule` con `public init()` leggero
   (il nome della classe è già nel registro: non cambiarlo). Il lavoro vero comincia in `start`.
3. **Id stabile** (già scelto nel segnaposto). È la chiave di impostazioni e dati.
4. **CPU a riposo ~0%**: niente timer a vuoto. Usa notifiche di sistema (IOKit, CoreAudio,
   NSWorkspace, EventKit…). Se serve un timer, fallo girare solo quando c'è qualcosa da mostrare
   (scheda visibile: `host.onCardVisibilityChange`, oppure faccia sulla pillola).
5. **Libera tutto in `stop()`**: timer, osservatori, listener, processi figli, hotkey. Il modulo può
   essere spento e riacceso a caldo, anche più volte.
6. **Testo in italiano**, breve e chiaro. Niente dati fuori dal Mac salvo opzioni esplicite,
   spente di default. Il log non contiene nomi di file, app, persone o contenuti.
7. **Niente permessi a sorpresa**: chiedi un permesso di macOS (Calendario, Bluetooth, Automazione…)
   solo quando l'utente accende la funzione o apre la scheda, con una riga che spiega perché.
   Le chiavi `NS…UsageDescription` sono già in `Resources/Info.plist`; se te ne serve un'altra,
   scrivilo nel resoconto.
8. **API private** (MediaRemote, DisplayServices, IOBluetooth non documentate): solo con `dlopen`/
   `dlsym` o `responds(to:)`, con un ripiego se non ci sono. Mai un crash se mancano.

## Il protocollo (`Sources/IsolaCore/IslandModule.swift`)

| Protocollo | Obbligatorio | A cosa serve |
|---|---|---|
| `IslandModule` | sì | Identità, ciclo di vita, scheda, pagina impostazioni |
| `RestingFaceProvider` | no | Cosa mostrare accanto alla notch a isola chiusa |
| `PeekProvider` | no | La riga sotto la notch quando chiami `host.attention(duration:)` |
| `StripProvider` | no | Cosa mostrare accanto alla notch sopra le app a schermo intero |

### IslandModule

- `id`, `title` (etichetta), `symbol` (nome di un **SF Symbol** che esiste su macOS 14),
  `order`, `enabledByDefault`.
- `start(host:) throws` sul main thread. Tieni `host`. Se lanci, il modulo si spegne e l'errore
  (`localizedDescription`, in italiano) compare in Impostazioni › Moduli.
- `stop()`.
- `makeCard() -> AnyView?` chiamata **una volta** dopo `start`: la scheda, area
  `IslandMetrics.card` = **536 × 196 punti**, sfondo già dipinto. `nil` = nessuna scheda.
  La vista può essere ricreata da SwiftUI quando si cambia scheda: tieni lo stato in un modello
  (`ObservableObject` o `@Observable`) di proprietà del modulo, non in `@State`.
- `makeSettings() -> AnyView?` chiamata ogni volta che la pagina si apre (Impostazioni di macOS,
  sfondo chiaro o scuro di sistema). Usa `Form { Section { … } }`: il core applica
  `.formStyle(.grouped)`. Qui **non** usare i colori dell'isola: è una finestra normale.

### RestingFaceProvider

- `restingPriority`: vince il più alto, `0` = niente. A parità vince l'`order` più basso.
  Riferimenti: agente che aspetta 90 · microfono muto o chiamata 80 · evento tra pochi minuti 70 ·
  batteria scarica 65 · in carica (pochi secondi) 60 · timer di concentrazione 55 ·
  musica in riproduzione 50 · ora 1.
- Quando cambia, chiama `host.refreshRestingFace()`.
- `makeRestingFace() -> RestingFace(sideWidth:leading:trailing:)`: due viste, una a sinistra e
  una a destra della notch, alte quanto la notch (32 pt), larghe `sideWidth` (predefinito 72).
  Un valore nuovo a ogni chiamata; aggiornale con il modello osservabile.
  Esempio: copertina a sinistra, barre dell'equalizzatore a destra.

### PeekProvider e attention

- `host.attention(duration:)` allarga la pillola: sopra c'è la tua faccia (se sei il vincitore),
  sotto una riga di `IslandMetrics.peek` = **360 × 40** con `makePeek()`. Senza `PeekProvider`:
  icona e titolo del modulo. Si vede anche sopra le app a schermo intero. Ignorato a scheda aperta.
  Passando il puntatore si apre la tua scheda.

### StripProvider

- `wantsStrip` + `makeStrip() -> RestingFace`: usata sopra le app a schermo intero se l'utente ha
  scelto "Striscia". Quando `wantsStrip` cambia, chiama `host.refreshRestingFace()`.

### IslandHost (quello che ricevi)

| Membro | Note |
|---|---|
| `refreshRestingFace()` | Rivaluta facce e striscia. |
| `openTab(id)` | Apre la scheda; se il puntatore non è sopra si richiude dopo 4 s. |
| `attention(duration:)` | Vedi sopra (max 300 s). |
| `requestKeyboardFocus()` | Chiamala quando l'utente tocca un `TextField` della scheda (`.onTapGesture` o `@FocusState`): l'isola prende la tastiera senza attivare l'app. Si restituisce da sola alla chiusura. |
| `isCardVisible`, `onCardVisibilityChange` | La tua scheda è aperta. |
| `isFullscreenAppActive`, `onFullscreenChange` | Un'app copre lo schermo dell'isola. |
| `screenHasNotch` | Lo schermo ha la notch vera. |
| `loadSettings(T.self, fallback:)` / `saveSettings(v)` | JSON in `~/Library/Application Support/Isola/settings/<id>.json`. |
| `dataDirectory` | `~/Library/Application Support/Isola/data/<id>/`. |
| `log(msg)` | `~/Library/Application Support/Isola/logs/isola.log`. |

Nel core ci sono anche `HotKey` (scorciatoie globali Carbon, senza permesso di Accessibilità),
`AppPaths`, `JSONStore`, `Log`.

## Stile

- `@Environment(\.island) var theme`: `background`, `foreground`, `muted`, `accent`, `surface`,
  `surfaceHover`, `isGlass`. Colori fissi: `IslandTheme.orange`, `.green`, `.red`. Il tema cambia a
  caldo (Nero, Grafite, Vetro, Liquido): non fissare colori di sfondo tuoi sulla scheda.
- Testo: `IslandFont.small` (11), `.body` (13), `.bodyBold`, `.title` (16), `.mono(size)` per i numeri.
- Pronti: `IslandButtonStyle()` (anche `prominent: true`), `IslandIconButton("play.fill") { }`,
  `IslandSurface { }`, `IslandEmptyState(symbol, title:, subtitle:)`.
- Animazioni brevi (0,15–0,35 s), `.spring` per le cose che crescono.

## Compilare e provare

La cartella Documenti è su iCloud: **compila sempre fuori**, con una cartella tua:

```bash
swift build --target IsolaMusic --scratch-path ~/Library/Caches/isola-build/music
```

Il pacchetto completo (`bash tools/build-app.sh --install`) lo crea chi integra: non avviarlo mentre
lavorano altri moduli. Per provare del codice dal vivo, scrivi uno script usa e getta in una cartella
temporanea tua.

Per vedere le schede senza guardare lo schermo (anche a Mac bloccato):
`open isola://open/<id>` e poi `open isola://debug/snapshot/<nome>`, che salva un PNG della
finestra dell'isola in `~/Library/Caches/isola-build/snapshots/`.

Un modulo che deve mettere file dentro `Isola.app` (framework, script, licenze) aggiunge
`tools/embed-<nome>.sh`, che riceve come primo argomento il percorso di `Isola.app` e copia in
`Contents/Frameworks` o `Contents/Resources`. Le risorse SwiftPM (`Bundle.module`) vengono già
copiate dallo script di build.

## Riferimento Windows

La versione per Windows è in `../src/Isola/Modules/<Nome>/` (C#/WPF): stesse funzioni, stessi testi
dove ha senso. Su Mac si integra con il sistema dove conviene (SF Symbols, EventKit, CoreAudio,
NSSharingService…).

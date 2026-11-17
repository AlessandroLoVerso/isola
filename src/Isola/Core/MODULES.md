# Moduli di Isola: il contratto

Ogni funzione dell'isola è un **modulo**. Il core (finestra, impostazioni, icona) non sa nulla
dei moduli: li trova da solo per reflection all'avvio.

## Regole d'oro

1. **Lavora solo nella tua cartella**: `src/Isola/Modules/<Nome>/`, namespace
   `Isola.Modules.<Nome>`. Non modificare file fuori da lì (né `Core/`, né `Island/`, né il `.csproj`
   senza accordo). Se ti serve qualcosa dal core, chiedilo: il contratto resta stabile.
2. **Una classe pubblica, non astratta, con costruttore pubblico senza parametri** che implementa
   `IIslandModule`. Basta questo per essere caricati. Il costruttore deve essere leggero: il lavoro
   vero comincia in `Start`.
3. **Id unico, minuscolo, stabile** (`"music"`, `"clipboard"`...). È la chiave delle impostazioni e
   della cartella dati. Non cambiarlo mai dopo il rilascio.
4. **CPU a riposo 0%**: niente timer che girano a vuoto. Usa eventi; se serve un timer, fallo
   ticchettare solo quando c'è qualcosa da mostrare (vedi `Clock`: un tick al minuto, al secondo solo
   mentre la scheda è visibile, tramite `IsVisibleChanged`).
5. **Libera tutto in `Stop()`**: timer, hook, eventi di sistema, handle nativi. Il modulo può essere
   spento e riacceso a caldo dalle impostazioni, anche più volte.
6. **P/Invoke**: le chiamate Win32 condivise stanno in `src/Isola/Native/`. Le dichiarazioni usate solo
   dal tuo modulo mettile in un file `Native*.cs` dentro la tua cartella.
7. **Testo in italiano**, breve. Niente dati fuori dal PC salvo opzioni esplicite, spente di default.

## Le interfacce (`Core/IIslandModule.cs`)

| Interfaccia | Obbligatoria | A cosa serve |
|---|---|---|
| `IIslandModule` | sì | Identità, ciclo di vita, scheda, pagina impostazioni |
| `IRestingFaceProvider` | no | Contenuto della pillola chiusa (e del "peek" di `Attention`) |
| `IStripProvider` | no | Contenuto della striscia sopra le app a schermo intero |

### IIslandModule

- `Id`, `Title` (etichetta della scheda), `Glyph` (carattere di *Segoe Fluent Icons*, es. `""`),
  `Order` (ordine delle schede, crescente), `EnabledByDefault`.
- `Start(IIslandHost host)` — sul thread UI. Tieni il riferimento a `host`.
- `Stop()` — sul thread UI.
- `CreateCard()` — chiamata **una volta** dopo `Start`. Restituisce il contenuto della tua scheda
  (area di circa **424 × 186 DIP**, sfondo già dipinto dall'isola) oppure `null` se non vuoi una scheda.
- `CreateSettingsPage()` — chiamata **ogni volta** che la pagina viene mostrata (e una volta per sapere
  se esiste): restituisci un elemento nuovo, oppure `null` per nessuna pagina.

### IRestingFaceProvider

- `RestingPriority`: la priorità **attuale**. Vince il valore più alto; `0` = niente da mostrare.
  A parità vince l'`Order` più basso. Se nessuno ha priorità > 0 l'isola mostra la faccia predefinita
  (ora `HH:mm` a sinistra, puntino a destra). Riferimenti: Orologio = 1; musica in riproduzione ≈ 50;
  microfono muto / chiamata ≈ 80; agente che aspetta ≈ 90.
- Quando la tua priorità cambia chiama `host.RefreshRestingFace()`.
- `CreateRestingFace()` deve restituire **un elemento nuovo a ogni chiamata** (l'host può averne due
  insieme: pillola e peek). Viene steso su tutta la pillola (circa 158 × 34 DIP, margini inclusi):
  impagina tu sinistra/centro/destra. Tieni gli elementi aggiornati con un view model e i binding,
  come fa `ClockModule`. L'elemento resta finché il tuo modulo resta il vincitore.

### IStripProvider

- `WantsStrip`: `true` quando hai qualcosa per la striscia (es. FPS di un gioco). Quando cambia chiama
  `host.RefreshRestingFace()`, che rivaluta anche la striscia.
- `CreateStrip()`: elemento nuovo, circa 272 × 24 DIP. Usato solo se l'utente ha scelto "Striscia"
  per le app a schermo intero; se nessun modulo la vuole, l'isola si nasconde.

### IIslandHost (quello che ricevi in `Start`)

Ogni modulo riceve **la sua** istanza. Tutti i metodi si possono chiamare da qualsiasi thread (quelli
che toccano l'isola vengono portati sul thread UI); le modifiche alla tua UI però vanno fatte tu sul
`Dispatcher`.

| Membro | Note |
|---|---|
| `Dispatcher` | Il dispatcher del thread UI. |
| `Hwnd` | La finestra dell'isola: per `RegisterHotKey`, `AddClipboardFormatListener`, ecc. |
| `AddMessageHook(Func<int,IntPtr,IntPtr,bool>)` | Hook sulla WndProc dell'isola `(msg, wParam, lParam) => gestito`. Rimosso da solo quando il modulo si ferma. Restituisci `true` solo per i messaggi tuoi. |
| `RefreshRestingFace()` | Rivaluta priorità delle facce e `WantsStrip`. |
| `OpenTab(id)` | Apre la scheda sul modulo. Se il mouse non è sopra, si richiude dopo 4 s. |
| `Attention(id, durata)` | Allarga la pillola a "peek" (330 × 48) con la tua `CreateRestingFace()` (o icona + titolo se non sei un `IRestingFaceProvider`). Appare anche sopra le app a schermo intero. Ignorato se la scheda è aperta. |
| `RequestKeyboardFocus()` | Da chiamare quando l'utente clicca in una casella di testo della tua scheda: l'isola diventa attivabile e prende la tastiera. Tutto torna com'era quando la scheda si chiude (anche con Esc o clic fuori). |
| `IsFullscreenAppActive`, `FullscreenChanged` | Un'app copre il monitor dell'isola (gioco, video). L'evento arriva sul thread UI. |
| `LoadSettings<T>(id)` / `SaveSettings<T>(id, v)` | JSON in `%LocalAppData%\Isola\settings\{id}.json`. File mancante o rotto ⇒ `new T()`. |
| `DataDirectory(id)` | `%LocalAppData%\Isola\data\{id}\`, creata se manca. |
| `Log(id, testo)` | Riga in `%LocalAppData%\Isola\logs\isola.log`. |

## Errori

L'host avvolge ogni chiamata al modulo (`Start`, `Stop`, `Create*`, le proprietà, gli hook, gli
handler di `FullscreenChanged`) in un `try/catch`. Se il modulo lancia un'eccezione viene **spento per
questa sessione**, l'errore va nel log e compare nella pagina *Moduli*; l'interruttore lo riprova.
Anche le eccezioni non gestite sul thread UI (es. nel `Tick` di un tuo timer) vengono attribuite al
modulo dal cui namespace provengono, e il modulo viene spento. L'app resta viva.

Nei task in background gestisci tu le eccezioni (quelle non osservate finiscono solo nel log).

## Tema e stile

Usa sempre `DynamicResource` (o `SetResourceReference` da codice): il tema cambia a caldo.

| Chiave | Tipo |
|---|---|
| `Isola.Brush.Background` | sfondo dell'isola (Nero `#0B0B0D`, Grafite `#2A2B30`) |
| `Isola.Brush.Foreground` | testo principale |
| `Isola.Brush.Muted` | testo secondario |
| `Isola.Brush.Accent` | accento (blu) |
| `Isola.Brush.Surface`, `Isola.Brush.SurfaceHover` | superfici e hover dentro la scheda |
| `Isola.Font.Text`, `Isola.Font.Display`, `Isola.Font.Icons` | Segoe UI Variable Text / Display, Segoe Fluent Icons |
| `Isola.FontSize.Small` / `Body` / `Title` | 11 / 13 / 16 |

Stili pronti (scheda e pagine impostazioni): `Isola.Style.ToggleSwitch` (CheckBox),
`Isola.Style.Segmented` (RadioButton dentro un Border con `Isola.Style.SegmentedHost`),
`Isola.Style.Slider`, `Isola.Style.Button`, `Isola.Style.TextBox`, `Isola.Style.SettingCard` (Border).

## Esempio minimo

```csharp
namespace Isola.Modules.Esempio;

public sealed class EsempioModule : IIslandModule, IRestingFaceProvider
{
    private IIslandHost? _host;
    public string Id => "esempio";
    public string Title => "Esempio";
    public string Glyph => "";
    public int Order => 500;
    public bool EnabledByDefault => false;
    public int RestingPriority => 0;

    public void Start(IIslandHost host) => _host = host;
    public void Stop() => _host = null;
    public FrameworkElement? CreateCard() => new TextBlock { Text = "Ciao dall'isola" };
    public FrameworkElement? CreateSettingsPage() => null;
    public FrameworkElement CreateRestingFace() => new TextBlock { Text = "Esempio" };
}
```

Il modulo completo di riferimento è `Modules/Clock/ClockModule.cs`.

## Estensione dei temi: IIslandBackdrop

Per un tema con una finestra di sfondo separata (il futuro "Vetro"), implementa
`Island/IIslandBackdrop.cs` in una tua cartella: viene trovato per reflection e compare nella lista
*Tema*. In `Attach(site)` ricevi `IIslandBackdropSite` con l'`IslandHwnd`, la forma corrente e l'evento
`ShapeChanged` (limiti visibili in **pixel dello schermo**, raggi, visibilità, scala DPI) sollevato a
ogni frame d'animazione, a ogni spostamento e quando l'isola si nasconde. `SetIslandFill(brush)`
rende il riempimento dell'isola traslucido per lasciar vedere lo sfondo.

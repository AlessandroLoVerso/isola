# Isola

Un'"isola" in alto al centro dello schermo per **Windows 11 e 10**: una pillola che, quando ci lasci sopra il mouse, si apre in una scheda con musica, appunti, file, promemoria, widget e lo stato dei tuoi agenti di Claude Code. A riposo usa ~0% di CPU.

*A Dynamic-Island-style notch for Windows. UI in Italian. Public domain.*

## Cosa fa

| Scheda | Cosa |
|---|---|
| **Musica** | Copertina, titolo, comandi e barra da qualunque app che parla con Windows (Spotify, YouTube nel browser, VLC…). Testi sincronizzati facoltativi (LRCLIB). Con Spotify collegato: cuore, aggiungi a playlist, coda, cerca. |
| **Agenti** | Le sessioni di Claude Code: al lavoro, *ti aspetta*, finito. La pillola si accende quando una sessione ti cerca. |
| **Appunti** | Cronologia di testi, link, immagini e file, con i fissati. Salta quello che copiano i gestori di password. |
| **Mensola** | Trascini file sulla pillola, poi li trascini fuori dove servono. |
| **Controlli** | Muto del microfono in tutte le app (Ctrl+Alt+M, o Ctrl+Maiusc+Alt+M se occupata), timer delle chiamate, volume, luminosità, Wi-Fi, Bluetooth. |
| **Promemoria** | Promemoria con ripetizioni che scendono anche sopra i giochi. |
| **Widget** | Fusi orari, meteo (Open-Meteo), timer di concentrazione, to-do. Sul desktop: l'orologio "Day" con il nome del giorno a lettere giganti. |
| **Prestazioni** | Sopra le app a schermo intero diventa una striscia con CPU, GPU, RAM e rete. |
| **Ora** | Orologio e data. |

Temi: **Nero**, **Grafite**, **Vetro** (sfocatura) e **Liquido** (rifrazione vera con Direct3D; non compare negli screenshot). Forme: isola o notch.

## Installare

Serve l'SDK di **.NET 9** su Windows.

```powershell
git clone https://github.com/AlessandroLoVerso/isola
cd isola
powershell -NoProfile -File tools/publish.ps1     # crea publish\Isola.exe (un file solo, ~175 MB)
```

Copia `publish\Isola.exe` dove vuoi (per esempio `%LocalAppData%\Programs\Isola`) e avvialo. "Avvia con Windows" si accende da Impostazioni › Generale (tasto destro sull'icona vicino all'orologio, oppure l'ingranaggio nella scheda).

Per sviluppare: `dotnet build Isola.sln -c Release`.

## Collegare Claude Code

Impostazioni › Agenti › **Collega Claude Code** aggiunge a `~/.claude/settings.json` (con backup) degli hook che mandano gli eventi a `http://127.0.0.1:47321/agent`. Il server ascolta solo in locale. "Scollega" li toglie.

## Collegare Spotify

1. Su [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) crea un'app con Web API e redirect URI `http://127.0.0.1:47322/callback`.
2. Copia il **Client ID** in Impostazioni › Musica › Spotify e premi **Collega Spotify**. Non serve il client secret (PKCE).
3. Il token resta sul PC, cifrato con DPAPI. "Riproduci" e "Metti in coda" richiedono Spotify Premium.

## Privacy

Niente account, niente telemetria. Vanno in rete solo: i testi (se li accendi), il meteo, Spotify (se lo colleghi). Appunti, file e notifiche restano sul PC. I log non contengono nomi di app, dispositivi o percorsi.

## Com'è fatto

C# · .NET 9 · WPF, API WinRT di Windows, NAudio, Vortice (Direct3D 11 / DirectComposition). Ogni funzione è un modulo indipendente in `src/Isola/Modules/` (vedi [`src/Isola/Core/MODULES.md`](src/Isola/Core/MODULES.md)): se uno si rompe, gli altri continuano. La guida di progetto è in [`guida-isola.html`](guida-isola.html).

Costruita con [Claude Code](https://claude.com/claude-code), con più sottoagenti in parallelo.

## Note

Progetto indipendente, ispirato all'idea della Dynamic Island. Non è affiliato ad Apple, né a NotchPixel o ad altre app simili. "Dynamic Island" è un marchio di Apple Inc.

## Licenza

[Unlicense](LICENSE): pubblico dominio. Fanne quello che vuoi.

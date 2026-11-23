# Appunti condivisi tra PC e Mac (protocollo "ponte" v1)

Copi su un computer, incolli sull'altro. Funziona tra **Isola per Windows** e **Isola Ponte** per macOS (o tra due Windows), attraverso **Tailscale**: niente cloud, niente server in mezzo, il traffico è già cifrato da WireGuard.

Esempi completi di richieste firmate, con una chiave di prova, in [`appunti-condivisi.esempio.json`](appunti-condivisi.esempio.json): servono a controllare byte per byte la firma dall'altra parte.

## Come si collegano

- Ogni computer ascolta su `http://<suo-IP-Tailscale>:47323/` (solo sull'indirizzo 100.x di Tailscale, mai su `0.0.0.0`).
- L'altro computer si indica con il nome MagicDNS di Tailscale (es. `pcale`, `macbook-air-di-alessandro`) o con l'IP 100.x. Chi invia contatta solo indirizzi Tailscale: se il nome si risolve in un indirizzo fuori da Tailscale non si invia niente.
- **Abbinamento:** uno dei due genera una **chiave condivisa**: **20 byte casuali** (160 bit), mostrati come **32 caratteri base32 in 8 gruppi di 4** separati da trattini, es. `K7QH-ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23`. Si scrive la stessa chiave sull'altro. Senza chiave giusta ogni richiesta riceve `401`.
  - Base32 è quello della RFC 4648 (`A`–`Z`, `2`–`7`), senza padding: 20 byte sono esattamente 32 caratteri.
  - Chi legge la chiave scritta a mano ignora maiuscole/minuscole, spazi e trattini; dopo, devono restare esattamente 32 caratteri dell'alfabeto, altrimenti la chiave non è valida.
  - La chiave per l'HMAC sono i 20 byte decodificati (non il testo).
  - Si salva cifrata (Windows: DPAPI dell'utente; macOS: Portachiavi), mai nelle impostazioni in chiaro e mai nei log.
- Si accettano richieste solo da indirizzi Tailscale (`100.64.0.0/10` o `fd7a:115c:a1e0::/48`); le altre ricevono `403`.

## HTTP

- HTTP/1.1, **una richiesta per connessione**: il ricevente risponde con `Connection: close` e chiude.
- Il corpo si manda sempre con `Content-Length` (niente `Transfer-Encoding: chunked`, che riceve `411`). `Expect: 100-continue` è accettato ma non serve.
- Il ricevente gestisce al massimo **2 connessioni insieme** (la terza riceve `503`), chiude una connessione se per **10 s** non arriva niente e comunque dopo 60 s.
- Le dimensioni: 1 MB = 1 MiB = 1 048 576 byte.

## Richiesta

`POST /clip` con corpo JSON (UTF-8, senza BOM), massimo **14 MB** (14 680 064 byte: ci sta un PNG da 10 MB in base64, che diventa circa 13,3 MB, più il resto). Un `Content-Length` oltre il limite riceve `413` subito, senza leggere il corpo.

```json
{
  "v": 1,
  "id": "6f1c0e5e-…",          // UUID dell'elemento, per evitare doppioni ed echi
  "from": "pcale",             // nome del computer che l'ha copiato
  "ts": 1795400000000,         // ms dall'epoca Unix
  "kind": "text" | "image",
  "text": "…",                 // se kind = text (max 1 000 000 caratteri)
  "png": "<base64>"            // se kind = image (PNG, max 10 MB prima del base64)
}
```

Regole dei campi:

- `v`: il numero `1`. Altri valori ⇒ `400`.
- `id`: stringa da 1 a 64 caratteri. Chi invia usa un UUID nuovo per ogni elemento, minuscolo con trattini (`6f1c0e5e-3b2a-4c1d-9e8f-0a1b2c3d4e5f`); chi riceve lo tratta come testo qualsiasi.
- `from`: nome da mostrare del computer che invia (Windows: il nome del PC; macOS: il nome del Mac, es. "MacBook Air di Alessandro"). Chi riceve toglie i caratteri di controllo e lo tronca a 64 caratteri; se manca o è vuoto mostra "altro computer".
- `ts`: numero intero (ms dall'epoca Unix, UTC), **uguale** all'intestazione `X-Isola-Ts`; se è diverso ⇒ `401`.
- `kind`: `"text"` o `"image"`; altri valori ⇒ `400`. C'è **solo** il campo che serve: `text` per `"text"`, `png` per `"image"` (l'altro si omette, non si manda `null`).
- `text`: non vuoto. I caratteri si contano in unità UTF-16 (`String.Length` in .NET, `NSString.length` / `utf16.count` su macOS): oltre 1 000 000 ⇒ `413`. Gli a capo viaggiano come `"\n"`: Windows converte `"\r\n"` → `"\n"` quando invia e `"\n"` → `"\r\n"` quando riceve.
- `png`: base64 standard della RFC 4648 (con `+`, `/` e padding `=`, senza a capo) dei byte di un file PNG. Decodificato oltre 10 MB ⇒ `413`; base64 non valido o byte che non cominciano con la firma PNG (`89 50 4E 47 0D 0A 1A 0A`) ⇒ `400`.
- Isola per Windows scrive il JSON compatto, senza spazi, con le chiavi in quest'ordine e i caratteri non ASCII in UTF-8 (non `\uXXXX`). Chi riceve però accetta qualsiasi JSON valido: la firma si controlla sui **byte ricevuti**, mai su un JSON riscritto.

Intestazioni:

- `X-Isola-Ts`: uguale a `ts`, in cifre decimali (niente segno, spazi o esponenti).
- `X-Isola-Sig`: HMAC-SHA256 in esadecimale minuscolo (64 caratteri) di `ts + "\n" + corpo` con la chiave condivisa (i 20 byte decodificati). In byte: l'ASCII di `X-Isola-Ts` esattamente come è scritto nell'intestazione, poi un byte `0x0A`, poi i byte del corpo così come viaggiano. Chi riceve accetta anche l'esadecimale maiuscolo e confronta in tempo costante. Il ricevente rifiuta (`401`) se manca un'intestazione, se la firma non torna o se `ts` è più lontano di 5 minuti (300 000 ms) dal suo orologio (anti-replay); ricorda gli ultimi 200 `id` e ignora i ripetuti (risponde `204` senza fare niente).

Risposte (corpo vuoto, `Content-Length: 0`):

| Codice | Quando |
|---|---|
| `204` | ok; anche per un `id` già ricevuto (ignorato) |
| `400` | JSON non valido o campi sbagliati; richiesta HTTP malformata o intestazioni oltre 16 KB |
| `401` | firma o chiave sbagliata, intestazioni mancanti, `ts` fuori dai 5 minuti o diverso tra intestazione e JSON, nessuna chiave impostata |
| `403` | origine fuori da Tailscale |
| `404` / `405` | percorso sconosciuto / metodo sbagliato |
| `411` | `POST` senza `Content-Length`, o `chunked` |
| `413` | troppo grande (corpo, testo o PNG) |
| `503` | condivisione in pausa su chi riceve, oppure già 2 connessioni aperte |

Ordine dei controlli: origine → percorso e metodo → `Content-Length` → lettura del corpo → firma e `ts` → JSON → limiti → pausa → `id` ripetuto. Così senza la chiave giusta non si scopre niente del contenuto.

`GET /ping` (firmato allo stesso modo: il corpo è vuoto, quindi si firma `ts + "\n"`; `Content-Length` assente o `0`) → `200 {"v":1,"name":"<nome>","app":"isola-windows|isola-ponte-mac"}` con `Content-Type: application/json; charset=utf-8`: serve alla pagina impostazioni per dire "collegato". La risposta non è firmata. Risponde `200` anche quando la condivisione è in pausa.

## Comportamento

- **Invio:** quando cambia il contenuto degli appunti locali (testo o immagine) e la condivisione è accesa, si invia all'altro computer. Niente file per ora. Si invia ogni nuovo elemento, non solo quelli diversi dal precedente; se mentre un invio è in corso se ne copiano altri, parte solo il più recente.
- **Ricezione:** si mette il contenuto negli appunti locali e lo si segna come "arrivato da fuori", così **non viene rimandato indietro** (niente ping-pong). Isola lo mostra nella cronologia con l'etichetta "dal &lt;from&gt;" (es. "dal MacBook Air di Alessandro", "dall'iMac", "dall'altro computer" se `from` è vuoto) e per un attimo mostra "Appunti · dal …" nell'isola.
- **Privacy:** non si invia mai quello che i gestori di password segnano come riservato.
  - Windows: formati `ExcludeClipboardContentFromMonitorProcessing` o `CanIncludeInClipboardHistory` = 0.
  - macOS: tipi `org.nspasteboard.ConcealedType` o `org.nspasteboard.TransientType` o `org.nspasteboard.AutoGeneratedType`.
  - Il pulsante "Copia" della chiave di abbinamento la mette negli appunti con questi segni, così non finisce né nella cronologia né all'altro computer.
- **Pausa:** un interruttore "Pausa condivisione" su entrambi. In pausa non si invia niente e chi riceve risponde `503` a `POST /clip`.
- Se l'altro computer è spento o irraggiungibile: un solo tentativo con timeout 3 s per trovare il nome e collegarsi (più 1 s per ogni MB del corpo, per le immagini grandi), poi si lascia perdere (niente code, niente ritentativi). La pagina impostazioni lo segnala ("Non raggiungibile", "Chiave sbagliata").
- Il testo oltre 1 000 000 di caratteri e le immagini oltre 10 MB non si inviano.
- **Log:** solo righe come `condivisione: inviato`, `condivisione: ricevuto`, `condivisione: errore <motivo>`; mai contenuto, chiavi, nomi o indirizzi.

## Note per Isola su Windows

- **Ascolto:** l'indirizzo Tailscale è quello IPv4 in `100.64.0.0/10` della scheda di rete il cui nome o descrizione contiene "Tailscale"; si ricontrolla quando cambiano gli indirizzi di rete. Se non c'è, Isola non ascolta e mostra "Tailscale non attivo". Prima prova `HttpListener` su `http://100.x.y.z:47323/`; senza diritti di amministratore Windows lo nega ("accesso negato", manca la URL ACL) e allora usa un piccolo server HTTP/1.1 su `TcpListener` legato solo a quell'indirizzo. Isola non chiede mai di diventare amministratore e non usa `netsh`.
- **Firewall:** la prima volta che Isola si mette in ascolto, Windows può chiedere se permettere a Isola di comunicare sulle reti: serve "Consenti", altrimenti il Mac non riesce a mandare niente al PC (dal PC al Mac funziona lo stesso).
- Con "Pausa cronologia" attiva Isola non legge gli appunti, quindi non invia neanche niente; quello che arriva va comunque negli appunti, ma non nella cronologia.
- I testi tra 200 000 e 1 000 000 di caratteri si inviano ma non restano nella cronologia di Windows (che tiene testi fino a 200 000).

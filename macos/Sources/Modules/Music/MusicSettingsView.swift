import AppKit
import SwiftUI

/// Impostazioni › Musica. Finestra normale: colori di sistema, niente colori dell'isola.
struct MusicSettingsView: View {
    @ObservedObject var model: MusicModel
    @ObservedObject var spotify: SpotifyModel
    let controller: SpotifyController?

    var body: some View {
        Form {
            Section("Sorgente") { sourceRows }
            Section("Opzioni") {
                Toggle("Testi sincronizzati", isOn: Binding(get: { model.lyricsEnabled },
                                                            set: { model.onLyricsToggle($0) }))
                note("Mostra nella scheda la riga del testo che si sta cantando. I testi vengono scaricati da "
                    + "lrclib.net (titolo, artista e durata del brano) e salvati sul Mac per non richiederli di nuovo.")
                Toggle("Avviso al cambio brano", isOn: Binding(get: { model.peekOnChange },
                                                               set: { model.onPeekToggle($0) }))
                note("Quando cambia brano, la pillola mostra per 3 secondi copertina, titolo e artista.")
            }
            Section("Spotify") { spotifyRows }
        }
        .onAppear { controller?.ensureDisplayName() }
    }

    // MARK: - Sorgente

    @ViewBuilder
    private var sourceRows: some View {
        switch model.source {
        case .adapter:
            Label("Tutte le app", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            note("Isola legge cosa suona in qualsiasi app (Spotify, Musica, browser, video) e la comanda "
                + "con i tasti della scheda.")
        case .fallback:
            Label("Solo Spotify e Musica", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            note("Il lettore di sistema non è disponibile, quindi Isola chiede a Spotify e Musica cosa suona, "
                + "ogni 2 secondi e solo mentre sono aperte.")
            if model.needsConsent {
                HStack {
                    Text("Serve il permesso di Automazione.")
                    Spacer()
                    Button("Consenti") { model.onRequestConsent() }
                }
            }
            note("Se l'hai negato: Impostazioni di Sistema › Privacy e sicurezza › Automazione › Isola.")
        case .none:
            Text("Modulo spento").foregroundStyle(.secondary)
        }
    }

    // MARK: - Spotify

    @ViewBuilder
    private var spotifyRows: some View {
        TextField("Client ID", text: Binding(get: { model.clientId }, set: { model.onClientIdChange($0) }))
            .font(.system(.body, design: .monospaced))
            .disabled(spotify.link != .disconnected)
        note("Crea un'app nella Dashboard di developer.spotify.com e incolla qui il suo Client ID.")
        LabeledContent("Redirect URI") {
            HStack(spacing: 8) {
                Text(SpotifyPKCE.redirectURI)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copia") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyPKCE.redirectURI, forType: .string)
                }
            }
        }
        note("Aggiungilo così com'è tra i Redirect URI dell'app Spotify (non \"localhost\").")
        HStack {
            switch spotify.link {
            case .disconnected:
                Text("Non collegato").foregroundStyle(.secondary)
                Spacer()
                Button("Collega Spotify") { controller?.connect(clientId: model.clientId) }
                    .disabled(controller == nil || model.clientId.trimmingCharacters(in: .whitespaces).isEmpty)
            case .connecting:
                Text("Completa l'accesso nel browser (hai 5 minuti).")
                Spacer()
                Button("Annulla") { controller?.cancelConnect() }
            case .connected:
                Text(spotify.displayName.map { "Collegato come \($0)" } ?? "Collegato")
                Spacer()
                Button("Scollega") { controller?.disconnect() }
            }
        }
        if !spotify.linkMessage.isEmpty {
            Text(spotify.linkMessage).font(.caption).foregroundStyle(.red)
        }
        note("Con Spotify collegato, mentre suona Spotify la scheda mostra il cuore e il pulsante \"…\" "
            + "(playlist, coda, cerca). Isola chiama Spotify solo quando cambia brano o quando apri il pannello. "
            + "Il token resta nel Portachiavi di questo Mac. \"Riproduci\" e \"Metti in coda\" richiedono "
            + "Spotify Premium.")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

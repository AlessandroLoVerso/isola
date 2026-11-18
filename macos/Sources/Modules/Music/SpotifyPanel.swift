import IsolaCore
import SwiftUI

/// Il pannello "…" di Spotify dentro la scheda: Playlist, Coda, Cerca.
struct SpotifyPanel: View {
    @ObservedObject var spotify: SpotifyModel
    let controller: SpotifyController
    let focus: () -> Void
    @Environment(\.island) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IslandIconButton("chevron.left", size: 12, help: "Torna al brano") { controller.closePanel() }
                Picker("", selection: Binding(get: { spotify.segment }, set: { controller.select($0) })) {
                    ForEach(SpotifyModel.Segment.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                Spacer(minLength: 8)
                Text(spotify.trackTitle)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            switch spotify.segment {
            case .playlist: playlists
            case .queue: queue
            case .search: search
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Playlist

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelField(placeholder: "Filtra le playlist", text: $spotify.playlistFilter, focus: focus,
                       onChange: { controller.applyFilter() }, onSubmit: {})
            if !spotify.playlistStatus.isEmpty {
                status(spotify.playlistStatus)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(spotify.playlists) { p in
                            PanelRow(action: { controller.addToPlaylist(p) }, help: "Aggiungi il brano a questa playlist") {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.muted)
                                    .frame(width: 20)
                                Text(p.name).font(IslandFont.body).foregroundStyle(theme.foreground).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(p.count == 1 ? "1 brano" : "\(p.count) brani")
                                    .font(IslandFont.small)
                                    .foregroundStyle(theme.muted)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    // MARK: - Coda

    private var queue: some View {
        Group {
            if !spotify.queueStatus.isEmpty {
                status(spotify.queueStatus)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(spotify.queue.enumerated()), id: \.offset) { i, e in
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(IslandFont.mono(11))
                                    .foregroundStyle(theme.muted)
                                    .frame(width: 20)
                                trackText(e.name, e.artist)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    // MARK: - Cerca

    private var search: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelField(placeholder: "Cerca un brano su Spotify", text: $spotify.searchText, focus: focus,
                       onChange: { controller.searchTextChanged() }, onSubmit: { controller.search() })
            if !spotify.searchStatus.isEmpty {
                status(spotify.searchStatus)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(spotify.results) { t in
                            HStack(spacing: 8) {
                                AsyncImage(url: t.imageURL) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(theme.surface)
                                }
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                trackText(t.name, t.artist)
                                Spacer(minLength: 4)
                                IslandIconButton("play.fill", size: 11,
                                                 help: spotify.playBlocked ? SpotifyModel.premiumTip : "Riproduci") {
                                    controller.play(t)
                                }
                                .opacity(spotify.playBlocked ? 0.4 : 1)
                                IslandIconButton("text.badge.plus", size: 11,
                                                 help: spotify.queueBlocked ? SpotifyModel.premiumTip : "Metti in coda") {
                                    controller.enqueue(t)
                                }
                                .opacity(spotify.queueBlocked ? 0.4 : 1)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    // MARK: - Aiuti

    private func trackText(_ name: String, _ artist: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(IslandFont.body).foregroundStyle(theme.foreground).lineLimit(1)
            if !artist.isEmpty {
                Text(artist).font(IslandFont.small).foregroundStyle(theme.muted).lineLimit(1)
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(IslandFont.body)
            .foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Campo di testo dell'isola: al tocco chiede la tastiera all'isola, poi prende il fuoco.
private struct PanelField: View {
    let placeholder: String
    @Binding var text: String
    let focus: () -> Void
    let onChange: () -> Void
    let onSubmit: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(IslandFont.body)
                .foregroundStyle(theme.foreground)
                .focused($focused)
                .onSubmit(onSubmit)
                .onChange(of: text) { onChange() }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            focus()
            DispatchQueue.main.async { focused = true }
        })
    }
}

private struct PanelRow<Content: View>: View {
    let action: () -> Void
    let help: String
    @ViewBuilder let content: () -> Content
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? theme.surfaceHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

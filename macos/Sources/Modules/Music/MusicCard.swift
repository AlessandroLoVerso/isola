import IsolaCore
import SwiftUI

/// La scheda: copertina, titolo, artista, testo, comandi e barra di avanzamento (536 × 196).
struct MusicCard: View {
    @ObservedObject var model: MusicModel
    @ObservedObject var spotify: SpotifyModel
    let controller: SpotifyController?
    @Environment(\.island) private var theme

    var body: some View {
        ZStack(alignment: .bottom) {
            if spotify.panelOpen, spotify.isActive, let controller {
                SpotifyPanel(spotify: spotify, controller: controller, focus: model.onKeyboardFocus)
            } else if model.hasSession {
                player
            } else {
                empty
            }
            if !spotify.message.isEmpty {
                Text(spotify.message)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.background))
                    .background(Capsule().fill(theme.surfaceHover))
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .frame(width: IslandMetrics.card.width, height: IslandMetrics.card.height)
        .animation(.easeOut(duration: 0.18), value: spotify.message)
    }

    // MARK: - Vuota

    private var empty: some View {
        Group {
            if showsLibrary {
                library
            } else {
                emptyPrompt
            }
        }
        .onAppear { controller?.loadShortcuts() }
        .onChange(of: spotify.link) { _, link in
            if link == .connected { controller?.loadShortcuts() }
        }
    }

    /// Spotify collegato e installato: al posto dei due pulsanti, cosa far partire.
    private var showsLibrary: Bool {
        !model.needsConsent && spotify.link == .connected && !spotify.shortcuts.isEmpty
            && MusicLauncher.installed.contains(MusicLauncher.spotify)
    }

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            IslandEmptyState("music.note", title: "Niente in riproduzione",
                             subtitle: model.source == .fallback
                                 ? "Avvia Spotify o Musica."
                                 : "Avvia musica o un video in un'app qualsiasi.")
                .frame(maxHeight: 96)
            if model.needsConsent {
                Text("Isola deve poter leggere Spotify e Musica.")
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                Button("Consenti") { model.onRequestConsent() }
                    .buttonStyle(IslandButtonStyle(prominent: true))
            } else {
                launchButtons
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Cosa ascolti?")
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(theme.foreground)
                Spacer(minLength: 8)
                ForEach(MusicLauncher.installed) { p in
                    Button {
                        model.onLaunch(p)
                    } label: {
                        HStack(spacing: 5) {
                            if model.launching == p.id {
                                ProgressView().controlSize(.mini).tint(theme.foreground)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                            }
                            Text(p.name)
                        }
                        .font(IslandFont.small)
                    }
                    .buttonStyle(IslandButtonStyle(prominent: false))
                    .disabled(model.launching != nil)
                    .help(p == MusicLauncher.spotify ? "Riprendi l'ultimo ascolto su Spotify" : "Riprendi su Musica")
                }
            }
            if !model.launchMessage.isEmpty {
                Text(model.launchMessage)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 4) {
                    ForEach(spotify.shortcuts) { s in
                        ShortcutTile(shortcut: s, busy: model.launching == s.id) { model.onPlayShortcut(s) }
                            .disabled(model.launching != nil)
                    }
                }
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "Suona su Spotify" / "Musica": apre l'app senza portarla davanti e fa partire la musica.
    private var launchButtons: some View {
        let players = MusicLauncher.installed
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(players.enumerated()), id: \.element.id) { i, p in
                    Button {
                        model.onLaunch(p)
                    } label: {
                        HStack(spacing: 6) {
                            if model.launching == p.id {
                                ProgressView().controlSize(.small).tint(theme.foreground)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                            }
                            Text(i == 0 ? "Suona su \(p.name)" : p.name)
                        }
                    }
                    .buttonStyle(IslandButtonStyle(prominent: i == 0))
                    .disabled(model.launching != nil)
                }
            }
            if !model.launchMessage.isEmpty {
                Text(model.launchMessage)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else if spotify.link == .disconnected, players.contains(MusicLauncher.spotify) {
                Text("Collega Spotify nelle impostazioni per scegliere una playlist da qui.")
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
            }
        }
    }

    // MARK: - In riproduzione

    private var accent: Color { model.accent ?? theme.accent }
    private var live: Bool { model.isPlaying && model.cardVisible }

    private var player: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Cover(image: model.artwork, size: 116, radius: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .font(IslandFont.title)
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let icon = model.sourceIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 14, height: 14)
                                .help(model.appName)
                        }
                        Text(model.artist)
                            .font(IslandFont.body)
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    }
                    if model.lyricsEnabled, let lines = model.lyrics {
                        Ticking(live: live, interval: 0.25) { now in
                            LyricsLines(lines: lines, position: model.position(at: now), accent: accent)
                        }
                        .padding(.top, 5)
                    }
                    Spacer(minLength: 0)
                    controls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 116)
            }
            progress
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            IslandIconButton("backward.fill", size: 15, help: "Precedente") { model.onCommand(.previous) }
            IslandIconButton(model.isPlaying ? "pause.fill" : "play.fill", size: 19,
                             help: model.isPlaying ? "Pausa" : "Riproduci") { model.onCommand(.togglePlayPause) }
            IslandIconButton("forward.fill", size: 15, help: "Successiva") { model.onCommand(.next) }
            Spacer(minLength: 0)
            if spotify.isActive, let controller {
                if spotify.canLike {
                    LikeButton(liked: spotify.isLiked, accent: IslandTheme.green) { controller.toggleLike() }
                }
                IslandIconButton("ellipsis", size: 14, help: "Playlist, coda e ricerca") { controller.openPanel() }
            }
        }
        .padding(.leading, -6)
    }

    @ViewBuilder
    private var progress: some View {
        if let duration = model.duration, duration > 0 {
            Ticking(live: live, interval: 0.5) { now in
                ProgressRow(position: model.position(at: now), duration: duration,
                            canSeek: model.canSeek, accent: accent) { model.onSeek($0) }
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(IslandTheme.red).frame(width: 6, height: 6)
                Text("In diretta").font(IslandFont.small).foregroundStyle(theme.muted)
                Spacer()
            }
            .frame(height: 16)
        }
    }
}

/// Ridisegna il contenuto con `TimelineView` solo quando serve (in riproduzione e scheda visibile).
/// Altrimenti nessun aggiornamento periodico.
struct Ticking<Content: View>: View {
    let live: Bool
    let interval: TimeInterval
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if live {
            TimelineView(.periodic(from: .now, by: interval)) { ctx in content(ctx.date) }
        } else {
            content(Date())
        }
    }
}

struct Cover: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    @Environment(\.island) private var theme

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(theme.surface)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(theme.muted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct LikeButton: View {
    let liked: Bool
    let accent: Color
    let action: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(liked ? accent : theme.foreground)
                .frame(width: 29, height: 29)
                .background(Circle().fill(hover ? theme.surfaceHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(liked ? "Togli dai Brani che ti piacciono" : "Aggiungi ai Brani che ti piacciono")
    }
}

private struct LyricsLines: View {
    let lines: [LrcLine]
    let position: Double
    let accent: Color
    @Environment(\.island) private var theme

    var body: some View {
        // Un attimo di anticipo: la riga compare quando la voce comincia, non dopo.
        let i = LyricsService.index(in: lines, at: position + 0.3)
        let current = i >= 0 ? lines[i].text : ""
        let next = lines.indices.contains(i + 1) ? lines[i + 1].text : ""
        VStack(alignment: .leading, spacing: 2) {
            Text(current.isEmpty ? "♪" : current)
                .font(IslandFont.bodyBold)
                .foregroundStyle(current.isEmpty ? theme.muted : accent)
                .lineLimit(1)
            Text(next)
                .font(IslandFont.small)
                .foregroundStyle(theme.muted)
                .lineLimit(1)
        }
        .id(i)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: i)
    }
}

private struct ProgressRow: View {
    let position: Double
    let duration: Double
    let canSeek: Bool
    let accent: Color
    let onSeek: (Double) -> Void
    @Environment(\.island) private var theme
    @State private var scrub: Double?
    @State private var hover = false

    var body: some View {
        let fraction = scrub ?? min(1, max(0, position / duration))
        let shown = fraction * duration
        HStack(spacing: 10) {
            Text(MusicModel.time(shown))
                .frame(width: 42, alignment: .trailing)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceHover)
                    Capsule().fill(accent).frame(width: max(0, w * fraction))
                }
                .frame(height: hover || scrub != nil ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(canSeek ? drag(width: w) : nil)
            }
            .frame(height: 16)
            .onHover { hover = canSeek && $0 }
            Text("-" + MusicModel.time(max(0, duration - shown)))
                .frame(width: 46, alignment: .leading)
        }
        .font(IslandFont.mono(11))
        .foregroundStyle(theme.muted)
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in scrub = min(1, max(0, v.location.x / max(1, width))) }
            .onEnded { v in
                let f = min(1, max(0, v.location.x / max(1, width)))
                scrub = nil
                onSeek(f * duration)
            }
    }
}

/// Una playlist (o i preferiti) nella scheda vuota: un clic e parte su Spotify.
private struct ShortcutTile: View {
    let shortcut: SpotifyShortcut
    let busy: Bool
    let action: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                art
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortcut.name)
                        .font(IslandFont.bodyBold)
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    Text(shortcut.detail)
                        .font(IslandFont.small)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.small).tint(theme.foreground)
                        .frame(width: 14, height: 14)
                } else if hover {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.foreground)
                }
            }
            .padding(5)
            .padding(.trailing, 4)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover ? theme.surfaceHover : theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Suona su Spotify")
    }

    @ViewBuilder private var art: some View {
        if shortcut.liked {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.27, green: 0.16, blue: 0.86), Color(red: 0.62, green: 0.78, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: "heart.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                .frame(width: 34, height: 34)
        } else {
            AsyncImage(url: shortcut.imageURL) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(theme.surfaceHover)
                    .overlay(Image(systemName: "music.note.list").font(.system(size: 12)).foregroundStyle(theme.muted))
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

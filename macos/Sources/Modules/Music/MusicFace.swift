import IsolaCore
import SwiftUI

/// Pillola chiusa, lato sinistro: la copertina piccola.
struct MusicFaceLeading: View {
    @ObservedObject var model: MusicModel

    var body: some View {
        Cover(image: model.artwork, size: 22, radius: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Pillola chiusa, lato destro: l'equalizzatore mentre suona, la pausa altrimenti.
struct MusicFaceTrailing: View {
    @ObservedObject var model: MusicModel
    @Environment(\.island) private var theme

    var body: some View {
        Group {
            if model.isPlaying {
                Equalizer(color: model.accent ?? theme.accent, height: 14)
            } else {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// Quattro barre animate con un'animazione SwiftUI (nessun timer). Esiste solo mentre suona.
struct Equalizer: View {
    let color: Color
    let height: CGFloat
    @State private var up = false

    private static let bars: [(low: CGFloat, high: CGFloat, duration: Double)] = [
        (0.30, 0.95, 0.42), (0.55, 0.75, 0.53), (0.25, 1.00, 0.37), (0.45, 0.80, 0.48),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Self.bars.indices, id: \.self) { i in
                let b = Self.bars[i]
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: height * (up ? b.high : b.low))
                    .animation(.easeInOut(duration: b.duration).repeatForever(autoreverses: true), value: up)
            }
        }
        .frame(height: height)
        .onAppear { up = true }
        .onDisappear { up = false }
    }
}

/// La riga sotto la notch al cambio brano (360 × 40).
struct MusicPeek: View {
    @ObservedObject var model: MusicModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Cover(image: model.artwork, size: 28, radius: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text(model.artist)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.isPlaying {
                Equalizer(color: model.accent ?? theme.accent, height: 14)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: IslandMetrics.peek.width, height: IslandMetrics.peek.height)
    }
}

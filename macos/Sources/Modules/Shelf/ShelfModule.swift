import IsolaCore
import SwiftUI

/// "Mensola": trascina i file sull'isola, aspettano lì (si tiene solo il riferimento, i file non
/// vengono mai copiati né cancellati), poi trascinali fuori in una cartella o in un'app,
/// uno o tanti insieme. In più: AirDrop, Condividi, Anteprima, Mostra nel Finder.
///
/// Mentre si trascinano file sopra la notch il core apre questa scheda; il rilascio lo
/// accetta la scheda stessa (`.onDrop` su tutta l'area).
public final class ShelfModule: IslandModule, RestingFaceProvider {
    public init() {}
    public var id: String { "shelf" }
    public var title: String { "Mensola" }
    public var symbol: String { "tray.full" }
    public var order: Int { 30 }
    public var enabledByDefault: Bool { true }

    private let model = ShelfModel()
    private weak var host: IslandHost?
    private var lastCount = 0

    public func start(host: IslandHost) throws {
        self.host = host
        model.start(host: host)
        lastCount = model.items.count
        model.onCountChanged = { [weak self] in self?.countChanged() }
        host.onCardVisibilityChange { [weak self] visible in self?.model.cardBecameVisible(visible) }
        if lastCount > 0 { host.refreshRestingFace() }
    }

    public func stop() {
        model.onCountChanged = nil
        model.stop()
        lastCount = 0
        host = nil
    }

    public func makeCard() -> AnyView? {
        AnyView(ShelfCard(model: model))
    }

    // MARK: faccia sulla pillola

    /// Bassa: sopra solo all'ora. Il vassoio con il numero di file.
    public var restingPriority: Int { model.items.isEmpty ? 0 : 10 }

    public func makeRestingFace() -> RestingFace {
        RestingFace(leading: ShelfFaceLeading(), trailing: ShelfFaceTrailing(model: model))
    }

    private func countChanged() {
        let n = model.items.count
        let wasEmpty = lastCount == 0
        lastCount = n
        if wasEmpty != (n == 0) { host?.refreshRestingFace() }
    }
}

private struct ShelfFaceLeading: View {
    @Environment(\.island) private var theme
    var body: some View {
        HStack {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
    }
}

private struct ShelfFaceTrailing: View {
    @ObservedObject var model: ShelfModel
    @Environment(\.island) private var theme
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text("\(model.items.count)")
                .font(IslandFont.mono(13, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: model.items.count)
        }
        .padding(.trailing, 6)
    }
}

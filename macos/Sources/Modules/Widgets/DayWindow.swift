import AppKit
import IsolaCore
import SwiftUI

/// L'orologio "Day" sul desktop: una finestra senza bordi sopra lo sfondo e sotto le icone,
/// su tutte le Scrivanie, che non riceve il mouse. Larga quanto lo schermo principale; il testo
/// si allinea a sinistra, al centro o a destra. Si aggiorna solo quando cambia il giorno
/// (il modulo aggiorna `vm.weekday` e `vm.dateLine`).
@MainActor
final class DayDesktopWindow {
    private static let margin: CGFloat = 48

    private let style: DayStyle
    private var window: NSWindow?

    init(vm: WidgetsViewModel, settings: DaySettings) {
        style = DayStyle(day: settings)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                         styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.isExcludedFromWindowsMenu = true
        w.animationBehavior = .none
        let host = NSHostingView(rootView: DayDesktopView(vm: vm, style: style))
        host.sizingOptions = []
        w.contentView = host
        window = w
        reposition()
        w.orderFrontRegardless()
    }

    func apply(_ settings: DaySettings) {
        guard settings != style.day else { return }
        style.day = settings
        reposition()
    }

    /// Schermo principale (quello con la barra dei menu), dopo un cambio di schermi o di grandezza.
    func reposition() {
        guard let window, let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let size = CGFloat(style.day.size)
        let height = ceil(size * 1.25 + max(14, size * 0.2) * 1.4 + 24)
        let y: CGFloat
        switch style.day.vertical {
        case .top: y = area.maxY - Self.margin - height
        case .center: y = area.midY - height / 2
        case .bottom: y = area.minY + Self.margin
        }
        style.margin = Self.margin
        window.setFrame(NSRect(x: screen.frame.minX, y: max(area.minY, y), width: screen.frame.width, height: height),
                        display: true)
    }

    func close() {
        guard let window else { return }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        self.window = nil
    }
}

@MainActor
final class DayStyle: ObservableObject {
    @Published var day: DaySettings
    @Published var margin: CGFloat = 48
    init(day: DaySettings) { self.day = day }
}

private struct DayDesktopView: View {
    @ObservedObject var vm: WidgetsViewModel
    @ObservedObject var style: DayStyle

    var body: some View {
        let size = CGFloat(style.day.size)
        let color = HexColor.color(style.day.color) ?? .white
        let alignment: HorizontalAlignment = switch style.day.horizontal {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
        let frameAlignment: Alignment = switch style.day.horizontal {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
        VStack(alignment: alignment, spacing: size * 0.02) {
            Text(vm.weekday)
                .font(.system(size: size, weight: .semibold))
                .tracking(size * 0.32)
                // Lo spazio dopo l'ultima lettera sbilancerebbe il centro.
                .padding(.trailing, -size * 0.32)
            Text(vm.dateLine.uppercased(with: WText.italian))
                .font(.system(size: max(14, size * 0.2), weight: .medium))
                .tracking(max(2, size * 0.06))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.3)
        .foregroundStyle(color)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .padding(.horizontal, style.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
        .allowsHitTesting(false)
    }
}

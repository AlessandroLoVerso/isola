import AppKit
import IsolaCore
import SwiftUI

/// Il contorno dell'isola. Con `flare` > 0 gli angoli in alto si piegano verso l'esterno
/// come la notch vera del MacBook; con `topRadius` > 0 è una pillola staccata.
struct IslandShape: Shape {
    var bodyWidth: CGFloat
    var bottomRadius: CGFloat
    var flare: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(bodyWidth, bottomRadius), AnimatablePair(flare, topRadius)) }
        set {
            bodyWidth = newValue.first.first
            bottomRadius = newValue.first.second
            flare = newValue.second.first
            topRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let h = rect.height
        let w = min(bodyWidth, rect.width)
        guard w > 0.5, h > 0.5 else { return Path() }
        let f = max(0, min(flare, h / 2, (rect.width - w) / 2))
        let x0 = rect.midX - w / 2, x1 = rect.midX + w / 2
        let y0 = rect.minY, y1 = rect.maxY
        let rt = max(0, min(topRadius, w / 2, h / 2))
        let rb = max(0, min(bottomRadius, w / 2, h - max(rt, f)))

        var p = Path()
        if f > 0.01 {
            p.move(to: CGPoint(x: x0 - f, y: y0))
            p.addLine(to: CGPoint(x: x1 + f, y: y0))
            p.addQuadCurve(to: CGPoint(x: x1, y: y0 + f), control: CGPoint(x: x1, y: y0))
        } else {
            p.move(to: CGPoint(x: x0 + rt, y: y0))
            p.addLine(to: CGPoint(x: x1 - rt, y: y0))
            if rt > 0.01 { p.addQuadCurve(to: CGPoint(x: x1, y: y0 + rt), control: CGPoint(x: x1, y: y0)) }
        }
        p.addLine(to: CGPoint(x: x1, y: y1 - rb))
        if rb > 0.01 {
            p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - rb, y: y1), radius: rb)
        }
        p.addLine(to: CGPoint(x: x0 + rb, y: y1))
        if rb > 0.01 {
            p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - rb), radius: rb)
        }
        if f > 0.01 {
            p.addLine(to: CGPoint(x: x0, y: y0 + f))
            p.addQuadCurve(to: CGPoint(x: x0 - f, y: y0), control: CGPoint(x: x0, y: y0))
        } else {
            p.addLine(to: CGPoint(x: x0, y: y0 + rt))
            if rt > 0.01 { p.addQuadCurve(to: CGPoint(x: x0 + rt, y: y0), control: CGPoint(x: x0, y: y0)) }
        }
        p.closeSubpath()
        return p
    }
}

/// La sfocatura di macOS dietro la finestra.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = material
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Lo sfondo per tema.
struct IslandBackground: View {
    let kind: ThemeKind
    let shape: IslandShape

    var body: some View {
        switch kind {
        case .nero, .grafite:
            shape.fill(kind.colors.background)
        case .vetro:
            ZStack {
                VisualEffect(material: .hudWindow)
                Color.black.opacity(0.22)
            }
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.6))
        case .liquido:
            ZStack {
                VisualEffect(material: .underWindowBackground)
                Color.black.opacity(0.12)
                // Riflessi: una luce che scende dall'alto e un bordo che brilla.
                LinearGradient(colors: [Color.white.opacity(0.16), .clear, Color.white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.white.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.2, y: 0.1), startRadius: 2, endRadius: 220)
            }
            .clipShape(shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.08), Color.white.opacity(0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.1)
            )
            .shadow(color: Color.white.opacity(0.06), radius: 1, y: -1)
        }
    }
}

struct DefaultPeek: View {
    let symbol: String
    let title: String
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            Text(title).font(IslandFont.bodyBold)
        }
        .foregroundStyle(theme.foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// La faccia senza moduli sugli schermi senza notch: l'ora e un puntino.
struct DefaultClockFace: View {
    @Environment(\.island) private var theme
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            HStack {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(IslandFont.mono(12, weight: .semibold))
                Spacer()
                Circle().fill(theme.muted).frame(width: 6, height: 6)
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 14)
        }
    }
}

// MARK: - La vista principale

struct IslandRootView: View {
    @ObservedObject var controller: IslandController

    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.8) }

    var body: some View {
        let s = controller.spec
        let theme = controller.themeKind.colors
        let shape = IslandShape(bodyWidth: s.width, bottomRadius: s.bottomRadius, flare: s.flare, topRadius: s.topRadius)
        let isOpen = controller.mode == .open

        ZStack(alignment: .top) {
            IslandBackground(kind: controller.themeKind, shape: shape)
                .opacity(s.visible ? 1 : 0)
                .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 18, y: 8)

            content(spec: s)
                .frame(width: s.width, height: s.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: s.outerWidth, height: s.height)
        .contentShape(shape)
        .onTapGesture { controller.clickedClosed() }
        .onDrop(of: [.fileURL], isTargeted: $controller.dropHover) { _ in false }
        .padding(.top, s.topOffset)
        .frame(width: IslandController.panelSize.width, height: IslandController.panelSize.height, alignment: .top)
        .environment(\.island, theme)
        .environment(\.colorScheme, .dark)
        .animation(spring, value: s)
    }

    @ViewBuilder
    private func content(spec s: IslandSpec) -> some View {
        let g = controller.geometry
        let band = g.hasNotch ? g.notchHeight : (controller.usesNotchShape ? g.notchHeight : 30)
        switch controller.mode {
        case .closed:
            if let f = controller.activeFace {
                faceRow(f.face, band: band)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .id(f.moduleId)
            } else if !g.hasNotch {
                DefaultClockFace().frame(height: band)
            }
        case .peek:
            VStack(spacing: 0) {
                if let f = controller.activeFace { faceRow(f.face, band: band) } else { Color.clear.frame(height: band) }
                (controller.peekView ?? AnyView(EmptyView()))
                    .frame(width: IslandMetrics.peek.width, height: IslandMetrics.peek.height)
            }
            .transition(.opacity)
        case .open:
            OpenIslandView(controller: controller, band: band)
                .transition(.opacity.combined(with: .offset(y: -6)))
        }
    }

    private func faceRow(_ face: RestingFace, band: CGFloat) -> some View {
        let g = controller.geometry
        return HStack(spacing: 0) {
            face.leading.frame(width: face.sideWidth, height: band)
            Spacer(minLength: g.hasNotch ? g.notchWidth : 8)
            face.trailing.frame(width: face.sideWidth, height: band)
        }
        .padding(.horizontal, 8)
        .frame(height: band)
    }
}

/// La scheda aperta: riga in alto (titolo a sinistra, ingranaggio a destra), schede, contenuto.
struct OpenIslandView: View {
    @ObservedObject var controller: IslandController
    let band: CGFloat
    @Environment(\.island) private var theme

    var body: some View {
        let tabs = controller.manager.tabs
        let selected = tabs.first { $0.moduleId == controller.selectedTab } ?? tabs.first
        let g = controller.geometry

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(selected?.module.title ?? "Isola")
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .padding(.leading, 22)
                Spacer(minLength: g.hasNotch ? g.notchWidth + 16 : 16)
                IslandIconButton("gearshape", size: 12, help: "Impostazioni") {
                    controller.close()
                    AppDelegate.shared?.showSettings()
                }
                .padding(.trailing, 16)
            }
            .frame(height: band)

            scaledBody(tabs: tabs, selected: selected)
        }
    }

    /// Schede e contenuto, disegnati a grandezza piena e poi rimpiccioliti di `openScale`.
    private func scaledBody(tabs: [ModuleRecord], selected: ModuleRecord?) -> some View {
        let k = IslandController.openScale
        let h = IslandController.tabRow + 2 + IslandMetrics.card.height
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs) { r in
                    TabButton(symbol: r.module.symbol, title: r.module.title,
                              selected: r.moduleId == selected?.moduleId) {
                        controller.select(r.moduleId)
                    }
                }
            }
            .frame(height: 34)
            .id(controller.modulesVersion)

            ZStack {
                if let card = selected?.card {
                    card
                        .id(selected?.moduleId)
                        .transition(.opacity)
                }
            }
            .frame(width: IslandMetrics.card.width, height: IslandMetrics.card.height)
            .padding(.top, 2)
        }
        .frame(width: IslandController.openWidth, height: h, alignment: .top)
        .scaleEffect(k, anchor: .top)
        .frame(width: IslandController.openWidth * k, height: h * k, alignment: .top)
    }
}

struct TabButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? theme.foreground : theme.muted)
                .frame(width: 34, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? theme.surfaceHover : (hover ? theme.surface : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(title)
    }
}

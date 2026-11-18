import AppKit
import Combine
import IsolaCore
import SwiftUI

/// La faccia che ha vinto, con l'id del modulo.
struct FaceEntry {
    let moduleId: String
    let face: RestingFace
}

/// La forma dell'isola in un istante: larghezza e altezza del corpo, raggio in basso,
/// curve verso l'esterno in alto (notch) o raggio in alto (isola staccata).
struct IslandSpec: Equatable {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var flare: CGFloat
    var topRadius: CGFloat
    var topOffset: CGFloat
    var visible: Bool

    var outerWidth: CGFloat { width + 2 * flare }
}

/// Il cervello dell'isola: stato (chiusa, peek, aperta), puntatore, timer, schermo.
@MainActor
final class IslandController: ObservableObject {
    enum Mode: Equatable {
        case closed
        case peek(String)
        case open
    }

    @Published private(set) var mode: Mode = .closed
    @Published var selectedTab: String?
    @Published private(set) var face: FaceEntry?
    @Published private(set) var strip: FaceEntry?
    @Published private(set) var peekView: AnyView?
    @Published private(set) var isFullscreen = false
    @Published private(set) var geometry: ScreenGeometry
    @Published private(set) var themeKind: ThemeKind = .nero
    @Published private(set) var shapeKind: IslandShapeKind = .notch
    @Published var dropHover = false {
        didSet { if dropHover, !oldValue { dropEntered() } }
    }
    /// Cambia quando cambia l'elenco dei moduli accesi (per ridisegnare le schede).
    @Published private(set) var modulesVersion = 0

    let manager: ModuleManager
    private let settings = SettingsStore.shared
    private var panel: IslandPanel!
    private let fullscreen = FullscreenWatcher()

    private var monitors: [Any] = []
    private var hovering = false
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var peekTimer: Timer?
    private var previousApp: NSRunningApplication?
    private var settingsObserver: AnyCancellable?

    static let panelSize = CGSize(width: 760, height: 360)
    static let openWidth: CGFloat = 568
    static let tabRow: CGFloat = 34
    /// L'isola aperta è disegnata a 568 punti e poi rimpicciolita: tutto resta in proporzione.
    static let openScale: CGFloat = 0.9
    private static let closeDelay: TimeInterval = 0.35
    private static let lingerDelay: TimeInterval = 4

    init(manager: ModuleManager) {
        self.manager = manager
        let screen = ScreenGeometry.pick(SettingsStore.shared.current.screen) ?? NSScreen.main!
        geometry = ScreenGeometry.forScreen(screen)
        themeKind = settings.current.theme
        shapeKind = settings.current.shape
        selectedTab = settings.current.lastTab
    }

    // MARK: avvio

    func start() {
        panel = IslandPanel(controller: self)
        let root = IslandRootView(controller: self)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hosting
        reposition()
        panel.orderFrontRegardless()
        installMonitors()

        fullscreen.screenProvider = { [weak self] in self?.currentScreen() }
        fullscreen.onChange = { [weak self] on in self?.fullscreenChanged(on) }
        fullscreen.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        settingsObserver = settings.$current.sink { [weak self] s in
            guard let self else { return }
            DispatchQueue.main.async {
                self.themeKind = s.theme
                self.shapeKind = s.shape
                self.reposition()
            }
        }
    }

    private func currentScreen() -> NSScreen? {
        ScreenGeometry.pick(settings.current.screen) ?? NSScreen.main
    }

    func reposition() {
        guard let screen = currentScreen(), let panel else { return }
        let g = ScreenGeometry.forScreen(screen)
        if g != geometry { geometry = g }
        let size = Self.panelSize
        let origin = CGPoint(x: (g.centerX - size.width / 2).rounded(), y: g.screenFrame.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        updateVisibility()
    }

    // MARK: la forma

    var usesNotchShape: Bool { geometry.hasNotch || shapeKind == .notch }

    var spec: IslandSpec {
        let g = geometry
        let notchShape = usesNotchShape
        let top: CGFloat = notchShape ? 0 : 6
        let baseH = g.hasNotch ? g.notchHeight : (notchShape ? g.notchHeight : 30)
        func make(_ w: CGFloat, _ h: CGFloat, _ r: CGFloat, flare: CGFloat, visible: Bool = true) -> IslandSpec {
            IslandSpec(width: w, height: h, bottomRadius: r,
                       flare: notchShape ? flare : 0,
                       topRadius: notchShape ? 0 : min(r, h / 2),
                       topOffset: top, visible: visible)
        }

        switch mode {
        case .open:
            let k = Self.openScale
            return make(Self.openWidth * k, baseH + (Self.tabRow + 2 + IslandMetrics.card.height + 14) * k,
                        26 * k, flare: 12)
        case .peek:
            let w = max(sideWidth(of: activeFace) * 2 + g.notchWidth + 16, IslandMetrics.peek.width + 28)
            return make(w, baseH + IslandMetrics.peek.height + 8, 20, flare: 10)
        case .closed:
            if let f = activeFace {
                let gap = g.hasNotch ? g.notchWidth : 8
                return make(f.face.sideWidth * 2 + gap + 16, baseH, notchShape ? 10 : baseH / 2, flare: 6)
            }
            if g.hasNotch {
                // Solo la notch: invisibile, ma il puntatore la sente.
                return make(g.notchWidth, g.notchHeight, 10, flare: 0, visible: false)
            }
            return make(132, baseH, notchShape ? 10 : baseH / 2, flare: 6)
        }
    }

    /// La faccia da mostrare: la striscia sopra le app a schermo intero, altrimenti quella che ha vinto.
    var activeFace: FaceEntry? {
        if isFullscreen, settings.current.fullscreen == .striscia { return strip }
        return face
    }

    private func sideWidth(of f: FaceEntry?) -> CGFloat { f?.face.sideWidth ?? 0 }

    /// Rettangolo sensibile al puntatore, in coordinate dello schermo.
    var hitRect: CGRect {
        let s = spec
        let w = s.outerWidth
        let maxY = geometry.screenFrame.maxY - s.topOffset
        var r = CGRect(x: geometry.centerX - w / 2, y: maxY - s.height, width: w, height: s.height)
        if mode == .open { r = r.insetBy(dx: -4, dy: -4) }
        if !geometry.hasNotch, mode == .closed { r = r.insetBy(dx: 0, dy: -2) }
        return r
    }

    // MARK: facce

    func modulesChanged() {
        modulesVersion += 1
        if let t = selectedTab, manager.record(t)?.card == nil || manager.record(t)?.running != true {
            selectedTab = manager.tabs.first?.moduleId
        }
        if selectedTab == nil { selectedTab = manager.tabs.first?.moduleId }
        refreshFaces()
    }

    func refreshFaces() {
        let running = manager.running
        let providers = running.compactMap { $0.module as? RestingFaceProvider }
        let winner = providers
            .map { ($0, $0.restingPriority) }
            .filter { $0.1 > 0 }
            .max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.order > b.0.order }?.0
        if winner?.id != face?.moduleId {
            face = winner.map { FaceEntry(moduleId: $0.id, face: $0.makeRestingFace()) }
        }

        let strips = running.compactMap { $0.module as? StripProvider }.filter(\.wantsStrip)
        let stripWinner = strips.min { $0.order < $1.order }
        if stripWinner?.id != strip?.moduleId {
            strip = stripWinner.map { FaceEntry(moduleId: $0.id, face: $0.makeStrip()) }
        }
        updateVisibility()
    }

    // MARK: apertura e chiusura

    func open(tab: String? = nil, byHover: Bool = false) {
        let old = isCardVisibleTab
        if let tab, manager.record(tab)?.card != nil { selectedTab = tab }
        if selectedTab == nil || manager.record(selectedTab!)?.card == nil {
            selectedTab = manager.tabs.first?.moduleId
        }
        guard selectedTab != nil else { return }
        peekTimer?.invalidate()
        let wasOpen = mode == .open
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { mode = .open }
        if !wasOpen, byHover, settings.current.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        manager.notifyCardVisibility(old: old, new: isCardVisibleTab)
        updateVisibility()
        updateMouseIgnoring()
    }

    /// Solo per lo sviluppo (isola://debug/snapshot): disegna la finestra dell'isola in un PNG,
    /// anche a schermo bloccato.
    func snapshotPNG() -> Data? {
        guard let view = panel?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func close() {
        guard mode != .closed else { return }
        let old = isCardVisibleTab
        cancelTimers()
        dropHover = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { mode = .closed }
        peekView = nil
        giveBackKeyboard()
        manager.notifyCardVisibility(old: old, new: nil)
        if let t = selectedTab { settings.update { $0.lastTab = t } }
        updateVisibility()
        updateMouseIgnoring()
    }

    func select(_ tab: String) {
        let old = isCardVisibleTab
        withAnimation(.easeOut(duration: 0.18)) { selectedTab = tab }
        manager.notifyCardVisibility(old: old, new: isCardVisibleTab)
    }

    private var isCardVisibleTab: String? { mode == .open ? selectedTab : nil }
    func isCardVisible(_ id: String) -> Bool { mode == .open && selectedTab == id }

    func openTab(_ id: String) {
        open(tab: id)
        if !hovering { scheduleClose(after: Self.lingerDelay) }
    }

    func toggle() {
        if mode == .open { close() } else { openTab(selectedTab ?? manager.tabs.first?.moduleId ?? "") }
    }

    func attention(_ id: String, duration: TimeInterval) {
        guard mode != .open else { return }
        let d = min(300, max(1, duration))
        if let p = manager.record(id)?.module as? PeekProvider {
            peekView = p.makePeek()
        } else if let r = manager.record(id) {
            peekView = AnyView(DefaultPeek(symbol: r.module.symbol, title: r.module.title))
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { mode = .peek(id) }
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.peekExpired() }
        }
        updateVisibility()
        updateMouseIgnoring()
    }

    private func peekExpired() {
        guard case .peek = mode else { return }
        if hovering {
            // Resta finché lo si guarda.
            peekTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.peekExpired() }
            }
            return
        }
        close()
    }

    private func dropEntered() {
        if let shelf = manager.record("shelf"), shelf.running, shelf.card != nil {
            open(tab: "shelf")
        }
    }

    // MARK: tastiera

    func requestKeyboardFocus() {
        guard mode == .open else { return }
        if !panel.isKeyWindow {
            previousApp = NSWorkspace.shared.frontmostApplication
            panel.allowsKey = true
            panel.makeKey()
        }
    }

    private func giveBackKeyboard() {
        guard panel.allowsKey else { return }
        panel.allowsKey = false
        panel.resignKey()
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        previousApp = nil
    }

    // MARK: schermo intero

    private func fullscreenChanged(_ on: Bool) {
        isFullscreen = on
        manager.notifyFullscreen(on)
        if on, mode == .open { close() }
        updateVisibility()
    }

    /// Nasconde la finestra quando non c'è niente da mostrare sopra un'app a schermo intero.
    private func updateVisibility() {
        guard let panel else { return }
        var show = true
        if isFullscreen {
            switch settings.current.fullscreen {
            case .normale: show = true
            case .nascondi: show = mode != .closed
            case .striscia: show = mode != .closed || strip != nil
            }
        }
        if show, !panel.isVisible { panel.orderFrontRegardless() }
        if !show, panel.isVisible { panel.orderOut(nil) }
    }

    // MARK: puntatore

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return e
        }) { monitors.append(m) }
        // Clic fuori: chiude.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode != .closed else { return }
                if !self.hitRect.contains(NSEvent.mouseLocation) { self.close() }
            }
        }) { monitors.append(m) }
        // Esc: chiude.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 {
                MainActor.assumeIsolated { self?.close() }
                return nil
            }
            return e
        }) { monitors.append(m) }
    }

    private func pointerMoved() {
        let inside = hitRect.contains(NSEvent.mouseLocation)
        updateMouseIgnoring(inside: inside)
        if inside, !hovering {
            hovering = true
            closeTimer?.invalidate()
            if mode != .open, panel.isVisible { scheduleOpen() }
        } else if !inside, hovering {
            hovering = false
            openTimer?.invalidate()
            if mode == .open { scheduleClose(after: Self.closeDelay) }
        } else if inside, mode == .open {
            closeTimer?.invalidate()
        }
    }

    private func updateMouseIgnoring(inside: Bool? = nil) {
        guard let panel else { return }
        let inside = inside ?? hitRect.contains(NSEvent.mouseLocation)
        let ignore = !inside
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    private func scheduleOpen() {
        openTimer?.invalidate()
        let delay = settings.current.openDelayMs / 1000
        openTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hovering else { return }
                let peekTab: String? = { if case .peek(let id) = self.mode { return id } else { return nil } }()
                self.open(tab: peekTab, byHover: true)
            }
        }
    }

    private func scheduleClose(after delay: TimeInterval) {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovering, !self.panel.allowsKey || !self.panel.isKeyWindow else { return }
                self.close()
            }
        }
    }

    private func cancelTimers() {
        openTimer?.invalidate()
        closeTimer?.invalidate()
        peekTimer?.invalidate()
    }

    func clickedClosed() {
        if mode != .open {
            let peekTab: String? = { if case .peek(let id) = mode { return id } else { return nil } }()
            open(tab: peekTab)
        }
    }
}

/// Il pannello: senza bordi, sopra la barra dei menu, in tutti gli spazi, non ruba il fuoco.
final class IslandPanel: NSPanel {
    var allowsKey = false

    init(controller: IslandController) {
        super.init(contentRect: CGRect(origin: .zero, size: IslandController.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

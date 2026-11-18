import AppKit

/// Dove sta l'isola: lo schermo, il centro e le misure della notch (in punti).
struct ScreenGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    /// Larghezza e altezza della notch vera. Senza notch: larghezza 0, altezza della barra dei menu.
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// Centro orizzontale della notch, in coordinate dello schermo.
    var centerX: CGFloat
    var displayName: String

    static func forScreen(_ screen: NSScreen) -> ScreenGeometry {
        let f = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = f.width - left.width - right.width
            return ScreenGeometry(screenFrame: f, hasNotch: true, notchWidth: width, notchHeight: top,
                                  centerX: f.minX + left.width + width / 2,
                                  displayName: screen.localizedName)
        }
        let menuBar = max(24, f.maxY - screen.visibleFrame.maxY)
        return ScreenGeometry(screenFrame: f, hasNotch: false, notchWidth: 0,
                              notchHeight: min(menuBar, 32), centerX: f.midX,
                              displayName: screen.localizedName)
    }

    /// Lo schermo scelto nelle impostazioni.
    static func pick(_ choice: String) -> NSScreen? {
        let screens = NSScreen.screens
        switch choice {
        case "main": return screens.first
        case "auto": return screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first
        default: return screens.first { $0.localizedName == choice } ?? screens.first
        }
    }
}

/// Si accorge quando un'app a schermo intero copre lo schermo dell'isola.
/// Niente timer: ricontrolla solo quando cambiano spazio, app attiva o schermi.
@MainActor
final class FullscreenWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var isFullscreen = false
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    var screenProvider: () -> NSScreen? = { nil }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        schedule()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    /// L'animazione di macOS verso lo spazio a schermo intero dura ~0,7 s: ricontrolla due volte.
    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.check()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { self?.check() } }
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func check() {
        let now = computeFullscreen()
        guard now != isFullscreen else { return }
        isFullscreen = now
        onChange?(now)
    }

    private func computeFullscreen() -> Bool {
        guard let screen = screenProvider(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.apple.finder" else { return false }
        // Coordinate di CGWindowList: origine in alto a sinistra dello schermo principale.
        guard let primary = NSScreen.screens.first else { return false }
        let f = screen.frame
        let cgFrame = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return false }
        let pid = app.processIdentifier
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { continue }
            let r = CGRect(x: x, y: y, width: w, height: h)
            if abs(r.minX - cgFrame.minX) < 1, abs(r.minY - cgFrame.minY) < 1,
               abs(r.width - cgFrame.width) < 1, abs(r.height - cgFrame.height) < 1 {
                return true
            }
        }
        return false
    }
}

import AppKit

/// Avvia la musica da Isola quando non suona niente: apre Spotify (o Musica) senza portarla
/// davanti e le dice di suonare con AppleScript. La prima volta macOS chiede il permesso
/// di Automazione: succede solo perché l'utente ha premuto il pulsante.
@MainActor
final class MusicLauncher {
    struct Player: Identifiable, Equatable {
        let id: String      // bundle id
        let name: String
    }

    static let spotify = Player(id: "com.spotify.client", name: "Spotify")
    static let music = Player(id: "com.apple.Music", name: "Musica")

    /// Le app installate, Spotify per prima.
    static var installed: [Player] {
        [spotify, music].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    private let queue = DispatchQueue(label: "isola.music.launcher", qos: .userInitiated)
    private var generation = 0
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) { self.log = log }

    func cancel() { generation += 1 }

    /// `done(nil)` se suona, altrimenti un messaggio breve per la scheda. Con `uri` (solo Spotify)
    /// parte quella playlist o quei brani: `play track` di AppleScript, non serve Premium.
    func play(_ player: Player, uri: String? = nil, done: @escaping @MainActor (String?) -> Void) {
        generation += 1
        let gen = generation
        if let uri, player != Self.spotify || !SpotifyController.isSafeURI(uri) {
            done("Non riesco a far partire questa playlist.")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.id) else {
            done("\(player.name) non è installata.")
            return
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: player.id).isEmpty
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if error != nil {
                    self.log("musica: avvio dell'app non riuscito")
                    done("Non riesco ad aprire \(player.name).")
                    return
                }
                // Spotify appena aperto ci mette un attimo prima di accettare "play".
                self.tryPlay(player, uri: uri, attempt: 0, delay: wasRunning ? 0 : 1.5, gen: gen, done: done)
            }
        }
    }

    private func tryPlay(_ player: Player, uri: String?, attempt: Int, delay: Double, gen: Int,
                         done: @escaping @MainActor (String?) -> Void) {
        let command = uri.map { "play track \"\($0)\"" } ?? "play"
        let source = """
        tell application id "\(player.id)"
            \(command)
            delay 0.6
            return (player state as string)
        end tell
        """
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let state = result?.stringValue ?? ""
            let code = (err?[NSAppleScript.errorNumber] as? Int) ?? 0
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if code == -1743 {
                    done("Consenti a Isola di comandare \(player.name): Impostazioni › Privacy › Automazione.")
                    return
                }
                if state == "playing" {
                    done(nil)
                } else if attempt < 4 {
                    self.tryPlay(player, uri: uri, attempt: attempt + 1, delay: 1.2, gen: gen, done: done)
                } else {
                    self.log("musica: play non confermato (errore \(code))")
                    done("\(player.name) è aperta: premi play lì.")
                }
            }
        }
    }
}

import AppKit

/// Now Playing di tutte le app con mediaremote-adapter: `/usr/bin/perl` (che macOS lascia
/// parlare con MediaRemote) carica il nostro `MediaRemoteAdapter.framework` e stampa una riga
/// JSON a ogni cambiamento. Nessun polling: il processo dorme finché il sistema non avvisa.
@MainActor
final class AdapterSource {
    struct Paths {
        let script: URL
        let framework: URL
    }

    /// Trova script e framework dentro Isola.app (li mette lì `tools/embed-music.sh`).
    /// Durante `swift build` non ci sono: `nil`, e il modulo usa AppleScript.
    static func locate() -> Paths? {
        let fm = FileManager.default
        guard let fw = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              fm.fileExists(atPath: fw.appendingPathComponent("MediaRemoteAdapter").path),
              let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              fm.fileExists(atPath: "/usr/bin/perl")
        else { return nil }
        return Paths(script: script, framework: fw)
    }

    private let paths: Paths
    private let onUpdate: (NowPlayingInfo?) -> Void
    private let onGiveUp: () -> Void
    private let log: (String) -> Void

    private var process: Process?
    private var startedAt = Date()
    private var generation = 0
    private var restart: DispatchWorkItem?
    private var deaths = 0
    private var fatalExits = 0
    private var running = false

    init(paths: Paths, log: @escaping (String) -> Void,
         onUpdate: @escaping (NowPlayingInfo?) -> Void, onGiveUp: @escaping () -> Void) {
        self.paths = paths
        self.log = log
        self.onUpdate = onUpdate
        self.onGiveUp = onGiveUp
    }

    func start() {
        guard !running else { return }
        running = true
        deaths = 0
        fatalExits = 0
        killOrphans()
        spawn()
    }

    /// Se Isola si è chiusa male, il vecchio `stream` resta vivo (figlio di launchd) finché
    /// non scrive qualcosa. Lo chiudiamo prima di avviarne uno nuovo.
    private func killOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let script = paths.script.path
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, f[1] == "1", f[2].contains(script),
                  let pid = Int32(f[0]) else { continue }
            kill(pid, SIGTERM)
        }
    }

    func stop() {
        running = false
        generation += 1
        restart?.cancel()
        restart = nil
        if let p = process {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            p.terminationHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
    }

    // MARK: - Comandi (processi brevi, non aspettiamo la fine)

    func send(_ command: MediaCommand) {
        runOnce(["send", String(command.adapterId)])
    }

    func seek(to seconds: Double) {
        runOnce(["seek", String(Int64(max(0, seconds) * 1_000_000))])
    }

    private func runOnce(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script.path, paths.framework.path] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("Musica: comando non riuscito") }
    }

    // MARK: - Il processo che resta acceso

    private func spawn() {
        guard running else { return }
        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script.path, paths.framework.path, "stream", "--micros", "--debounce=100"]
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe

        let parser = StreamParser { [weak self] info in
            onMain {
                guard let self, self.generation == gen else { return }
                self.onUpdate(info)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            parser.feed(chunk)
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let byExit = proc.terminationReason == .exit
            onMain {
                guard let self, self.generation == gen else { return }
                self.died(status: status, byExit: byExit)
            }
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            log("Musica: adattatore non avviabile")
            giveUp()
        }
    }

    private func died(status: Int32, byExit: Bool) {
        process = nil
        guard running else { return }
        // Niente musica per un po' = processo sano: il conto dei guasti riparte.
        if Date().timeIntervalSince(startedAt) > 60 { deaths = 0; fatalExits = 0 }
        deaths += 1
        if byExit && status != 0 { fatalExits += 1 }
        onUpdate(nil)
        // Il README dell'adattatore: un'uscita con errore è un guasto vero (framework non caricato,
        // MediaRemote negato). Dopo tre di fila passiamo ad AppleScript.
        if fatalExits >= 3 {
            log("Musica: adattatore fermo (codice \(status)), passo ad AppleScript")
            giveUp()
            return
        }
        let delay = min(60, pow(2, Double(deaths - 1)))
        log("Musica: adattatore uscito (codice \(status)), riprovo tra \(Int(delay)) s")
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.spawn() }
        }
        restart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func giveUp() {
        stop()
        onGiveUp()
    }
}

/// Divide l'uscita in righe e tiene lo stato completo (lo stream manda differenze).
/// Lavora sul thread del `readabilityHandler`, che FileHandle chiama in serie.
private final class StreamParser: @unchecked Sendable {
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var artworkString: String?
    private var artworkImage: NSImage?
    private var artworkAccent: NSColor?
    private var artworkToken = 0
    private let deliver: (NowPlayingInfo?) -> Void

    init(deliver: @escaping (NowPlayingInfo?) -> Void) {
        self.deliver = deliver
    }

    func feed(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { handle(line) }
        }
        // Una riga senza fine oltre 16 MB è spazzatura.
        if buffer.count > 16 << 20 { buffer.removeAll() }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "data",
              let payload = obj["payload"] as? [String: Any] else { return }
        if obj["diff"] as? Bool == true {
            for (k, v) in payload {
                if v is NSNull { state.removeValue(forKey: k) } else { state[k] = v }
            }
        } else {
            state = payload
        }
        deliver(snapshot())
    }

    private func snapshot() -> NowPlayingInfo? {
        guard let title = state["title"] as? String, !title.isEmpty else { return nil }
        var info = NowPlayingInfo()
        info.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        info.artist = (state["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        info.album = (state["album"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = state["parentApplicationBundleIdentifier"] as? String
        info.bundleId = (parent?.isEmpty == false ? parent : nil) ?? state["bundleIdentifier"] as? String
        info.playing = (state["playing"] as? Bool) ?? false
        if let d = number(state["durationMicros"]), d > 0 { info.duration = d / 1_000_000 }
        if let e = number(state["elapsedTimeMicros"]) { info.elapsed = e / 1_000_000 }
        if let t = number(state["timestampEpochMicros"]) { info.timestamp = Date(timeIntervalSince1970: t / 1_000_000) }
        if let r = number(state["playbackRate"]), r > 0 { info.rate = r }

        let art = state["artworkData"] as? String
        if art != artworkString {
            artworkString = art
            artworkToken += 1
            if let art, let data = Data(base64Encoded: art, options: .ignoreUnknownCharacters),
               let img = NSImage(data: data) {
                artworkImage = img
                artworkAccent = CoverArt.accent(of: img)
            } else {
                artworkImage = nil
                artworkAccent = nil
            }
        }
        info.artwork = artworkImage
        info.artworkAccent = artworkAccent
        info.artworkToken = artworkToken
        return info
    }

    private func number(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue
    }
}

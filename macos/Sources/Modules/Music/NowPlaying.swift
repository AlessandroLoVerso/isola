import AppKit

/// Cosa sta suonando, visto da una sorgente (adattatore MediaRemote o AppleScript).
/// Passa dal thread della sorgente al main thread: `NSImage` è immutabile una volta creata.
struct NowPlayingInfo: @unchecked Sendable {
    var title = ""
    var artist = ""
    var album = ""
    /// L'app che suona (per i browser l'app "madre", non il processo WebKit).
    var bundleId: String?
    var playing = false
    /// Secondi; `nil` o 0 = diretta / sconosciuta.
    var duration: Double?
    /// Posizione (secondi) al momento `timestamp`.
    var elapsed: Double?
    var timestamp: Date?
    var rate: Double = 1
    var canSeek = true
    var artwork: NSImage?
    /// Cambia quando cambia la copertina (per non ricalcolare il colore a ogni aggiornamento).
    var artworkToken = 0
    /// Colore medio della copertina, calcolato fuori dal main thread.
    var artworkAccent: NSColor?

    var trackKey: String { title + "\n" + artist + "\n" + album }
}

enum MediaCommand {
    case togglePlayPause, next, previous

    /// Gli id di `send` di mediaremote-adapter (kMRTogglePlayPause, kMRNextTrack, kMRPreviousTrack).
    var adapterId: Int {
        switch self {
        case .togglePlayPause: 2
        case .next: 4
        case .previous: 5
        }
    }
}

/// Esegue sul main actor dal thread di un callback di sistema.
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

enum CoverArt {
    /// Colore "dominante" della copertina: media dei pixel più saturi di una miniatura 12×12,
    /// schiarito se troppo scuro (deve leggersi sul nero dell'isola).
    static func accent(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        var samples: [(r: Double, g: Double, b: Double, s: Double)] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let s = mx > 0 ? (mx - mn) / mx : 0
            samples.append((r, g, b, s * (0.3 + mx)))
        }
        samples.sort { $0.s > $1.s }
        let top = samples.prefix(max(1, samples.count / 4))
        var r = 0.0, g = 0.0, b = 0.0
        for p in top { r += p.r; g += p.g; b += p.b }
        let n = Double(top.count)
        let color = NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        if s < 0.18 { return nil } // copertina grigia: meglio l'accento del tema
        return NSColor(hue: h, saturation: min(s, 0.85), brightness: max(v, 0.78), alpha: 1)
    }
}

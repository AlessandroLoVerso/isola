// Disegna l'icona di Isola (la pillola nera con il puntino blu) e crea Resources/AppIcon.icns.
// Uso: swift tools/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let s = size / 1024
        // Quadrato arrotondato di macOS, con un po' di margine.
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSGradient(colors: [NSColor(white: 0.96, alpha: 1), NSColor(white: 0.84, alpha: 1)])!
            .draw(in: tilePath, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // La pillola.
        let pill = NSRect(x: 190 * s, y: 380 * s, width: 644 * s, height: 264 * s)
        let pillPath = NSBezierPath(roundedRect: pill, xRadius: 132 * s, yRadius: 132 * s)
        NSColor(white: 0.04, alpha: 1).setFill()
        pillPath.fill()
        // Riflesso in alto.
        NSGraphicsContext.saveGraphicsState()
        pillPath.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), .clear])!
            .draw(in: NSRect(x: pill.minX, y: pill.midY, width: pill.width, height: pill.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Il puntino blu.
        let dot = NSRect(x: 606 * s, y: 440 * s, width: 144 * s, height: 144 * s)
        NSGradient(colors: [NSColor(red: 0.25, green: 0.62, blue: 1, alpha: 1),
                            NSColor(red: 0.02, green: 0.45, blue: 0.98, alpha: 1)])!
            .draw(in: NSBezierPath(ovalIn: dot), angle: -90)
        return true
    }
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let img = render(px)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Creata \(out.path)" : "iconutil non riuscito")

import AppKit

/// The app icon, drawn in code: a rounded square with a gradient and the "doc.on.clipboard" symbol.
enum AppIcon {
    static func writeIconset(to dir: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = size * scale
                guard let png = render(px) else { return false }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                do { try png.write(to: dir.appendingPathComponent(name)) } catch { return false }
            }
        }
        return true
    }

    private static func render(_ px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(px)
        // macOS icon grid: the shape fills ~80% of the canvas.
        let inset = s * 0.1
        let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.80, alpha: 1),
                   ending: NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.85, alpha: 1))?.draw(in: path, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let sz = symbol.size
            let r = NSRect(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2, width: sz.width, height: sz.height)
            symbol.draw(in: r)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

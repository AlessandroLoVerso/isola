import AppKit

// `IsolaPonte --disegna-icona <cartella.iconset>`: used by build-app.sh to draw the app icon.
let args = CommandLine.arguments
if args.count == 3, args[1] == "--disegna-icona" {
    exit(AppIcon.writeIconset(to: URL(fileURLWithPath: args[2])) ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

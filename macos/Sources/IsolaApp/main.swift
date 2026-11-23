import AppKit

// Una sola Isola alla volta.
let bundleId = Bundle.main.bundleIdentifier ?? "com.alessandroloverso.isola"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
    .filter { $0 != NSRunningApplication.current }
if !others.isEmpty, Bundle.main.bundleIdentifier != nil {
    exit(0)
}

// pkill, logout, `kill`: chiudi in ordine, così i moduli fermano i processi figli.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

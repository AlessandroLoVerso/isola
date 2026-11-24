// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IsolaPonte",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "IsolaPonte", targets: ["IsolaPonte"]),
    ],
    targets: [
        // Protocol "ponte" v1 (docs/appunti-condivisi.md): key, signature, JSON, HTTP server, client.
        // No AppKit here, so it can be tested on its own.
        .target(name: "PonteCore"),
        // The menu bar app: settings, Keychain, pasteboard.
        .executableTarget(name: "IsolaPonte", dependencies: ["PonteCore"]),
        .testTarget(name: "PonteCoreTests", dependencies: ["PonteCore"]),
    ]
)

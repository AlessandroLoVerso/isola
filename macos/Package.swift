// swift-tools-version:5.10
// Isola per macOS. Ogni modulo è un target a sé: si compila da solo con
//   swift build --target IsolaMusic --build-path .build/music
// così più persone (o agenti) lavorano in parallelo senza pestarsi i piedi.
import PackageDescription

let moduleNames = [
    "Music", "Agents", "Clipboard", "Shelf", "Controls", "Bluetooth",
    "Reminders", "Widgets", "Clock", "Perf", "Battery", "Calendar",
]

let moduleTargets: [Target] = moduleNames.map { name in
    .target(
        name: "Isola\(name)",
        dependencies: ["IsolaCore"],
        path: "Sources/Modules/\(name)"
    )
}

let package = Package(
    name: "Isola",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Isola", targets: ["IsolaApp"]),
    ],
    targets: [
        .target(name: "IsolaCore", path: "Sources/IsolaCore"),
        .executableTarget(
            name: "IsolaApp",
            dependencies: ["IsolaCore"] + moduleNames.map { .target(name: "Isola\($0)") },
            path: "Sources/IsolaApp"
        ),
    ] + moduleTargets
)

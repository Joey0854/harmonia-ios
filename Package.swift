// swift-tools-version:5.7
import PackageDescription

/* The signal-processing code of the app (App/Sound) as a package of its own, so that it can be
   tested with `swift test` on a Mac without building the app. The app itself is built from
   project.yml and compiles the same files directly. */
let package = Package(
    name: "SoundCore",
    platforms: [.macOS(.v12), .iOS(.v16)],
    products: [
        .library(name: "SoundCore", targets: ["SoundCore"])
    ],
    targets: [
        .target(name: "SoundCore", path: "App/Sound"),
        /* The ambient-light protocol without any Bluetooth in it (the other files in App/Light
           need CoreBluetooth and UIKit and belong to the app only). */
        .target(name: "LightCore", path: "App/Light", sources: ["LightProtocol.swift", "LightMusicCore.swift", "LightPalette.swift", "LightWizardCore.swift"]),
        .testTarget(
            name: "SoundCoreTests",
            dependencies: ["SoundCore", "LightCore"],
            path: "Tests",
            exclude: ["tools"],
            sources: ["SoundCoreTests"],
            resources: [.copy("Fixtures")]
        )
    ]
)

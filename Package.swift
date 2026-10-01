// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ravil",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Ravil", targets: ["Ravil"])],
    targets: [
        .executableTarget(
            name: "Ravil",
            path: "apps/macos/Ravil",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)

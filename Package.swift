// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacShanti",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacShanti", targets: ["MacShanti"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "MacShanti",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MacShanti",
            // Info.plist is consumed by the linker (-sectcreate below) and by
            // Scripts/make_app.sh, not as an SwiftPM resource bundle entry.
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so the process is treated as a
                // menubar-only (LSUIElement) app with a stable bundle identifier,
                // which UNUserNotificationCenter requires. When packaged into a
                // proper .app bundle (see Scripts/make_app.sh) this is redundant
                // but harmless.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MacShanti/Resources/Info.plist"
                ])
            ]
        )
    ]
)

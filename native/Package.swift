// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LyricBox",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LyricBox",
            path: "Sources/LyricBox",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

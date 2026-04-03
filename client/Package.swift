// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PetTypeless",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PetTypeless",
            path: "Sources",
            exclude: ["PetTypeless.entitlements", "Info.plist", "AppIcon.icns"]
        )
    ]
)

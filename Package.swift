// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShotPark",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ShotPark",
            path: "Sources/ShotPark",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)

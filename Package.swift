// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CPU",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CPUApp", targets: ["CPUApp"]),
        .executable(name: "cpuctl", targets: ["cpuctl"])
    ],
    targets: [
        .target(
            name: "CPUCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("WebKit"),
                .linkedFramework("PDFKit"),
                .linkedLibrary("z")
            ]
        ),
        .executableTarget(
            name: "CPUApp",
            dependencies: ["CPUCore"]
        ),
        .executableTarget(
            name: "cpuctl",
            dependencies: ["CPUCore"]
        ),
        .testTarget(
            name: "CPUCoreTests",
            dependencies: ["CPUCore"]
        )
    ]
)

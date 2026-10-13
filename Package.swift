// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Tether", targets: ["Tether"]),
        // The OpenXR runtime editors load (Unity Play mode, Unreal VR Preview).
        .library(name: "TetherOpenXR", type: .dynamic, targets: ["TetherOpenXR"]),
    ],
    targets: [
        // libxrsp (MIT, Evan Lambert) plus the native Quest Link host.
        .target(
            name: "CXRSP",
            path: "Sources/CXRSP",
            exclude: ["LICENSE-libxrsp"],
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include/libusb-1.0", "-std=c11"]),
            ],
            linkerSettings: [
                // Static libusb so the app doesn't depend on Homebrew at runtime.
                .unsafeFlags(["/opt/homebrew/lib/libusb-1.0.a"]),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        // Khronos OpenXR headers with the Metal binding enabled.
        .target(name: "COpenXR", path: "Sources/COpenXR", exclude: ["LICENSE-OpenXR-SDK"]),
        // Shared by the app and the runtime: per-slice H.264 encoding for the headset.
        .target(
            name: "TetherCore",
            dependencies: ["CXRSP"],
            path: "Sources/TetherCore",
            linkerSettings: [.linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia")]
        ),
        .target(
            name: "TetherOpenXR",
            dependencies: ["COpenXR", "CXRSP", "TetherCore"],
            path: "Sources/TetherOpenXR",
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("CoreVideo")]
        ),
        .executableTarget(
            name: "Tether",
            dependencies: ["CXRSP", "TetherCore"],
            path: "Sources/Tether",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Metal"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)

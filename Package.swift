// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrigonSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "OrigonSDK", targets: ["OrigonSDK"]),
    ],
    targets: [
        .binaryTarget(
            name: "COrigonSDK",
            url: "https://github.com/Origon/apple-sdk/releases/download/v0.4.2/COrigonSDK.xcframework.zip",
            checksum: "cea12675e2bb767ab8e272eca87486b20e6074d69c43a5ec448bc9850e143b99"
        ),
        .target(
            name: "OrigonSDK",
            dependencies: ["COrigonSDK"],
            path: "Sources/OrigonSDK",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Network"),
                .linkedFramework("AVFAudio", .when(platforms: [.iOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.macOS])),
                .linkedFramework("CoreVideo", .when(platforms: [.macOS])),
                .linkedFramework("VideoToolbox", .when(platforms: [.macOS])),
                .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "OrigonSDKTests",
            dependencies: ["OrigonSDK"],
            path: "Tests/OrigonSDKTests"
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SiliconPlayer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SiliconPlayer", targets: ["SiliconPlayer"]),
               .executable(name: "web-extractor", targets: ["WebExtractor"])],
    targets: [
        .target(name: "PlayerCore"),
        .target(name: "SystemPiPBridge", path: "Sources/SystemPiPBridge",
                publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("AppKit")]),
        .target(name: "RemoteTransferBridge", path: "Sources/RemoteTransferBridge",
                publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedLibrary("curl"), .linkedFramework("Foundation")]),
        .target(name: "MetalRenderBridge", path: "Sources/MetalRenderBridge",
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("pinned-mpv/include"), .unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("QuartzCore")]),
        .systemLibrary(name: "CMPV", path: "Sources/CMPV"),
        .executableTarget(name: "WebExtractor", path: "Sources/WebExtractor"),
        .executableTarget(
            name: "SiliconPlayer",
            dependencies: ["PlayerCore", "CMPV", "SystemPiPBridge", "RemoteTransferBridge", "MetalRenderBridge"],
            linkerSettings: [
                .unsafeFlags(["-L", "Vendor/lib", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("OpenGL"), .linkedFramework("Security")
            ]
        ),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"])
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HDTVMate",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CMPV", path: "Sources/CMPV"),
        .executableTarget(
            name: "HDTVMate",
            dependencies: ["CMPV"],
            path: "Sources/HDTVMate",
            linkerSettings: [.linkedFramework("OpenGL"), .linkedFramework("Cocoa")]
        ),
    ]
)

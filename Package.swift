// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XpectorKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v15)
    ],
    products: [
        .library(name: "XpectorKit", targets: ["XpectorKit"]),
        .library(name: "XpectorServer", targets: ["XpectorServer"]),
    ],
    targets: [
        .target(
            name: "Peertalk",
            path: "Sources/Peertalk",
            publicHeadersPath: "include",
            cSettings: [
                .define("SHOULD_COMPILE_LOOKIN_SERVER", to: "1")
            ]
        ),
        .target(
            name: "XpectorKit",
            dependencies: ["Peertalk"],
            path: "Sources/XpectorKit"
        ),
        // Load-time constructor that auto-starts the inspection server in
        // DEBUG builds (zero-code integration). ObjC because Swift has no
        // __attribute__((constructor)) equivalent.
        .target(
            name: "XpectorAutoStart",
            path: "Sources/XpectorAutoStart",
            publicHeadersPath: "include"
        ),
        .target(
            name: "XpectorServer",
            dependencies: ["XpectorKit", "XpectorAutoStart"],
            path: "Sources/XpectorServer"
        ),
        .testTarget(
            name: "XpectorKitTests",
            dependencies: ["XpectorKit"],
            path: "Tests/XpectorKitTests"
        ),
    ]
)

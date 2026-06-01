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
        .target(
            name: "XpectorServer",
            dependencies: ["XpectorKit"],
            path: "Sources/XpectorServer"
        ),
    ]
)

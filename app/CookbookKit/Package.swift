// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CookbookKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "CookbookKit",
            targets: ["CookbookKit"]
        ),
        .library(
            name: "CookbookUI",
            targets: ["CookbookUI"]
        ),
    ],
    targets: [
        .target(
            name: "CookbookKit",
            path: "Sources/CookbookKit"
        ),
        .target(
            name: "CookbookUI",
            dependencies: ["CookbookKit"],
            path: "Sources/CookbookUI"
        ),
        .testTarget(
            name: "CookbookKitTests",
            dependencies: ["CookbookKit"],
            path: "Tests/CookbookKitTests"
        ),
    ]
)

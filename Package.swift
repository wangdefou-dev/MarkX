// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MarkX",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "XArticleArchiverCore", targets: ["XArticleArchiverCore"]),
        .executable(name: "XArticleArchiverApp", targets: ["XArticleArchiverApp"])
    ],
    targets: [
        .target(
            name: "XArticleArchiverCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "XArticleArchiverApp",
            dependencies: ["XArticleArchiverCore"]
        ),
        .testTarget(
            name: "XArticleArchiverCoreTests",
            dependencies: ["XArticleArchiverCore"]
        ),
        .testTarget(
            name: "XArticleArchiverAppTests",
            dependencies: ["XArticleArchiverApp", "XArticleArchiverCore"]
        )
    ]
)

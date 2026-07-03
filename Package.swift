// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MatchPointGPT",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MatchPointGPT", targets: ["MatchPointGPT"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.1")
    ],
    targets: [
        .executableTarget(
            name: "MatchPointGPT",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio")
            ]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaporOpenAI",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "VaporOpenAI", targets: ["VaporOpenAI"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.115.0"),
        .package(url: "https://github.com/georgetchelidze/AsyncSemaphore.git", branch: "main"),
        .package(url: "https://github.com/georgetchelidze/JSONValue.git", branch: "main")
    ],
    targets: [
        .target(
            name: "VaporOpenAI",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AsyncSemaphore", package: "AsyncSemaphore"),
                .product(name: "JSONValue", package: "JSONValue")
            ],
            path: "Sources/VaporOpenAI",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "VaporOpenAITests",
            dependencies: ["VaporOpenAI"],
            path: "Tests/VaporOpenAITests"
        )
    ]
)

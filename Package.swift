// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nodaystypst",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Nodaystypst", targets: ["Nodaystypst"])
    ],
    targets: [
        .executableTarget(
            name: "Nodaystypst",
            path: "Sources/Nodaystypst",
            resources: [.process("../../Resources")]
        ),
        .testTarget(
            name: "NodaystypstTests",
            dependencies: ["Nodaystypst"],
            path: "Tests/NodaystypstTests"
        )
    ]
)

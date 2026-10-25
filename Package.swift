// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Talkie",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Talkie", targets: ["Talkie"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(
            name: "Talkie",
            dependencies: ["CSQLite", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "TalkieTests", dependencies: ["Talkie"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)

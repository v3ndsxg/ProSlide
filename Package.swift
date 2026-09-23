// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileConverter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FileConverter", targets: ["FileConverter"])
    ],
    targets: [
        .executableTarget(name: "FileConverter")
    ]
)

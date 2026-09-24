// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileConverter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FileConverterCore", targets: ["FileConverterCore"]),
        .executable(name: "FileConverter", targets: ["FileConverter"])
    ],
    targets: [
        .target(name: "FileConverterCore"),
        .executableTarget(
            name: "FileConverter",
            dependencies: ["FileConverterCore"]
        ),
        .testTarget(
            name: "FileConverterTests",
            dependencies: ["FileConverterCore"],
            exclude: ["Fixtures"]
        )
    ]
)
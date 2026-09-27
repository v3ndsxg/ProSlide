// swift-tools-version: 5.9
import PackageDescription

// The macOS app lives in App/ProSlide.xcodeproj and depends on the
// FileConverterCore library below. This package owns the conversion engine and
// its tests, so `swift test` covers rendering without needing Xcode.
let package = Package(
    name: "ProSlideCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FileConverterCore", targets: ["FileConverterCore"])
    ],
    targets: [
        .target(name: "FileConverterCore"),
        .testTarget(
            name: "FileConverterTests",
            dependencies: ["FileConverterCore"],
            exclude: ["Fixtures"]
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

// This package owns the conversion engine, its tests, and the app's sources,
// so `swift build`, `swift test` and Scripts/make-app-bundle.sh all work
// without opening Xcode. App/ProSlide.xcodeproj still exists for development
// (breakpoints, previews); the packaging script does not depend on it.
//
// Sources under App/ProSlide are listed here as well as in the pbxproj. When
// you add a file to the app, add it to the ProSlideApp target below too, or it
// will compile in Xcode and be missing from the packaged app.
let package = Package(
    name: "ProSlideCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FileConverterCore", targets: ["FileConverterCore"]),
        .executable(name: "ProSlide", targets: ["ProSlideApp"])
    ],
    targets: [
        .target(name: "FileConverterCore"),
        // ProSlideApp.swift holds the @main entry point, so this is a real
        // executable rather than a library that Xcode links into an app target.
        // Assets.xcassets is excluded: the packaging script builds the .icns
        // from the appiconset PNG and the system accent is used instead.
        .executableTarget(
            name: "ProSlideApp",
            dependencies: ["FileConverterCore"],
            path: "App/ProSlide",
            exclude: ["Assets.xcassets"]
        ),
        .testTarget(
            name: "FileConverterTests",
            dependencies: ["FileConverterCore"],
            exclude: ["Fixtures"]
        )
    ]
)

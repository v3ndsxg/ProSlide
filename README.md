# ProSlide
A MacOS utility that can convert PowerPoint/PDF files to JPEGs. This can then be imported into ProPresenter without destroying slide contents.

## Requirements
- macOS 13 or later
- Xcode 15 or later (for development)
- LibreOffice installed in `/Applications` for `.pptx` conversion. PDF conversion works without it.

## Layout
- `App/ProSlide.xcodeproj` — the macOS app. Open this in Xcode.
- `App/ProSlide/` — the SwiftUI app target (`ProSlideApp.swift`, `ContentView.swift`, `ConversionJob.swift`) and its asset catalog.
- `Sources/FileConverterCore/` — the conversion engine, a Swift package library.
- `Tests/FileConverterTests/` — engine tests. The app target has no tests; the engine is what has logic worth asserting.

The app links the engine as a local Swift package, so there is one copy of the rendering code and no duplicate `@main`.

## Run
Open `App/ProSlide.xcodeproj` and press Run (⌘R). ⌘B writes `ProSlide.app` into DerivedData, which you can double-click in Finder or copy to `/Applications`.

To build the same app without opening Xcode:
```
./Scripts/make-app-bundle.sh          # writes build/ProSlide.app (Debug or Release)
open build/ProSlide.app
```

The package itself no longer produces an executable: `swift build` and `swift test` build and test the engine library only, which is all the test suite and CI need.

## Tests
`swift test` runs the conversion pipeline against 16:9 sample PDF/PPTX fixtures at every resolution preset (HD 1280x720, Full HD 1920x1080, 4K 3840x2160), asserting output size and that the render stays upright. The PPTX path is skipped when LibreOffice is not installed. CI runs this suite on a macOS runner on every push.

## Conversion behavior
- PDF: PDFKit/Core Graphics renders each page directly to JPEG.
- PPTX: the app runs LibreOffice headlessly to make a temporary PDF, then renders that PDF to JPEG.
- Every job creates a new `Document Name JPEGs` folder in the persistent bin (`~/Library/Application Support/FileConverter/Bin`), never overwriting an earlier conversion. The bin panel's **Save…** copies a set anywhere you like.

LibreOffice fidelity depends on installed fonts and PowerPoint-specific effects. For the closest possible Microsoft Office rendering, a future version can add PowerPoint automation as an optional renderer.

## Security considerations
- ProSlide opens untrusted PDFs and PowerPoint files with Apple's PDFKit and LibreOffice. As with any document viewer, a malicious file could attempt to exploit a parser bug and run code on your machine, so keep LibreOffice and macOS updated. The app makes no network connections and stores no credentials.
- As a guard against crafted documents with extreme page dimensions or page counts, rendering clamps every output image to at most 8192 px per side and a document to at most 300 pages.

## Rust extension point
The UI and Apple PDF APIs deliberately remain Swift-native. A Rust core is useful for future cross-platform batch queues, naming/collision policy, and image-processing work, but it should not replace PDFKit or LibreOffice (The two components doing document rendering). This MVP keeps the app dependency-free and lightweight while leaving that core as a clean future module.

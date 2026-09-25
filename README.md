# ProSlide
A MacOS utility that can convert PowerPoint/PDF files to JPEGs. This can then be imported into ProPresenter without destroying slide contents.

## Requirements
- macOS 13 or later
- Xcode 15 or later (for development)
- LibreOffice installed in `/Applications` for `.pptx` conversion. PDF conversion works without it.

## Run
Open `Package.swift` in Xcode and run the `FileConverter` scheme. The project is also a Swift Package, so it can be built with `swift build` on macOS.

## Tests
`swift test` runs the conversion pipeline against 16:9 sample PDF/PPTX fixtures at every resolution preset (HD 1280x720, Full HD 1920x1080, 4K 3840x2160), asserting output size and that the render stays upright. The PPTX path is skipped when LibreOffice is not installed. CI runs this suite on a macOS runner on every push.

## Conversion behavior
- PDF: PDFKit/Core Graphics renders each page directly to JPEG.
- PPTX: the app runs LibreOffice headlessly to make a temporary PDF, then renders that PDF to JPEG.
- Every job creates a new `Document Name JPEGs` folder in the selected export location (Downloads by default), avoiding accidental overwrites.

LibreOffice fidelity depends on installed fonts and PowerPoint-specific effects. For the closest possible Microsoft Office rendering, a future version can add PowerPoint automation as an optional renderer.

## Security considerations
- ProSlide opens untrusted PDFs and PowerPoint files with Apple's PDFKit and LibreOffice. As with any document viewer, a malicious file could attempt to exploit a parser bug and run code on your machine, so keep LibreOffice and macOS updated. The app makes no network connections and stores no credentials.
- As a guard against crafted documents with extreme page dimensions or page counts, rendering clamps every output image to at most 8192 px per side and a document to at most 300 pages.

## Rust extension point
The UI and Apple PDF APIs deliberately remain Swift-native. A Rust core is useful for future cross-platform batch queues, naming/collision policy, and image-processing work, but it should not replace PDFKit or LibreOffice (The two components doing document rendering). This MVP keeps the app dependency-free and lightweight while leaving that core as a clean future module.

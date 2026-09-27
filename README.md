# ProSlide
A macOS app that converts PDF and PowerPoint files into dependable JPEG images, ready to import into ProPresenter without destroying slide contents.

## Requirements
- macOS 13 or later
- Swift 5.9 or later (Xcode 15+, or the Command Line Tools, to build)
- LibreOffice installed in `/Applications` for `.pptx` conversion. PDF conversion works without it.

## Layout
- `App/ProSlide/` — the app: `ProSlideApp.swift`, `ContentView.swift`, `BinOpener.swift` and its asset catalog.
- `App/ProSlide.xcodeproj` — development only. Not needed to build, run, or install the app.
- `Package.swift` — builds both the engine library and the app executable.
- `Sources/FileConverterCore/` — the Swift package library: the conversion engine and the batch queue.
- `Tests/FileConverterTests/` — engine and batch tests.
- `Scripts/make-app-bundle.sh` — assembles `ProSlide.app` from `swift build`.

The app links the engine as a local Swift package, so there is one copy of the rendering code and no duplicate `@main`. The batch queue lives in the library rather than the app specifically so batch behaviour is covered by `swift test` and CI, without needing a window.

## Install
```
./Scripts/make-app-bundle.sh --install
open /Applications/ProSlide.app
```
This compiles a release build with `swift build` and writes a signed `ProSlide.app`, then copies it to `/Applications`. It never touches `App/ProSlide.xcodeproj`, so it cannot be broken by an Xcode project problem.

Without installing, `./Scripts/make-app-bundle.sh` writes `build/ProSlide.app`, which you can double-click in Finder. Pass `debug` before any other flag for a debug build, e.g. `./Scripts/make-app-bundle.sh debug`. To update an installed copy later, re-run the same command.

If macOS ever refuses to open a build copied from another machine, clear the quarantine flag:
```
xattr -dr com.apple.quarantine /Applications/ProSlide.app
```

## Develop in Xcode
Open `App/ProSlide.xcodeproj` for breakpoints and SwiftUI previews. When you add or rename a file under `App/ProSlide/`, add it to the `ProSlideApp` target in `Package.swift` too — that is what the packaging script and CI build, so a file registered only in the pbxproj compiles in Xcode but is missing from the installed app.

## Tests
```
swift test
```
`EngineSmokeTests` runs the conversion pipeline against 16:9 PDF/PPTX fixtures at every resolution preset (HD 1280x720, Full HD 1920x1080, 4K 3840x2160), asserting output size and that the render stays upright, plus a clamp test for pathological page dimensions. The PPTX path is skipped when LibreOffice is not installed.

`ConversionQueueTests` drives the batch queue through an injected converter, so it needs neither a window nor LibreOffice. It covers name-ordered sequencing, per-file error isolation, re-queuing a failure on the next run, security-scope balance, aggregate progress arithmetic, cancellation, unsupported-file reporting, and bin scanning. CI runs both suites on a macOS runner on every push, and packages the app with the same script the install instructions use.

## Using it
- Drop or choose any number of PDFs and `.pptx` files at once. The queue sorts them by name so a batch is predictable, and each row shows its own state.
- Unsupported files are reported and skipped instead of failing the batch.
- **Convert N files** runs them one at a time. One bad document never stops the rest; **Stop** cancels the run and leaves the unconverted files queued.
- Each document gets its own `Document Name JPEGs` folder in the persistent bin (`~/Library/Application Support/FileConverter/Bin`) and never overwrites an earlier conversion.

## Dragging into ProPresenter
- Every image can be dragged individually, or use a document's **Drag All Images** handle for the whole set in one gesture.
- **Drag Folder** (and **Drag Folders** for a multi-document selection) drops the folder itself, which is what ProPresenter wants to import a set as a sequence.
- Click document rows to select them, then **Select All** and the combined drag handles appear. **Save…** copies a set to a folder you choose.

## Conversion behavior
- PDF: PDFKit/Core Graphics renders each page directly to JPEG.
- PPTX: the app runs LibreOffice headlessly to make a temporary PDF, then renders that PDF to JPEG.
- JPEG quality is always ImageIO's maximum (1.0). The quality slider was removed on purpose: the renders are already capped at 8192 px per side, so a lower-quality knob only traded away fidelity. Note this is maximum lossy quality, not lossless — output remains 4:2:0 subsampled.
- A batch reuses one LibreOffice profile across all its files, since creating a user profile is a real per-run cost.
- LibreOffice fidelity depends on installed fonts and PowerPoint-specific effects. For the closest possible Microsoft Office rendering, a future version can add PowerPoint automation as an optional renderer.

## Security considerations
- ProSlide opens untrusted PDFs and PowerPoint files with Apple's PDFKit and LibreOffice. As with any document viewer, a malicious file could attempt to exploit a parser bug and run code on your machine, so keep LibreOffice and macOS updated. The app makes no network connections and stores no credentials.
- As a guard against crafted documents with extreme page dimensions or page counts, rendering clamps every output image to at most 8192 px per side and a document to at most 300 pages.
- The app is unsandboxed because it launches LibreOffice as a child process, and it takes a security-scoped read scope on every document you import, releasing it once the document is converted or removed.

## Rust extension point
The UI and Apple PDF APIs deliberately remain Swift-native. A Rust core is useful for future cross-platform batch queues, naming/collision policy, and image-processing work, but it should not replace PDFKit or LibreOffice (the two components doing document rendering). This MVP keeps the app dependency-free and lightweight while leaving that core as a clean future module.

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

Both build systems use Swift 5 language mode: `Package.swift` declares `swift-tools-version: 5.9` with no `swiftLanguageMode`, and the Xcode target sets `SWIFT_VERSION = 5.0`. The code has not been audited for strict concurrency, so treat sendability warnings as expected and fix them in place — do not turn the language mode up to silence one. For the same reason, prefer the pre-macOS-14 `.onChange(of:) { value in }` form over the zero-parameter one, which requires raising the deployment target.

## Tests
```
swift test
```
`EngineSmokeTests` runs the conversion pipeline against 16:9 PDF/PPTX fixtures at every resolution preset (HD 1280x720, Full HD 1920x1080, 4K 3840x2160), asserting output size and that the render stays upright, plus a clamp test for pathological page dimensions. The PPTX path is skipped when LibreOffice is not installed.

`ConversionQueueTests` drives the batch queue through an injected converter, so it needs neither a window nor LibreOffice. It covers name-ordered sequencing, per-file error isolation, re-queuing a failure on the next run, security-scope balance, aggregate progress arithmetic, cancellation, unsupported-file reporting, and bin scanning.

CI runs both suites on a macOS runner on every push, and packages the app with the same script the install instructions use.

## Using it
- Drop or choose any number of PDFs and `.pptx` files at once. The queue sorts them by name so a batch is predictable, and each row shows its own state.
- Unsupported files are reported and skipped instead of failing the batch.
- **Convert N files** runs them one at a time. One bad document never stops the rest; **Stop** cancels the run and leaves the unconverted files queued.
- Each document gets its own `Document Name JPEGs` folder in the persistent bin (`~/Library/Application Support/FileConverter/Bin`) and never overwrites an earlier conversion.

## Dragging into ProPresenter
- Every document in the bin has one **Drag All Images** handle. Drop it on ProPresenter and the document's whole `Name JPEGs` folder arrives as a sequence, so no selection step and no trip to Finder are needed.
- Drag an individual thumbnail to move just that one image.
- **Save…** copies a document's set to a folder you choose.

The handle drops the document's *folder*, not a bundle of loose files, and the folder icon on the handle says so. That is deliberate. A SwiftUI drag hands over a single `NSItemProvider`, so a list of URLs packed into one item does not arrive as many files — the receiving app takes the first and you get one slide. Finder avoids this by writing one pasteboard item per file, which requires an AppKit drag session. Dropping the folder sidesteps the limitation and matches what ProPresenter wants. If a deck ever needs only a middle range of slides, the bin has no control for that; the thumbnail drag is the only way to cherry-pick, one image at a time.

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

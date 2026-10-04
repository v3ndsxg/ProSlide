# ProSlide
A macOS app that converts PDF and PowerPoint files into dependable JPEG images, ready to import into ProPresenter without destroying slide contents.

## Installing ProSlide

### Should you trust it?

That is your call to make, so here is everything you need to decide rather than a request for faith.

- **It is MIT-licensed**, so you are explicitly permitted to read all of it. See `LICENSE` and the source layout below.
- **It is small: roughly 1,300 lines of shipped Swift** (444 in the app, 847 in the engine), plus 1,267 lines of tests. That is short enough to actually read end to end, not just skim.
- **It contains no network code at all** — no `URLSession`, no `URLRequest`, no URLs. It cannot phone home, because there is nothing to phone home with.
- **It stores no credentials**, and never touches the Keychain.
- **It launches exactly one external program: LibreOffice**, at a path the app checks for first, to turn `.pptx` files into PDFs. Converting a PDF launches nothing. The only other system interactions are revealing a folder in Finder when you click **Open**, and reading image dimensions from the JPEGs it just wrote.
- The real risk is not the app but the documents: opening a PDF or PowerPoint file means trusting Apple's PDFKit and LibreOffice to parse it, exactly as Preview and Keynote do. See [Security considerations](#security-considerations) for that, and for the 8192 px / 300 page guards against pathological files.

None of that makes it safe by assertion. It makes it auditable in a way that fits on one screen, which is the point.

### Installing

## Requirements
- macOS 13 or later
- Swift 5.9 or later (Xcode 15+, or the Command Line Tools, to build)
- LibreOffice installed in `/Applications` for `.pptx` conversion. PDF conversion works without it.
You will need macOS 13 or later, and either Xcode 15+ or the Swift Command Line Tools so `swift` is available. LibreOffice is needed only for `.pptx`; PDF conversion works without it.

```
git clone https://github.com/v3ndsxg/ProSlide.git
cd ProSlide
./Scripts/make-app-bundle.sh --install
```

That compiles a release build and copies a working `ProSlide.app` into `/Applications`. To open it, either

```
open /Applications/ProSlide.app
```

or just find **ProSlide** in Spotlight or Launchpad — once installed it is an ordinary app like any other.

### If macOS refuses to open it

The app is **ad-hoc signed** (`codesign -s -`) and is **not notarized**. There is no Apple-issued developer identity behind it, because it is not sold through the App Store, so Gatekeeper may object on first launch. Nothing is wrong with the build.

Click through it by right-clicking the app in Finder and choosing **Open** once, or clear the quarantine flag:

```
xattr -dr com.apple.quarantine /Applications/ProSlide.app
```

Contributors should see [Install](#install) for the build flags, and the `Scripts/make-app-bundle.sh` header for the full usage.

## Layout
- `App/ProSlide/` — the app: `ProSlideApp.swift`, `ContentView.swift`, `BinOpener.swift` and its asset catalog.
- `App/ProSlide.xcodeproj` — development only. Not needed to build, run, or install the app.
- `Package.swift` — builds both the engine library and the app executable.
- `Sources/FileConverterCore/` — the Swift package library: the conversion engine, the batch queue, and the ProPresenter packaging.
- `Tests/FileConverterTests/` — engine and batch tests.
- `Scripts/make-app-bundle.sh` — assembles `ProSlide.app` from `swift build`.

The app links the engine as a local Swift package, so there is one copy of the rendering code and no duplicate `@main`. The batch queue lives in the library rather than the app specifically so batch behaviour is covered by `swift test` and CI, without needing a window.

## Develop in Xcode
Open `App/ProSlide.xcodeproj` for breakpoints and SwiftUI previews. When you add or rename a file under `App/ProSlide/`, add it to the `ProSlideApp` target in `Package.swift` too — that is what the packaging script and CI build, so a file registered only in the pbxproj compiles in Xcode but is missing from the installed app.

Both build systems use Swift 5 language mode: `Package.swift` declares `swift-tools-version: 5.9` with no `swiftLanguageMode`, and the Xcode target sets `SWIFT_VERSION = 5.0`. The code has not been audited for strict concurrency, so treat sendability warnings as expected and fix them in place — do not turn the language mode up to silence one. For the same reason, prefer the pre-macOS-14 `.onChange(of:) { value in }` form over the zero-parameter one, which requires raising the deployment target.

## Tests
```
swift test
```
`EngineSmokeTests` runs the conversion pipeline against 16:9 PDF/PPTX fixtures at every resolution preset (HD 1280x720, Full HD 1920x1080, 4K 3840x2160), asserting output size and that the render stays upright, plus a clamp test for pathological page dimensions. The PPTX path is skipped when LibreOffice is not installed.

`ConversionQueueTests` drives the batch queue through an injected converter, so it needs neither a window nor LibreOffice. It covers name-ordered sequencing, per-file error isolation, re-queuing a failure on the next run, security-scope balance, aggregate progress arithmetic, cancellation, unsupported-file reporting, and bin scanning.

`ProPresenterPackageTests` covers the packaging path with no window, no LibreOffice and no real JPEG decoding — pixel sizes are injected. It decodes the generated manifest with an independent protobuf reader (`ProtoReader.swift`) and the generated archive with an independent ZIP reader (`ZipReader.swift`), so a mistake shared between a writer and its decoder cannot pass unnoticed. `reference.pro` in `Fixtures/` is a real ProPresenter-written presentation with its paths and identifiers replaced; it is the ground truth for every field number the writer emits.

CI runs all three suites on a macOS runner on every push, and packages the app with the same script the install instructions use.

## Using it

1. **Add your file or files.** Drag PDFs and `.pptx` files onto the panel, or click it to pick them. You can add more at any time.
2. **Check the resolution.** Leave it at Full HD unless you have a reason; that is the right choice for most ProPresenter services.
3. **Press Convert** (or ⌘↩). One at a time they run, and the panel shows what each file is doing. If a file fails, the rest still convert and the failure tells you why.
4. **Wait for the Bin** to fill in on the right. Each document gets its own `Document Name JPEGs` folder, and the bin remembers everything you have converted, so it is still there next time you open the app. Documents are listed alphabetically.
5. **Drag the card into ProPresenter.** That is the whole job. Every slide in that document arrives, in order, named `Document-001.jpg`, `Document-002.jpg`, and so on.

If you want the deck to arrive as a single named presentation rather than a pile of slides, set **Drag as** in the bin to `.probundle` or `.pro` first — see [Packaging as a ProPresenter presentation](#packaging-as-a-propresenter-presentation).

If you need a slide that is not the whole document, drag its individual thumbnail instead of the card. And if you want the images somewhere other than ProPresenter, **Save…** copies a document's set to any folder you choose.

Two details worth knowing: converting the same file again creates a second folder rather than overwriting the first, and **Stop** halts a batch without losing the files you have not converted yet.

## Dragging into ProPresenter
- The whole document card in the bin is a drag source. Drop it on ProPresenter and the document's `Name JPEGs` folder arrives as a sequence, so no selection step and no trip to Finder are needed.
- Drag an individual thumbnail to move just that one image.
- **Save…** copies a document's set to a folder you choose.
- The **Drag as** control switches the card between that folder and a packaged `.probundle` or `.pro`. See [Packaging as a ProPresenter presentation](#packaging-as-a-propresenter-presentation).

A card drag carries the document's *folder*, not a bundle of loose files, and the folder icon on the card says so. That is deliberate. A SwiftUI drag hands over a single `NSItemProvider`, so a list of URLs packed into one item does not arrive as many files — the receiving app takes the first and you get one slide. Finder avoids this by writing one pasteboard item per file, which requires an AppKit drag session. Dragging the folder sidesteps the limitation and matches what ProPresenter wants. If a deck ever needs only a middle range of slides, the bin has no control for that; the thumbnail drag is the only way to cherry-pick, one image at a time.

## Packaging as a ProPresenter presentation
The **Drag as** control at the top of the bin changes what a card drag hands over. The default, **JPEGs**, is the behaviour above. The other two package the document into a real ProPresenter file first, written into the document's own folder so **Clear** takes it away again:

| Drag as | What you get | When to use it |
| --- | --- |---|
| **JPEGs** | The `Name JPEGs` folder | Importing slides into an existing presentation. |
| **.probundle** | `Name.probundle`, a ZIP holding `Name.pro` plus a copy of every JPEG under `Media/Assets` | Anything you want to move, email, put on a USB stick, or open on another machine. Self-contained. |
| **.pro** | `Name.pro`, pointing at the JPEGs where they already are | Smallest option, and fine if the bin never moves. The links break if the JPEGs do. |

Packaging runs in the background when you pick a mode, and each card shows whether it is ready. Because a drag can only be assembled at the moment you start it, a card that has not finished packaging still falls back to dragging its JPEG folder rather than doing nothing. **Package** on a card forces a rebuild if you have re-converted or edited the JPEGs.

A `.probundle` is the better default for sharing. ProPresenter itself exports that format, and the bundle resolves its images relative to itself, so nothing depends on where it was made. The bare `.pro` resolves images against your home folder, which is why it refuses to package anything living outside it.

Two deliberate omissions. Generated slides carry no playback duration, so a slide holds until you click rather than advancing on a timer; ProPresenter's own exports set ten seconds on announcement slides, which is the right behaviour for announcements but the wrong one for a sermon deck. And each slide is its own cue in a single group, so the deck is a flat sequence with no arrangements or sections.

### About the format
ProPresenter 7 and later store presentations as Google Protocol Buffers messages rather than the XML that version 6 used. The schema is community-reverse-engineered and is **not** created, endorsed or supported by Renewed Vision. ProSlide writes it directly — `ProtobufWriter.swift` is a small wire-format writer and `ProPresenterDocument.swift` describes the handful of messages a deck of still images needs — so there is no `protoc` step and no new dependency.

That also means the field numbers are pinned to a particular version. `Tests/FileConverterTests/Fixtures/reference.pro` is a recording of a presentation ProPresenter wrote itself, with every path and identifier replaced, and `ProPresenterPackageTests` checks the generated manifest against it field by field. If a future ProPresenter version stops reading these files, that fixture is where you start. Always keep a backup of anything you have already made, and test on a copy.

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

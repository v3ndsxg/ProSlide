# ProSlide
A macOS app that converts PDF and PowerPoint files into JPEG images for ProPresenter, and packages each deck as a ProPresenter `.probundle` presentation.

## Install

Requires macOS 13+ and Xcode 15+ or the Swift Command Line Tools. LibreOffice is needed only for PowerPoint files (`.pptx` and `.ppt`); PDFs convert without it. It can live in `/Applications` or `~/Applications`.

```
git clone https://github.com/v3ndsxg/ProSlide.git
cd ProSlide
./Scripts/make-app-bundle.sh --install
open /Applications/ProSlide.app
```

The app is ad-hoc signed and not notarized, so Gatekeeper may object on first launch. Right-click the app and choose **Open** once, or run `xattr -dr com.apple.quarantine /Applications/ProSlide.app`.

### Should you trust it?
- MIT-licensed and small enough to read end to end.
- No network code, no credentials, no Keychain.
- It launches one external program, LibreOffice, and only for PowerPoint files.
- The real risk is the documents: PDFKit and LibreOffice parse files you open, as Preview and Keynote do. See [Security](#security).

## Using it
1. Drag PDFs and PowerPoint files (`.pptx` or `.ppt`) onto the panel, or click it to pick them.
2. Leave the resolution at Full HD unless you have a reason.
3. Press **Convert** (⌘↩). Files run one at a time; a failure doesn't stop the rest.
4. Each document appears in the **Bin** as a card, remembered across launches.
5. Drag the card into ProPresenter.

**Convert** runs only files that haven't finished, so adding a file to a completed batch doesn't redo the others. Drop a file again to convert it again; that creates a second folder rather than overwriting the first. **Stop** ends the batch, including a running LibreOffice, and discards the file in progress.

## The bin and dragging
The **Converted decks** panel lists each document as a compact row: a grip (the cue that it can be dragged), the name, its slide count, and a status chip (**Ready**, **Preparing…**, **Not built** or **Couldn't prepare**). A switch at the top sets what dragging a row hands over:

- **ProPresenter Presentation** (default): one `Name.probundle`, which ProPresenter imports as a single named presentation with every image inside it.
- **JPEG Files**: the `Name JPEGs` folder, which ProPresenter imports as a plain sequence. Use this to add slides to an existing presentation, or when you need something portable.

Other controls:
- The chevron on a row previews that deck's slides. Rows start collapsed and open independently. Drag a single thumbnail to move one image.
- Right-click a row for **Show in Finder**, **Save a copy…** (saves what the row drags) and **Rebuild presentation**. There are no buttons on the rows themselves.
- **Clear** empties the panel and the file list on the main page.
- **Couldn't prepare** means the bundle couldn't be written. The row won't drag as a presentation, and never falls back to the JPEGs. Open it to see why and press **Try again**.
- A deck converted before bundles existed shows **Not built**. Open its row and press **Build presentation**.

A drag hands over a single item, which is why a whole deck travels as one bundle or one folder rather than a pile of files.

### Where files live
- JPEGs: `~/Documents/ProSlide/Bin/<Name> JPEGs/`, holding JPEGs and nothing else.
- Presentations: `~/Documents/ProSlide/Pro/<Name>.probundle`. They're kept apart from the JPEG folders because ProPresenter imports a folder holding a presentation as that presentation. Each bundle has its own copy of the JPEGs, so a deck takes about twice the space until you **Clear**.
- Both are under Documents because ProPresenter opens these paths itself, and macOS won't let it into another app's container. Decks in the old location (`~/Library/Application Support/FileConverter/Bin`) are moved across on the first scan.

## How the bundle works
A `.probundle` is an uncompressed zip holding `<Name>.pro` and the deck's images under `Media/Assets/`. The `.pro` names each image relative to the bundle, so:

- The bundle works on any machine, and keeps working after the bin is cleared.
- On import, ProPresenter copies the images into its own media store, with media management on or off. Importing the same deck twice gives a second copy named `-1`.
- ProSlide never reads, writes or deletes anything in ProPresenter's own folders.

Bundles are built during **Convert**, so a deck is ready to drag when it reaches the bin. Each is written under a temporary name and renamed when complete, so an interrupted one is never offered.

### The format
ProPresenter 7+ stores presentations as protobuf, in a schema the community reverse-engineered and Renewed Vision doesn't support. ProSlide writes the protobuf and the zip itself (`ProtobufWriter.swift`, `ZipWriter.swift`), with no `protoc` step.

The layout was copied from a bundle ProPresenter exported, then confirmed by importing generated bundles. Each slide is one cue holding an empty slide with the canvas size, then a foreground media action with the image. A media action is used because ProPresenter can turn a media cue into a slide element but not the reverse. Image paths are relative to the bundle and never absolute.

`ProPresenterDocument.swift` lists what is deliberately left out of the `.pro`, and why. Don't change it without testing a new import.

## Conversion
- **PDF:** PDFKit and Core Graphics render each page to JPEG, using the page's crop box and honouring its rotation.
- **PPTX and PPT:** LibreOffice runs headless to make a temporary PDF, which is rendered the same way. A batch shares one LibreOffice profile, and a conversion that takes over five minutes is stopped.
- **Quality:** always ImageIO's maximum (1.0). That is the top lossy setting, not lossless.
- **Embed Fonts:** passed to LibreOffice's PDF export. It's on by default as a safeguard for odd font cases.
- **Fidelity:** LibreOffice output depends on installed fonts and PowerPoint-specific effects.

## Layout
- `App/ProSlide/`: the SwiftUI app.
- `App/ProSlide.xcodeproj`: development only (breakpoints, previews).
- `Sources/FileConverterCore/`: the conversion engine, batch queue and `.probundle` packaging.
- `Tests/FileConverterTests/`: tests and fixtures.
- `Scripts/make-app-bundle.sh`: builds `ProSlide.app` from `swift build`.
- `Scripts/check-probundle.py`: checks `.probundle` files with no Swift and no Mac (see below).

## Development
Open `App/ProSlide.xcodeproj` in Xcode, or use the package directly. When you add or rename a file under `App/ProSlide/`, also add it to the `ProSlideApp` target in `Package.swift`, or it will be missing from the installed app.

Both build systems use Swift 5 language mode, and the code hasn't been audited for strict concurrency. Fix sendability warnings in place rather than raising the language mode. Prefer the `.onChange(of:) { value in }` form, since the zero-parameter one needs macOS 14.

```
swift test
```
- `EngineSmokeTests`: PDF and PPTX at every resolution preset (HD, Full HD, 4K) and PPT at Full HD, checking output size and orientation. The PowerPoint tests are skipped without LibreOffice.
- `ConversionQueueTests`: the batch queue through an injected converter and packager, against a temporary bin, with no window or LibreOffice.
- `ProPresenterPackageTests`: the zip and `.pro` writers, read back with independent readers and the system's `unzip`, plus a real bundle built from each fixture. These tests can't prove ProPresenter accepts a file; only an import can.

CI runs on a macOS runner. It packages the app with the install script, runs the tests, then checks the bundles they built with `Scripts/check-probundle.py`. If LibreOffice didn't install, the run shows a warning that the PowerPoint path wasn't checked. Each run uploads a **test-artifacts** zip holding the test output, the rendered JPEGs and the bundles, ready to drag into ProPresenter.

The checker is standard-library Python that shares no code with the Swift writer, so it runs anywhere, Linux included:

```
python3 -I Scripts/check-probundle.py Deck.probundle   # or a folder of them
```

## Security
- Untrusted PDFs and PowerPoint files are parsed by PDFKit and LibreOffice. A crafted file could try to exploit a parser bug, so keep macOS and LibreOffice updated.
- Output is capped at 8192 px per side and 300 pages per document, and filenames are sanitised.
- The app is unsandboxed because it launches LibreOffice. It makes no network connections.

## Possible future work
A Rust core for batch queuing and image processing, and PowerPoint automation as an optional renderer for closer Office fidelity. PDFKit and LibreOffice stay as the renderers.

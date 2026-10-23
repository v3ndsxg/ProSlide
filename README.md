# ProSlide
A macOS app that converts PDF and PowerPoint files into JPEG images for ProPresenter, and can package each deck as a ProPresenter `.pro` presentation.

## Install

Requires macOS 13+ and Xcode 15+ or the Swift Command Line Tools. LibreOffice is needed only for `.pptx`; PDFs convert without it.

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
- It launches one external program, LibreOffice, and only for `.pptx`.
- The real risk is the documents: PDFKit and LibreOffice parse files you open, as Preview and Keynote do. See [Security](#security).

## Using it
1. Drag PDFs and `.pptx` files onto the panel, or click it to pick them.
2. Leave the resolution at Full HD unless you have a reason.
3. Press **Convert** (⌘↩). Files run one at a time; a failure doesn't stop the rest.
4. Each document appears in the **Bin** as a card, remembered across launches.
5. Drag the card into ProPresenter.

**Convert** runs only files that haven't finished, so adding a file to a completed batch doesn't redo the others. Drop a file again to convert it again; that creates a second folder rather than overwriting the first. **Stop** ends the batch, including a running LibreOffice, and discards the file in progress.

## The bin and dragging
A switch at the top of the bin sets what a card drag hands over:

- **.pro Presentation** (default): one `Name.pro`, which ProPresenter opens as a single named presentation with every slide attached.
- **JPEG Folder**: the `Name JPEGs` folder, which ProPresenter imports as a plain sequence. Use this to add slides to an existing presentation, or when you need something portable.

Other controls:
- Drag a single thumbnail to move one image.
- **Save…** copies what the card drags (the `.pro` or the JPEGs) to a folder you choose.
- **Rebuild** rewrites a deck's `.pro`. **Presentations** reveals the `Pro` folder. **Clear** empties the bin.

A card drag carries one item, never a pile of files: SwiftUI hands over a single `NSItemProvider`, so a list of URLs arrives as one slide. That's why the `.pro`, which references every image, is the way to drag a whole deck.

If a deck's `.pro` can't be written, its card won't drag in presentation mode, and the bin explains why. It does not fall back to the JPEGs.

### Where files live
- JPEGs: `~/Documents/ProSlide/Bin/<Name> JPEGs/`, holding JPEGs and nothing else.
- Presentations: `~/Documents/ProSlide/Pro/`, kept outside the deck folders because ProPresenter imports a folder containing a `.pro` as a presentation, which would break the JPEG Folder option.
- Both are under Documents on purpose. ProPresenter opens these paths itself, and macOS won't let it into another app's `Application Support` container. Decks left in the old location (`~/Library/Application Support/FileConverter/Bin`) are moved across on the first scan.

## How the `.pro` works
A `.pro` is a protobuf manifest that **names** images; it can't contain them. So for each deck, ProSlide:

1. Hard-links the JPEGs into `<ProPresenter folder>/Media/Imported/<deck>/<item>/`. A link is a second name for the same bytes, so nothing is duplicated. If the link fails (a library on another disk), it copies instead.
2. Writes a `.pro` whose media paths point at those files.

Consequences:
- The `.pro` is tied to the machine whose ProPresenter library it was written against. Use JPEG Folder to move slides between machines.
- ProPresenter's folder is found via `PathSettings.proPaths`, then `~/Documents/ProPresenter`, then `~/Library/Application Support/ProPresenter`. It must already exist, because ProSlide never creates it. A library moved elsewhere in ProPresenter's preferences may not be found.
- Rebuilding keeps a deck's staged media where it is unless the deck's images changed. **Clear** deletes it, so re-import a deck afterwards if ProPresenter reads its images in place.
- Slides carry no playback duration, so each holds until you click.

### The format
ProPresenter 7+ stores presentations as protobuf. The schema is community-reverse-engineered and not supported by Renewed Vision. ProSlide writes it with a small wire-format writer (`ProtobufWriter.swift`) and no `protoc` step.

`Tests/FileConverterTests/Fixtures/real.pro` is a presentation exported by ProPresenter 21.3 and is the ground truth. What an image slide needs, each of which was wrong at least once:

- **One action per cue**, a presentation slide. The image is an element inside it. There are no media actions.
- **A path as well as bounds** on the image element: a closed rectangle over the unit square. Without it the media resolves, nothing warns, and the slide is blank.
- **Bounds** equal to the slide's size.
- **Media URLs** use root `ROOT_SHOW` (10), a path relative to ProPresenter's folder, and a full `file://` absolute string. Paths never climb out with `..`.
- **`metadata.format`** is uppercase `JPG`.
- **The cue group** names the cues by their own identifiers.
- **No arrangements.**

## Conversion
- **PDF:** PDFKit and Core Graphics render each page to JPEG, using the page's crop box and honouring its rotation.
- **PPTX:** LibreOffice runs headless to make a temporary PDF, which is rendered the same way. A batch shares one LibreOffice profile, and a conversion that takes over five minutes is stopped.
- **Quality:** always ImageIO's maximum (1.0). That is the top lossy setting, not lossless.
- **Embed Fonts:** passed to LibreOffice's PDF export. It's on by default as a safeguard for odd font cases.
- **Fidelity:** LibreOffice output depends on installed fonts and PowerPoint-specific effects.

## Layout
- `App/ProSlide/`: the SwiftUI app.
- `App/ProSlide.xcodeproj`: development only (breakpoints, previews).
- `Sources/FileConverterCore/`: the conversion engine, batch queue and `.pro` packaging.
- `Tests/FileConverterTests/`: tests and fixtures.
- `Scripts/make-app-bundle.sh`: builds `ProSlide.app` from `swift build`.

## Development
Open `App/ProSlide.xcodeproj` in Xcode, or use the package directly. When you add or rename a file under `App/ProSlide/`, also add it to the `ProSlideApp` target in `Package.swift`, or it will be missing from the installed app.

Both build systems use Swift 5 language mode, and the code hasn't been audited for strict concurrency. Fix sendability warnings in place rather than raising the language mode. Prefer the `.onChange(of:) { value in }` form, since the zero-parameter one needs macOS 14.

```
swift test
```
- `EngineSmokeTests`: PDF and PPTX at every resolution preset (HD, Full HD, 4K), checking output size and orientation. The PPTX test is skipped without LibreOffice.
- `ConversionQueueTests`: the batch queue through an injected converter, with no window or LibreOffice.
- `ProPresenterPackageTests`: the `.pro` writer, decoded with an independent protobuf reader and compared with `real.pro`. These tests can't prove ProPresenter accepts a file; only an import can.

CI runs all of this on a macOS runner and packages the app with the install script.

## Security
- Untrusted PDFs and PPTX files are parsed by PDFKit and LibreOffice. A crafted file could try to exploit a parser bug, so keep macOS and LibreOffice updated.
- Output is capped at 8192 px per side and 300 pages per document, and filenames are sanitised.
- The app is unsandboxed because it launches LibreOffice. It makes no network connections.

## Possible future work
A Rust core for batch queuing and image processing, and PowerPoint automation as an optional renderer for closer Office fidelity. PDFKit and LibreOffice stay as the renderers.

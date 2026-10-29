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
- No credentials and no Keychain. The production app has no network code. The beta's Downloader reaches the internet only through `yt-dlp`, when you press Download on a link you pasted (see [Beta features](#beta-features)).
- It launches LibreOffice for PowerPoint files. The beta also launches `yt-dlp`, `ffmpeg` and Deno for downloads.
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
- Downloads (beta): `~/Documents/ProSlide Beta/Downloads/<Title>.mp4` or `.mp3`, beside `Bin` and `Pro`. Each download works in a hidden `.work` folder and is moved in only when finished, so the bin never shows a partial file.
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
- `Sources/FileConverterCore/`: the conversion engine, batch queue and `.probundle` packaging, plus the Downloader's engine and queue.
- `Tests/FileConverterTests/`: tests and fixtures.
- `Scripts/make-app-bundle.sh`: builds `ProSlide.app` from `swift build`.
- `Scripts/check-probundle.py`: checks `.probundle` files with no Swift and no Mac (see below).
- `Scripts/tools.lock`, `fetch-tools.sh`, `update-tools.sh`: the pinned download tools (see [Beta features](#beta-features)).

## Development
Open `App/ProSlide.xcodeproj` in Xcode, or use the package directly. When you add or rename a file under `App/ProSlide/`, also add it to the `ProSlideApp` target in `Package.swift`, or it will be missing from the installed app.

Both build systems use Swift 5 language mode, and the code hasn't been audited for strict concurrency. Fix sendability warnings in place rather than raising the language mode. Prefer the `.onChange(of:) { value in }` form, since the zero-parameter one needs macOS 14.

```
swift test
```
- `EngineSmokeTests`: PDF and PPTX at every resolution preset (HD, Full HD, 4K) and PPT at Full HD, checking output size and orientation. The PowerPoint tests are skipped without LibreOffice.
- `ConversionQueueTests`: the batch queue through an injected converter and packager, against a temporary bin, with no window or LibreOffice.
- `DownloadModelsTests`, `DownloadEngineTests`, `DownloadQueueTests`, `DownloadsBinTests`: the Downloader's links, command lines, progress, engine and queue, and the bin's handling of downloads. The engine runs against stand-in `yt-dlp` and `ffmpeg` scripts, so no network or real tools are needed.
- `RealToolsTests`: the engine against the real packaged tools and a local web server. Skipped unless `PROSLIDE_TOOLS_DIR` points at the tools; CI sets it. It never reaches the internet.
- `ProPresenterPackageTests`: the zip and `.pro` writers, read back with independent readers and the system's `unzip`, plus a real bundle built from each fixture. These tests can't prove ProPresenter accepts a file; only an import can.

CI runs on a macOS runner. It packages the app with the install script (both the beta and the production app), runs each packaged download tool from inside the app, runs the tests, then checks the bundles they built with `Scripts/check-probundle.py`. If LibreOffice didn't install, the run shows a warning that the PowerPoint path wasn't checked. Each run uploads a **test-artifacts** zip holding the test output, the rendered JPEGs and the bundles, ready to drag into ProPresenter.

The checker is standard-library Python that shares no code with the Swift writer, so it runs anywhere, Linux included:

```
python3 -I Scripts/check-probundle.py Deck.probundle   # or a folder of them
```

## Security
- Untrusted PDFs and PowerPoint files are parsed by PDFKit and LibreOffice. A crafted file could try to exploit a parser bug, so keep macOS and LibreOffice updated.
- Output is capped at 8192 px per side and 300 pages per document, and filenames are sanitised.
- The app is unsandboxed because it launches LibreOffice (and, in the beta, the download tools).
- The production app makes no network connections. In the beta, only `yt-dlp` does, and only for links you paste. Links are passed to it as arguments after `--`, never through a shell, and only `http` and `https` links are accepted. There is no cookie or login support.
- The download tools are pinned to exact versions and SHA-256 checksums in `Scripts/tools.lock`. The build refuses any file that doesn't match, and no binary is committed to git. There is no in-app updater: updating means a reviewed change to the lock file.

## Beta features
These live on the `beta` branch and are not in `main` yet. New work is tested there first and reaches `main` only once it has proven out.

### Downloader
The **Downloader** tab saves videos as MP4 or just their audio as MP3, from YouTube and most social media sites, straight into the bin.

1. Switch to the **Downloader** tab, and paste one link per line (or press **Paste**). A link can leave off `https://`. YouTube links in any form (Shorts, `youtu.be`, `/live/`, embeds, the mobile and Music sites) are read as the plain video link, so the same video pasted twice shows once.
2. Choose **MP4 Video** or **MP3 Audio**. For MP4, choose a quality from the tabs: it means "up to this", and a video without it downloads at the best it has. Tabs that none of the pasted links offer are greyed out, and if the quality you chose isn't offered a message says so (red for 4K, yellow for 1440p). Quality is measured by the shorter side, so a vertical Short is 1080p. The default is 1080p, and the format and quality are remembered.
3. Each pasted link gets a row showing its site, title, length and the best quality on offer. Links are looked up three at a time, and download without a lookup if one is slow. A lookup first asks YouTube the quick way (up to 20 seconds), and if that fails for any reason asks the normal way (up to another 45 seconds).
4. Press **Download** (⌘↩). Links download one at a time, shown as cards in the bin with a live line such as "Downloading video · 45% · 3.2 MB/s · 1:20 left". **Stop** cancels and removes the partial file. A download that makes no progress for 60 seconds stops with a **Retry** button.
5. Drag the finished card into ProPresenter. A video or audio card hands over the file itself.

- **Compatibility:** nothing is re-encoded. The download picks a version that plays in ProPresenter as it comes: H.264 where there is one (YouTube has it up to 1080p), otherwise VP9, which is all YouTube offers at 1440p and 4K. AV1 is avoided, since Macs before the M3 can't play it, and so is HDR. Sound is AAC where the site offers it, otherwise the site's own. Other containers, such as WebM, are repackaged as MP4 without re-encoding. MP3 is 320 kbps.
- **Not supported:** playlists and channels (a link like `watch?v=…&list=…` downloads just that video), live streams, Intel Macs, and videos that need a login or cookies, such as private, age-restricted or some Instagram and Facebook videos. These say so rather than failing silently.
- **Log:** every run of the tools is written to `~/Documents/ProSlide Beta/Logs/downloads.log` (kept to about 1 MB). Click **Show Download Log** at the bottom of the Downloader, or right-click a download card, to find it, for example to send when something stalls.
- **Tools:** `yt-dlp` fetches, `ffmpeg` merges video and sound and makes MP3s, and Deno lets `yt-dlp` read YouTube. They are downloaded when you build the app, pinned to stable releases in `Scripts/tools.lock` with SHA-256 checksums, and kept in `ProSlide Beta.app/Contents/Resources/Tools` with their licenses in `THIRD_PARTY_NOTICES.txt`. They are Apple Silicon builds. `./Scripts/make-app-bundle.sh --no-tools` skips them.
- **Updating the tools:** run `Scripts/update-tools.sh` to print the newest stable versions and checksums, compare them with each project's release page, and change `tools.lock` in a pull request. Stable `yt-dlp` releases can lag behind YouTube changes, so a site that stops working may need a newer release.
- **Rights:** only download videos you own or have permission to use. YouTube's terms don't allow downloading, and `yt-dlp` and `ffmpeg` are GPL programs; if you give a built app to other people, include their licenses and sources, as the notices file points out.

### Still to come
- **Lyrics Formatter:** format lyrics with ease so they import into ProPresenter quickly.

### Installing the beta
The beta is a separate app, **ProSlide Beta**, with its own bundle ID (`com.v3ndsxg.proslide.beta`), an orange icon marked BETA, and its own folder at `~/Documents/ProSlide Beta/`. It installs beside the production app and never reads or changes its decks.

```
git clone --branch beta --single-branch https://github.com/v3ndsxg/ProSlide.git ProSlide-beta
cd ProSlide-beta
./Scripts/make-app-bundle.sh --install
open "/Applications/ProSlide Beta.app"
```

Pull and rerun the script to update. On the `beta` branch the script builds the beta by default; `--stable` builds the production app from the same checkout. The values live in `Scripts/make-app-bundle.sh`, and the app reads them from its Info.plist (`AppIdentity.swift`).

Longer term: a Rust core for batch queuing and image processing, and PowerPoint automation as an optional renderer for closer Office fidelity. PDFKit and LibreOffice stay as the renderers.

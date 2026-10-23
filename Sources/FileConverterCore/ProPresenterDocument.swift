import Foundation

/// Builds the `rv.data.Presentation` message that ProPresenter 7 and later
/// expects to find in a `.pro` file.
///
/// A presentation is a flat list of *cues*, one per slide, plus *cue groups*
/// that give the slide list its order in the UI. Each cue holds two actions:
/// an empty slide canvas and a foreground media action pointing at the image.
///
/// The field numbers and enum values below are not guesses. They were checked
/// against the community-reverse-engineered `.proto` schema and are pinned
/// against a recording of a real ProPresenter file in `ProPresenterPackageTests`.
/// The schema is unsupported by Renewed Vision, so it is pinned deliberately:
/// emit the smallest set that ProPresenter demonstrably reads, and change nothing
/// without a new sample to check against.
enum ProPresenterDocument {

    // MARK: - Schema constants

    // rv.data.ApplicationInfo
    private enum Platform: UInt64 { case macOS = 1 }
    private enum Application: UInt64 { case proPresenter = 1 }

    // rv.data.Action
    //
    // `media` is deliberately absent even though the schema defines it: a real
    // presentation has no media actions at all. Images are elements inside the
    // presentation-slide action instead.
    private enum ActionType: UInt64 { case presentationSlide = 11 }

    // rv.data.AlphaType
    private enum AlphaType: UInt64 { case straight = 1 }

    // rv.data.Cue
    private enum CompletionActionType: UInt64 { case last = 1 }

    // rv.data.URL.LocalRelativePath.Root
    private enum Root {
        /// Resolved against ProPresenter's own document root — the folder
        /// holding `Libraries`, `Media` and `Configuration`. This is the only
        /// root any real ProPresenter file uses: `Fixtures/real.pro` records
        /// `root: 10` on all 82 of its media URLs.
        ///
        /// ProSlide can use it because it stages its decks into that root first,
        /// so the path it writes is `Media/Imported/…` like the recording rather
        /// than a `..` climb out to where the bin happens to live.
        static let show: UInt64 = 10

        /// `ROOT_SHARED`. Unused: it names a shared location ProPresenter
        /// defines, and nothing ProSlide needs lives there.
        static let shared: UInt64 = 9

        /// `ROOT_CURRENT_RESOURCE`: resolved against the bundle being imported.
        /// Meaningful for a `.probundle`, which carries its media inside the
        /// archive; a bare `.pro` has no bundle, so it points at nothing.
        static let currentResource: UInt64 = 12
    }

    // rv.data.Media.Metadata
    private enum ColorFormat: UInt64 { case sdr = 1 }

    /// ProPresenter records JPEG in uppercase in a standalone `.pro`, which is
    /// what `Fixtures/real.pro` shows. (Its own bundles record it lowercase, so
    /// the two forms genuinely differ.)
    private static let jpegFormatIdentifier = "JPG"

    /// Measured at roughly 700 bytes per slide, so this keeps a full 300-page deck
    /// to a single allocation.
    private static let estimatedSlideByteCount = 1024

    // MARK: - Entry point

    /// Serialises the manifest for a presentation named `name` holding `slides`, in
    /// order.
    ///
    /// Each slide's media is named by a path relative to `showRoot` — ProPresenter's
    /// own document root — because that is the only root a real ProPresenter file
    /// uses. `slides` are therefore expected to name their images *inside* that
    /// root, which is where the packager links them; the writer itself touches no
    /// files. Injectable so the tests can assert exact paths instead of depending
    /// on the account running them.
    static func encode(
        name: String,
        slides: [ProSlide],
        showRoot: URL = ProPresenterInstallation.defaultDocumentRoot
    ) -> Data {
        var document = ProtoWriter(reservingCapacity: slides.count * estimatedSlideByteCount)

        document.message(1) { applicationInfo in
            // Only platform and application. ProPresenter also writes
            // platform_version (2) and application_version (4), and the author of
            // the published schema marked both required — but omitting them is
            // deliberate. There is no honest version number to put there:
            // ProSlide is not ProPresenter, and inventing one risks tripping
            // version-gated behaviour. ProPresenter opens the file without them.
            applicationInfo.uint(1, Platform.macOS.rawValue)
            applicationInfo.uint(3, Application.proPresenter.rawValue)
        }
        let documentUUID = newUUID()
        document.message(2) { $0.string(1, documentUUID) }
        document.string(3, name)

        // ProPresenter writes a transparent background here, leaving the colour
        // channels at zero. Our slides are full-canvas page renders, so nothing
        // shows through either way.
        document.message(8) { background in
            background.message(1) { $0.float(4, 1) }
        }
        document.message(9) { url in
            url.uint(3, Platform.macOS.rawValue)
        }

        // Cue identifiers are minted once, up front, and shared by the cue and
        // the group that lists it. The group names its cues by identifier, so
        // two independent sets of identifiers leave the group pointing at cues
        // that do not exist and the deck has no readable order.
        let cueUUIDs = slides.map { _ in newUUID() }
        for (slide, cueUUID) in zip(slides, cueUUIDs) {
            document.data(13, cue(for: slide, uuid: cueUUID, showRoot: showRoot))
        }

        // One group holding every cue, in document order.
        //
        // No arrangement and no `selected_arrangement`. Those were an earlier
        // inference of mine and they are wrong: `Fixtures/real.pro`, exported by
        // ProPresenter itself, records neither. A single flat group is what a
        // simple deck looks like.
        document.data(12, cueGroup(for: cueUUIDs))

        return document.data
    }

    // MARK: - Cues

    private static func cue(for slide: ProSlide, uuid: String, showRoot: URL) -> Data {
        var cue = ProtoWriter()
        cue.message(1) { $0.string(1, uuid) }
        cue.uint(5, CompletionActionType.last.rawValue)
        cue.message(8) { _ in }
        cue.data(10, slideAction(for: slide, showRoot: showRoot))
        cue.bool(12, true)
        return cue.data
    }

    /// One cue carries exactly **one** action: a presentation slide with the image
    /// nested inside its base slide.
    ///
    /// This is the single most important structural fact about the format, and I
    /// had it wrong for a long time. Earlier versions of this writer emitted two
    /// actions per cue — a blank canvas plus a separate `ACTION_TYPE_MEDIA` —
    /// which reads plausibly and even produced valid protobuf, but no
    /// ProPresenter-written file contains a media action at all: `real.pro` has 41
    /// cues and 41 presentation-slide actions, and zero media actions. The image
    /// hangs off the slide at `10.23.2.1.1.1.9.3.2`, which is the path walked below.
    private static func slideAction(for slide: ProSlide, showRoot: URL) -> Data {
        let location = mediaLocation(for: slide, showRoot: showRoot)
        var action = ProtoWriter()
        action.message(1) { uuid in uuid.string(1, newUUID()) }
        action.bool(6, true)
        action.uint(9, ActionType.presentationSlide.rawValue)
        action.message(23) { slideType in
            slideType.message(2) { presentationSlide in
                presentationSlide.message(1) { baseSlide in
                    // base_slide.elements -> element -> graphics -> fill -> media -> the URL
                    baseSlide.message(1) { element in
                        element.message(1) { graphics in
                            graphics.message(1) { uuid in uuid.string(1, newUUID()) }
                            // `Graphics.Element.bounds` — the rectangle on the
                            // canvas this element is drawn into. It is the only
                            // thing that says *where* the image goes. Omit it and
                            // the element has no extent: the media still resolves,
                            // so ProPresenter reports nothing wrong, and it
                            // renders an empty slide showing only the background.
                            // `real.pro` records the slide's own dimensions here.
                            graphics.message(3) { bounds in rect(&bounds, slide.pixelSize) }
                            graphics.double(5, 1.0)  // opacity
                            // `Graphics.Path`: the outline the fill is painted
                            // inside. Bounds say how big the element is; the path
                            // says what shape it is. An element with no path has
                            // nothing to fill, so the image resolves, nothing warns,
                            // and the slide is blank. Every element in `real.pro`
                            // has one, and for a full-slide image it is the unit
                            // rectangle.
                            graphics.message(8) { path in unitRectanglePath(&path) }
                            // `Graphics.Fill`, whose `media` field is the image.
                            graphics.message(9) { fill in
                                fill.message(3) { mediaElement in
                                    mediaElement.message(1) { uuid in uuid.string(1, newUUID()) }
                                    mediaElement.message(2) { url in location.write(to: &url) }
                                    mediaElement.message(3) { metadata in
                                        metadata.string(5, jpegFormatIdentifier)
                                        metadata.uint(6, ColorFormat.sdr.rawValue)
                                    }
                                    mediaElement.message(5) { elementType in
                                        elementType.message(1) { drawing in
                                            drawing.message(5) { natural in size(&natural, slide.pixelSize) }
                                            // `custom_image_bounds`: an override for when the image
                                            // has deliberately been placed and cropped by hand.
                                            // Left empty — as `real.pro` leaves it — the
                                            // element's own bounds govern where the image
                                            // is drawn, which is the field above.
                                            drawing.message(7) { custom in
                                                custom.message(1) { origin in _ = origin }
                                                custom.message(2) { extent in _ = extent }
                                            }
                                            drawing.message(14) { crop in _ = crop }
                                            drawing.uint(15, AlphaType.straight.rawValue)
                                        }
                                        // The same URL a second time, as
                                        // `image.file.localUrl`. ProPresenter
                                        // reads both and they have to agree.
                                        elementType.message(2) { file in
                                            file.message(1) { localURL in location.write(to: &localURL) }
                                        }
                                    }
                                }
                                fill.uint(4, 1)  // Fill.enable
                            }
                            // Stroke, shadow and feather, as `real.pro` records them
                            // on every element. All three are disabled (their enable
                            // flags are unset), so they draw nothing; they are
                            // written so the element looks like ProPresenter's own.
                            graphics.message(10) { stroke in
                                stroke.double(2, 3.0)
                                stroke.message(3) { color in
                                    color.float(1, 1); color.float(2, 1); color.float(3, 1); color.float(4, 1)
                                }
                            }
                            graphics.message(11) { shadow in
                                shadow.double(2, 315.0)
                                shadow.double(3, 5.0)
                                shadow.double(4, 5.0)
                                shadow.message(5) { color in color.float(4, 1) }
                                shadow.double(6, 0.75)
                            }
                            graphics.message(12) { feather in feather.double(2, 0.05) }
                        }
                    }
                    baseSlide.uint(4, 1)  // draws_background
                    baseSlide.message(5) { background in
                        background.float(4, 1)  // opaque black
                    }
                    baseSlide.message(6) { canvas in size(&canvas, slide.pixelSize) }
                    baseSlide.message(7) { canvasUUID in canvasUUID.string(1, newUUID()) }
                }
                presentationSlide.message(4) { chordChart in
                    chordChart.uint(3, Platform.macOS.rawValue)
                }
            }
        }
        return action.data
    }

    /// Where ProPresenter should look for one slide's image: a path and the root
    /// that path is relative to.
    ///
    /// `absoluteString` is the full `file://` URL, because that is what
    /// `real.pro` records for all 82 of its media URLs — not a
    /// percent-encoded fragment.
    private struct MediaLocation {
        let path: String
        let root: UInt64
        let absoluteString: String

        func write(to writer: inout ProtoWriter) {
            writer.string(1, absoluteString)
            writer.uint(3, Platform.macOS.rawValue)
            writer.message(4) { local in
                local.uint(1, root)
                local.string(2, path)
            }
        }
    }

    /// `slide`'s image, named the way `real.pro` names its own: relative to
    /// ProPresenter's document root, with the absolute URL alongside it.
    ///
    /// The packager has already linked the image into that root, so this is
    /// normally `Media/Imported/…` — the shape every real presentation
    /// records, and the one ProPresenter is known to resolve.
    private static func mediaLocation(for slide: ProSlide, showRoot: URL) -> MediaLocation {
        MediaLocation(
            path: relativePath(of: slide.imageURL, from: showRoot)
                ?? slide.imageURL.lastPathComponent,
            root: Root.show,
            absoluteString: slide.imageURL.standardizedFileURL.absoluteString
        )
    }

    /// `url` expressed relative to `root`, allowing `..` to climb out of it.
    ///
    /// ProPresenter's own files never climb: their media sits in `Media` under
    /// the document root, and the packager puts ProSlide's there too. The
    /// climbing ability is only kept so a deck staged elsewhere still produces
    /// a path rather than a bare filename.
    ///
    /// Returns nil only when the two paths share no common ancestor that can be
    /// climbed to, which means they are on different volumes.
    static func relativePath(of url: URL, from root: URL) -> String? {
        let target = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let base = root.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let shared = zip(base, target).prefix { $0 == $1 }.count
        // A path cannot climb above the filesystem root, so a relative path
        // between two absolute paths on one volume always exists.
        guard shared <= min(base.count, target.count) else { return nil }
        let climbs = Array(repeating: "..", count: base.count - shared)
        let descent = target[shared...]
        let combined = climbs + descent
        guard !combined.isEmpty else { return "." }
        return combined.joined(separator: "/")
    }

    /// Every slide in one group, in document order.
    ///
    /// `cueUUIDs` are the same identifiers the cues carry in their own field 1.
    /// A group whose identifiers do not match the cues leaves ProPresenter with
    /// no readable order, so these must be the identical strings.
    private static func cueGroup(for cueUUIDs: [String]) -> Data {
        var group = ProtoWriter()
        group.message(1) { inner in
            inner.message(1) { identifier in identifier.string(1, newUUID()) }
            inner.message(4) { hotKey in _ = hotKey }
        }
        for cueUUID in cueUUIDs {
            group.message(2) { identifier in identifier.string(1, cueUUID) }
        }
        return group.data
    }

    // MARK: - Shared fragments

    private static func size(_ writer: inout ProtoWriter, _ pixels: PixelSize) {
        writer.double(1, Double(pixels.width))
        writer.double(2, Double(pixels.height))
    }

    /// `Graphics.Rect`: the rectangle on the canvas an element is drawn into.
    ///
    /// The origin is left empty because proto3 keeps an all-zero point off the
    /// wire, which is exactly what `real.pro` records — origin absent, size the
    /// slide's own dimensions.
    private static func rect(_ writer: inout ProtoWriter, _ pixels: PixelSize) {
        writer.message(1) { origin in _ = origin }
        writer.message(2) { extent in size(&extent, pixels) }
    }

    /// `Graphics.Path`: a closed rectangle over the unit square, with the shape
    /// marked as a rectangle — the same four points `real.pro` records. Points
    /// are normalised to the element's bounds. Zero coordinates stay off the wire
    /// (proto3), so (0,0) is an empty point and the others carry only their
    /// non-zero axis.
    private static func unitRectanglePath(_ path: inout ProtoWriter) {
        path.bool(1, true)  // closed
        for (x, y) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] {
            path.message(2) { point in
                // BezierPoint: the point and its two control handles, all equal.
                for field in 1...3 {
                    point.message(field) { coordinate in
                        if x != 0 { coordinate.double(1, x) }
                        if y != 0 { coordinate.double(2, y) }
                    }
                }
            }
        }
        path.message(3) { shape in shape.uint(1, 1) }  // TYPE_RECTANGLE
    }

    private static func newUUID() -> String {
        UUID().uuidString.uppercased()
    }
}

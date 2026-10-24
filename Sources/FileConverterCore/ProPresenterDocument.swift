import Foundation

/// Builds the `rv.data.Presentation` message that goes inside a `.probundle`
/// as `<Name>.pro`.
///
/// A presentation is a flat list of *cues*, one per slide, plus a *cue group*
/// that gives the slide list its order in the UI. Each cue holds two actions:
/// an empty presentation slide, and a **foreground media action** carrying the
/// image. A media action rather than an image element on the slide, because
/// ProPresenter can turn a media cue into a slide element but not the reverse.
///
/// The shape is copied from a presentation ProPresenter itself re-exported as a
/// bundle (a workspace-era build, October 2026), and the exact bytes this
/// writes were imported successfully with media management both on and off.
/// The schema is community-reverse-engineered and unsupported by Renewed
/// Vision, so the rule is: write what that import accepted, and change nothing
/// without a new import to check against.
///
/// Deliberately absent, though ProPresenter's own export has them:
///
/// - Application info (field 1). ProPresenter's workspace builds drop it from
///   their own exports too.
/// - `content_destination` (19). Copying it from an announcements deck sent the
///   test presentation to the announcements layer.
/// - Notes (7) and the timeline (17), which belong to the deck it was copied from.
/// - A duration on the media action, so ProPresenter applies its own.
/// - The media asset identifier (media field 10) and field 11, which ProPresenter
///   assigns on import.
enum ProPresenterDocument {

    // MARK: - Schema constants

    // rv.data.Action.ActionType
    private enum ActionType: UInt64 {
        case media = 2
        case presentationSlide = 11
    }

    // rv.data.Action.LayerType. Background is 0, and proto3 would leave it off
    // the wire entirely.
    private enum LayerType: UInt64 { case foreground = 1 }

    // rv.data.Cue
    private enum CompletionActionType: UInt64 { case last = 1 }

    /// `rv.data.URL.LocalRelativePath.Root.ROOT_SHOW`. Inside a bundle it is
    /// resolved against the bundle itself; on import ProPresenter copies the
    /// file into its own media store and re-roots it there.
    private static let showRoot: UInt64 = 10

    /// The folder images live in inside a bundle, and in ProPresenter's store.
    static let mediaFolder = "Media/Assets"

    // rv.data.Media.Metadata
    private enum ColorFormat: UInt64 { case sdr = 1 }

    /// `DrawingProperties.scale_behavior`: scale to fill, which is what the
    /// imported slides showed.
    private static let scaleToFill: UInt64 = 1

    // rv.data.AlphaType
    private enum AlphaType: UInt64 { case straight = 1 }

    /// Measured at roughly 600 bytes per slide, so this keeps a full 300-page deck
    /// to a single allocation.
    private static let estimatedSlideByteCount = 1024

    // MARK: - Entry point

    /// Serialises the manifest for a presentation named `name` holding `slides`, in
    /// order.
    ///
    /// Each slide's image is named by `mediaPath(for:)`, so the bundle must
    /// store the image there; the writer itself touches no files.
    static func encode(name: String, slides: [ProSlide]) -> Data {
        var document = ProtoWriter(reservingCapacity: slides.count * estimatedSlideByteCount)

        document.message(2) { $0.string(1, newUUID()) }
        document.string(3, name)

        // ProPresenter writes a transparent background here, leaving the colour
        // channels at zero. Every slide is covered by its image either way.
        document.message(8) { background in
            background.message(1) { $0.float(4, 1) }
        }

        // Cue identifiers are minted once, up front, and shared by the cue and
        // the group that lists it. The group names its cues by identifier, so
        // two independent sets of identifiers leave the group pointing at cues
        // that do not exist and the deck has no readable order.
        let cueUUIDs = slides.map { _ in newUUID() }
        document.data(12, cueGroup(for: cueUUIDs))
        for (slide, cueUUID) in zip(slides, cueUUIDs) {
            document.data(13, cue(for: slide, uuid: cueUUID))
        }
        return document.data
    }

    /// Where `fileName` lives inside a bundle, and so how the manifest names it.
    static func mediaPath(for fileName: String) -> String {
        "\(mediaFolder)/\(fileName)"
    }

    // MARK: - Cues

    private static func cue(for slide: ProSlide, uuid: String) -> Data {
        var cue = ProtoWriter()
        cue.message(1) { $0.string(1, uuid) }
        cue.string(2, slide.label)
        cue.uint(5, CompletionActionType.last.rawValue)
        cue.message(8) { _ in }
        cue.data(10, slideAction(for: slide))
        cue.data(10, mediaAction(for: slide))
        cue.bool(12, true)  // enabled
        return cue.data
    }

    /// The empty presentation slide every cue starts with: the canvas and
    /// nothing on it. The image is the media action that follows.
    private static func slideAction(for slide: ProSlide) -> Data {
        var action = ProtoWriter()
        action.message(1) { $0.string(1, newUUID()) }
        action.message(3) { label in label.string(2, slide.label) }
        action.bool(6, true)  // enabled
        action.uint(9, ActionType.presentationSlide.rawValue)
        action.message(23) { slideType in
            slideType.message(2) { presentationSlide in
                presentationSlide.message(1) { baseSlide in
                    baseSlide.message(6) { canvas in size(&canvas, slide.pixelSize) }
                    baseSlide.message(7) { canvasUUID in canvasUUID.string(1, newUUID()) }
                }
            }
        }
        return action.data
    }

    /// The image, as a foreground media action.
    private static func mediaAction(for slide: ProSlide) -> Data {
        let path = mediaPath(for: slide.imageURL.lastPathComponent)
        var action = ProtoWriter()
        action.message(1) { $0.string(1, newUUID()) }
        action.bool(6, true)  // enabled
        action.uint(9, ActionType.media.rawValue)
        action.message(20) { media in
            media.message(5) { element in
                element.message(1) { $0.string(1, newUUID()) }
                element.message(2) { url in localURL(&url, path) }
                element.message(3) { metadata in
                    metadata.string(5, slide.imageURL.pathExtension)
                    metadata.uint(6, ColorFormat.sdr.rawValue)
                }
                element.message(5) { image in
                    image.message(1) { drawing in
                        drawing.uint(1, scaleToFill)
                        drawing.message(5) { natural in size(&natural, slide.pixelSize) }
                        // `custom_image_bounds`, left empty so the image fills
                        // the canvas rather than a hand-placed rectangle.
                        drawing.message(7) { custom in
                            custom.message(1) { _ in }
                            custom.message(2) { _ in }
                        }
                        drawing.message(14) { _ in }  // crop insets: none
                        drawing.uint(15, AlphaType.straight.rawValue)
                    }
                    // The same location a second time, as `image.file.local_url`.
                    // ProPresenter writes both and they have to agree.
                    image.message(2) { file in
                        file.message(1) { url in localURL(&url, path) }
                    }
                }
            }
            // The empty marker ProPresenter writes for an image here. The
            // published schema calls field 8 `audio`; what matters is that
            // ProPresenter's own exports carry it.
            media.message(8) { _ in }
            media.uint(10, LayerType.foreground.rawValue)
        }
        return action.data
    }

    /// `rv.data.URL` naming `path` inside the bundle: the relative path and its
    /// root, and nothing else. No absolute `file://` string and no platform —
    /// those would name a file on the machine that built the bundle.
    private static func localURL(_ url: inout ProtoWriter, _ path: String) {
        url.message(4) { local in
            local.uint(1, showRoot)
            local.string(2, path)
        }
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
            inner.message(4) { _ in }
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

    private static func newUUID() -> String {
        UUID().uuidString.uppercased()
    }
}

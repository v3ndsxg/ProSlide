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
    private enum ActionType: UInt64 { case media = 2, presentationSlide = 11 }
    private enum LayerType: UInt64 { case foreground = 1 }

    // rv.data.Cue
    private enum CompletionActionType: UInt64 { case last = 1 }

    // rv.data.URL.LocalRelativePath.Root
    private enum Root {
        /// Resolved by ProPresenter against the resource the `.pro` itself sits
        /// in. For a standalone `.pro` that is the folder holding it, which is
        /// where `ProPresenterPackage` writes the deck's JPEGs.
        static let currentResource: UInt64 = 12
    }

    // rv.data.Media.Metadata
    private enum ColorFormat: UInt64 { case sdr = 1 }

    /// ProPresenter records JPEG in uppercase in a standalone `.pro`, which is
    /// what `Fixtures/reference.pro` shows. (Its own bundles record it
    /// lowercase, so the two forms genuinely differ.)
    private static let jpegFormatIdentifier = "JPG"

    /// Measured at roughly 700 bytes per slide, so this keeps a full 300-page deck
    /// to a single allocation.
    private static let estimatedSlideByteCount = 1024

    // MARK: - Entry point

    /// Serialises the manifest for a presentation named `name` holding `slides`, in
    /// order.
    ///
    /// Each slide's media is referenced by bare filename against
    /// `ROOT_CURRENT_RESOURCE`, which ProPresenter resolves against the folder
    /// containing the `.pro`.
    static func encode(name: String, slides: [ProSlide]) -> Data {
        var document = ProtoWriter(reservingCapacity: slides.count * estimatedSlideByteCount)

        document.message(1) { applicationInfo in
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
            document.data(13, cue(for: slide, uuid: cueUUID))
        }

        // One group holding every cue, in order, wrapped in one arrangement that
        // collects it. The arrangement is what `selected_arrangement` below
        // points at, and between them they are what gives the deck its sequence
        // and its name in ProPresenter's slide list. Without a selected
        // arrangement ProPresenter has nothing to show.
        let groupUUID = newUUID()
        document.data(12, cueGroup(for: cueUUIDs, groupUUID: groupUUID))

        let arrangementUUID = newUUID()
        document.message(11) { arrangement in
            arrangement.message(1) { $0.string(1, arrangementUUID) }
            arrangement.string(2, name)
            arrangement.message(3) { $0.string(1, groupUUID) }
        }
        document.message(10) { selectedArrangement in
            selectedArrangement.string(1, arrangementUUID)
        }

        return document.data
    }

    // MARK: - Cues

    private static func cue(for slide: ProSlide, uuid: String) -> Data {
        var cue = ProtoWriter()
        cue.message(1) { $0.string(1, uuid) }
        cue.string(2, slide.label)
        cue.uint(5, CompletionActionType.last.rawValue)
        cue.message(8) { _ in }
        cue.data(10, canvasAction(for: slide))
        cue.data(10, mediaAction(for: slide))
        cue.bool(12, true)
        return cue.data
    }

    /// The blank canvas the media is composited over. ProPresenter pairs one of
    /// these with every media action, so a deck is really "empty slide, then
    /// image on top of it".
    private static func canvasAction(for slide: ProSlide) -> Data {
        var action = ProtoWriter()
        action.message(1) { uuid in uuid.string(1, newUUID()) }
        action.message(3) { label in label.string(2, slide.label) }
        action.bool(6, true)
        action.uint(9, ActionType.presentationSlide.rawValue)
        action.message(23) { slideType in
            slideType.message(2) { presentationSlide in
                presentationSlide.message(1) { baseSlide in
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

    private static func mediaAction(for slide: ProSlide) -> Data {
        var action = ProtoWriter()
        action.message(1) { uuid in uuid.string(1, newUUID()) }
        action.bool(6, true)
        action.uint(9, ActionType.media.rawValue)
        action.message(20) { media in
            media.message(5) { element in
                element.message(1) { uuid in uuid.string(1, newUUID()) }
                element.message(2) { url in writeURL(&url, filename: slide.imageURL.lastPathComponent) }
                element.message(3) { metadata in
                    metadata.string(5, jpegFormatIdentifier)
                    metadata.uint(6, ColorFormat.sdr.rawValue)
                }
                element.message(5) { type in
                    type.message(1) { drawing in
                        drawing.message(5) { natural in size(&natural, slide.pixelSize) }
                        // An all-zero origin and size tells ProPresenter to fit
                        // the image to the canvas itself.
                        drawing.message(7) { bounds in
                            bounds.message(1) { origin in
                                origin.double(1, 0)
                                origin.double(2, 0)
                            }
                            bounds.message(2) { boundsSize in
                                size(&boundsSize, PixelSize(width: 0, height: 0))
                            }
                        }
                        drawing.message(14) { crop in _ = crop }
                        drawing.uint(15, 1)  // alpha_type: straight
                        drawing.bool(16, true)
                    }
                    type.message(2) { file in
                        file.message(1) { localURL in writeURL(&localURL, filename: slide.imageURL.lastPathComponent) }
                    }
                }
            }
            media.message(8) { audio in _ = audio }
            media.uint(10, LayerType.foreground.rawValue)
        }
        return action.data
    }

    /// Every slide in one group, in order, which is what gives the deck its
    /// order in ProPresenter's slide list.
    ///
    /// The group needs a stable UUID of its own because the arrangement
    /// references it by identifier; ProPresenter cannot resolve an arrangement
    /// whose `group_identifiers` point at a UUID nothing else carries.
    ///
    /// `cueUUIDs` are the same identifiers the cues carry in their own field 1,
    /// in the order the cues appear in the document.
    private static func cueGroup(for cueUUIDs: [String], groupUUID: String) -> Data {
        var group = ProtoWriter()
        group.message(1) { inner in
            inner.message(1) { identifier in identifier.string(1, groupUUID) }
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

    /// Writes the URL for one slide's media.
    ///
    /// The `.pro` is written into the same folder as the images it points at, so
    /// both halves of the URL are the bare filename: `absolute_string` is the
    /// percent-encoded form ProPresenter displays, and the `local` path names the
    /// same file against `ROOT_CURRENT_RESOURCE`, which resolves against the
    /// folder holding the `.pro`.
    ///
    /// Percent-encoding is not cosmetic. A deck called `Sermon Notes 2026` gives
    /// an image `Sermon Notes 2026-001.jpg`, and an unescaped space in
    /// `absolute_string` stops the URL resolving. `Fixtures/reference.pro`
    /// records the encoded form — `Pictures/5ways%20to%20give.jpg`.
    ///
    /// `ROOT_SHOW` (10) is deliberately *not* used. It looks like the natural
    /// choice — it is named "show", and one third-party encoder uses it — but it
    /// points at ProPresenter's own library directory, not at the document.
    private static func writeURL(_ writer: inout ProtoWriter, filename: String) {
        writer.string(1, percentEncoded(filename))
        writer.uint(3, Platform.macOS.rawValue)
        writer.message(4) { local in
            local.uint(1, Root.currentResource)
            local.string(2, filename)
        }
    }

    private static func newUUID() -> String {
        UUID().uuidString.uppercased()
    }

    /// Percent-encodes the characters that are not allowed unescaped in the
    /// path component of a URL.
    ///
    /// Anything outside the allowed set is escaped as its UTF-8 bytes, one
    /// `%XX` per byte. Escaping a *character* would be wrong: a filename like
    /// `Ünïcode.jpg` is two bytes per accented letter in UTF-8, and both have to
    /// be written out or ProPresenter decodes something else entirely.
    static func percentEncoded(_ name: String) -> String {
        var allowed = Set<Character>()
        allowed.formUnion("abcdefghijklmnopqrstuvwxyz")
        allowed.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        allowed.formUnion("0123456789")
        allowed.formUnion("-._~!$&'()*+,;=:@/")

        var encoded = ""
        for character in name {
            if allowed.contains(character) {
                encoded.append(character)
            } else {
                for byte in String(character).utf8 {
                    encoded += String(format: "%%%02X", byte)
                }
            }
        }
        return encoded
    }
}
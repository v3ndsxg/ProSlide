import Foundation

/// Builds the `rv.data.Presentation` message that ProPresenter 7 and later
/// expects to find in a `.pro` file, and that sits at the root of a
/// `.probundle`.
///
/// A presentation is a flat list of *cues*, one per slide, plus *cue groups*
/// that give the slide list its order in the UI. Each cue holds two actions:
/// an empty slide canvas and a foreground media action pointing at the image.
///
/// The field numbers and enum values below are not guesses. They were read out
/// of a presentation ProPresenter wrote itself, and
/// `ProPresenterPackageTests` re-reads a recording of that file to keep them
/// honest. The schema is community-reverse-engineered and unsupported by Renewed
/// Vision, so it is pinned deliberately: emit the smallest set that ProPresenter
/// demonstrably reads, and change nothing without a new sample to check against.
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

    // rv.data.Media.Metadata
    private enum ColorFormat: UInt64 { case sdr = 1 }

    /// ProPresenter writes the uppercase form for JPEG and lowercase for PNG,
    /// so this matches what it wrote for a `.jpg`.
    private static let jpegFormatIdentifier = "JPG"

    /// Measured at roughly 700 bytes per slide, so this keeps a full 300-page deck
    /// to a single allocation.
    private static let estimatedSlideByteCount = 1024

    // MARK: - Entry point

    /// Serialises a presentation named `name` holding `slides`, in order.
    ///
    /// Each slide carries its own `MediaReference`, so the same call produces
    /// both a bundled and an unbundled manifest; only the references differ.
    static func encode(name: String, slides: [ProSlide]) -> Data {
        var document = ProtoWriter(reservingCapacity: slides.count * estimatedSlideByteCount)

        document.message(1) { applicationInfo in
            applicationInfo.uint(1, Platform.macOS.rawValue)
            applicationInfo.uint(3, Application.proPresenter.rawValue)
        }
        document.message(2) { $0.string(1, newUUID()) }
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

        for slide in slides {
            document.data(13, cue(for: slide))
        }
        document.data(12, cueGroup(for: slides.count))

        return document.data
    }

    // MARK: - Cues

    private static func cue(for slide: ProSlide) -> Data {
        var cue = ProtoWriter()
        cue.message(1) { $0.string(1, newUUID()) }
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
                element.message(2) { url in writeURL(&url, slide.reference) }
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
                        file.message(1) { localURL in writeURL(&localURL, slide.reference) }
                    }
                }
            }
            media.message(8) { audio in _ = audio }
            media.uint(10, LayerType.foreground.rawValue)
        }
        return action.data
    }

    /// Every slide in one group, which is what gives the deck its order in
    /// ProPresenter's slide list.
    private static func cueGroup(for slideCount: Int) -> Data {
        var group = ProtoWriter()
        group.message(1) { inner in
            inner.message(1) { groupUUID in groupUUID.string(1, newUUID()) }
            inner.message(4) { hotKey in _ = hotKey }
        }
        for _ in 0..<slideCount {
            group.message(2) { identifier in identifier.string(1, newUUID()) }
        }
        return group.data
    }

    // MARK: - Shared fragments

    private static func size(_ writer: inout ProtoWriter, _ pixels: PixelSize) {
        writer.double(1, Double(pixels.width))
        writer.double(2, Double(pixels.height))
    }

    private static func writeURL(_ writer: inout ProtoWriter, _ reference: MediaReference) {
        writer.string(1, reference.absoluteString)
        writer.uint(3, Platform.macOS.rawValue)
        writer.message(4) { local in
            local.uint(1, reference.root)
            local.string(2, reference.path)
        }
    }

    private static func newUUID() -> String {
        UUID().uuidString.uppercased()
    }

    /// Percent-encodes the characters that are not allowed unescaped in the
    /// path component of a URL.
    static func percentEncoded(_ name: String) -> String {
        var allowed = Set<Character>()
        allowed.formUnion("abcdefghijklmnopqrstuvwxyz")
        allowed.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        allowed.formUnion("0123456789")
        allowed.formUnion("-._~!$&'()*+,;=:@/")
        return name
            .map { allowed.contains($0) ? String($0) : String(format: "%%%02X", $0.asciiValue ?? 0) }
            .joined()
    }
}
@testable import FileConverterCore
import XCTest

final class DownloaderStyleTests: XCTestCase {

    private func info(_ height: Int?) -> VideoInfo {
        VideoInfo(title: "t", duration: nil, maxHeight: height, isLive: false)
    }

    func testFourKIsRedAndFourteenFortyYellowWhenNoLinkOffersThem() {
        let hd = [info(1080)]
        let fourK = QualityAdvice.make(selected: .p2160, infos: hd)
        XCTAssertEqual(fourK.severity, .error)
        XCTAssertTrue(fourK.text.contains("4K"))

        let fourteenForty = QualityAdvice.make(selected: .p1440, infos: hd)
        XCTAssertEqual(fourteenForty.severity, .warning)
        XCTAssertTrue(fourteenForty.text.contains("1440p"))
    }

    func testNoWarningWhenTheChosenQualityIsOffered() {
        XCTAssertEqual(QualityAdvice.make(selected: .p2160, infos: [info(1080), info(2160)]).severity, .neutral)
        XCTAssertEqual(QualityAdvice.make(selected: .p1080, infos: [info(1080)]).severity, .neutral)
    }

    func testNoWarningBeforeAnythingIsKnownOrWhenTheHeightIsUnknown() {
        XCTAssertEqual(QualityAdvice.make(selected: .p2160, infos: []).severity, .neutral)
        XCTAssertEqual(QualityAdvice.make(selected: .p2160, infos: [info(nil)]).severity, .neutral)
    }

    func testLowerQualitiesNeverShoutEvenForATinyVideo() {
        for quality in [DownloadQuality.p1080, .p720, .p480, .p360] {
            XCTAssertEqual(QualityAdvice.make(selected: quality, infos: [info(240)]).severity, .neutral, quality.title)
        }
    }

    func testBadgesNameTheSite() {
        XCTAssertEqual(SiteBadge.forHost("www.youtube.com").label, "YT")
        XCTAssertEqual(SiteBadge.forHost("m.youtube.com").label, "YT")
        XCTAssertEqual(SiteBadge.forHost("youtu.be").label, "YT")
        XCTAssertEqual(SiteBadge.forHost("vimeo.com").label, "V")
        XCTAssertEqual(SiteBadge.forHost("www.tiktok.com").label, "TT")
        XCTAssertEqual(SiteBadge.forHost("x.com").label, "X")
        XCTAssertEqual(SiteBadge.forHost("fb.watch").label, "f")
    }

    func testUnknownSitesGetTheirFirstLetterOnGrey() {
        let badge = SiteBadge.forHost("www.example.org")
        XCTAssertEqual(badge.label, "E")
        XCTAssertEqual(badge.color, 0x8E8E93)
        XCTAssertEqual(SiteBadge.forHost(nil).label, "?")
        XCTAssertEqual(SiteBadge.forHost("").label, "?")
    }

    func testALookalikeHostIsNotMistakenForARealSite() {
        XCTAssertEqual(SiteBadge.forHost("notyoutube.com").label, "N")
        XCTAssertEqual(SiteBadge.forHost("youtube.com.evil.example").label, "Y")
    }
}

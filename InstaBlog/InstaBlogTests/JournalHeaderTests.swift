import CoreGraphics
import Testing
@testable import InstaBlog

@Suite("Journal header presentation")
struct JournalHeaderTests {
    @Test("Zero scroll keeps the title expanded")
    func zeroScrollIsExpanded() {
        let presentation = JournalHeaderPresentation(scrollOffset: 0, collapseDistance: 120)

        #expect(presentation.progress == 0)
        #expect(presentation.sizeProgress == 0)
        #expect(presentation.positionProgress == 0)
    }

    @Test("A scrolled journal moves the title toward the compact state")
    func scrolledTitleIsCompact() {
        let presentation = JournalHeaderPresentation(scrollOffset: 60, collapseDistance: 120)

        #expect(presentation.progress == 0.5)
        #expect(presentation.sizeProgress == 1)
        #expect(presentation.positionProgress == 0)
    }

    @Test("The second stage moves the compact title after resizing completes")
    func positionAnimationStartsAfterSizeAnimation() {
        let presentation = JournalHeaderPresentation(scrollOffset: 90, collapseDistance: 120)

        #expect(presentation.sizeProgress == 1)
        #expect(presentation.positionProgress == 0.5)
    }
}

@Suite("Journal compact title layout")
struct JournalCompactTitleLayoutTests {
    @Test("A long title remains clear of equally reserved buttons")
    func longTitleUsesSymmetricAvailableWidth() {
        let layout = JournalCompactTitleLayout(
            containerWidth: 354,
            measuredTitleWidth: 400
        )

        #expect(layout.width == 250)
        #expect(layout.offset == 52)
        #expect(354 - layout.offset - layout.width == 52)
    }

    @Test("A short title pill is centered")
    func shortTitleIsCentered() {
        let layout = JournalCompactTitleLayout(
            containerWidth: 354,
            measuredTitleWidth: 80
        )

        #expect(layout.width == 108)
        #expect(layout.offset == 123)
        #expect(layout.offset == 354 - layout.offset - layout.width)
    }
}

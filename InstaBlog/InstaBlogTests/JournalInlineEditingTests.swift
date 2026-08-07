import Foundation
import Testing
@testable import InstaBlog

@Suite("Journal inline text editing")
struct JournalInlineEditingTests {
    @Test("No change when edited text matches original")
    func unchangedTextIsNoChange() {
        #expect(
            InlineTextEditor.commitOutcome(
                originalText: "A lovely day",
                editedText: "A lovely day",
                hasPhotos: false
            ) == .noChange
        )
    }

    @Test("Whitespace-only differences are treated as no change")
    func whitespaceOnlyIsNoChange() {
        #expect(
            InlineTextEditor.commitOutcome(
                originalText: "A lovely day",
                editedText: "  A lovely day\n",
                hasPhotos: false
            ) == .noChange
        )
    }

    @Test("Changed text is an update")
    func changedTextIsUpdate() {
        #expect(
            InlineTextEditor.commitOutcome(
                originalText: "A lovely day",
                editedText: "A lovely evening",
                hasPhotos: false
            ) == .updated
        )
    }

    @Test("Emptied text deletes a photo-less item")
    func emptiedTextDeletesPhotoLessItem() {
        #expect(
            InlineTextEditor.commitOutcome(
                originalText: "A lovely day",
                editedText: "   ",
                hasPhotos: false
            ) == .delete
        )
    }

    @Test("Emptied text keeps an item that has photos")
    func emptiedTextKeepsPhotoItem() {
        #expect(
            InlineTextEditor.commitOutcome(
                originalText: "A lovely day",
                editedText: "",
                hasPhotos: true
            ) == .updated
        )
    }
}

import Foundation
import Testing
@testable import InstaBlog

@Suite("Blog item cancel confirmation")
struct BlogItemCancelConfirmationTests {
    private static let itemDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func hasChanges(
        isNewItem: Bool = true,
        blogText: String = "",
        location: String = "",
        temperature: Double = 0,
        condition: String = "",
        currentDate: Date = itemDate,
        originalItemDate: Date = itemDate,
        didReorderPhotos: Bool = false
    ) -> Bool {
        BlogItemDetailView.hasUnsavedChanges(
            isNewItem: isNewItem,
            blogText: blogText,
            location: location,
            temperature: temperature,
            condition: condition,
            currentDate: currentDate,
            originalItemDate: originalItemDate,
            didReorderPhotos: didReorderPhotos
        )
    }

    @Test("Existing item never reports unsaved changes")
    func existingItemNeverReportsChanges() {
        #expect(hasChanges(isNewItem: false) == false)
        #expect(hasChanges(isNewItem: false, blogText: "Hello") == false)
        #expect(hasChanges(isNewItem: false, location: "Paris") == false)
        #expect(hasChanges(isNewItem: false, didReorderPhotos: true) == false)
    }

    @Test("Blank new item with no edits has no unsaved changes")
    func blankNewItemNoChanges() {
        #expect(hasChanges() == false)
    }

    @Test("Non-empty blog text counts as a change")
    func blogTextChangeDetected() {
        #expect(hasChanges(blogText: "A lovely day") == true)
        #expect(hasChanges(blogText: "   ") == false)
    }

    @Test("Non-empty location counts as a change")
    func locationChangeDetected() {
        #expect(hasChanges(location: "Paris") == true)
        #expect(hasChanges(location: "   ") == false)
    }

    @Test("Temperature above zero counts as a change")
    func temperatureChangeDetected() {
        #expect(hasChanges(temperature: 18.5) == true)
        #expect(hasChanges(temperature: 0) == false)
    }

    @Test("Weather condition string counts as a change")
    func conditionChangeDetected() {
        #expect(hasChanges(condition: "Clear") == true)
        #expect(hasChanges(condition: "") == false)
    }

    @Test("Date changed from original counts as a change")
    func dateChangeDetected() {
        let changedDate = itemDate.addingTimeInterval(3600)
        #expect(hasChanges(currentDate: changedDate) == true)
    }

    @Test("Date matching original is not a change")
    func dateUnchanged() {
        #expect(hasChanges(currentDate: itemDate) == false)
    }

    @Test("Photo reorder counts as a change")
    func photoReorderDetected() {
        #expect(hasChanges(didReorderPhotos: true) == true)
        #expect(hasChanges(didReorderPhotos: false) == false)
    }

    @Test("Only photos added (no reorder) does not trigger confirmation")
    func photosOnlyNoReorderNoChange() {
        #expect(hasChanges() == false)
    }

    @Test("Multiple simultaneous changes still report true")
    func multipleChanges() {
        #expect(
            hasChanges(
                blogText: "Hello",
                location: "London",
                temperature: 12,
                didReorderPhotos: true
            ) == true
        )
    }
}

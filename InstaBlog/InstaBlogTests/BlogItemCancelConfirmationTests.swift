import Foundation
import Testing
@testable import InstaBlog

@Suite("Blog item cancel confirmation")
struct BlogItemCancelConfirmationTests {
    private static let itemDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static let blankBaseline = BlogItemCancelBaseline(
        location: "",
        temperatureText: TemperatureText.missingValue,
        condition: "",
        date: itemDate
    )

    private static func hasChanges(
        isNewItem: Bool = true,
        blogText: String = "",
        location: String = "",
        temperatureText: String = TemperatureText.missingValue,
        condition: String = "",
        currentDate: Date = itemDate,
        baseline: BlogItemCancelBaseline = blankBaseline,
        didReorderPhotos: Bool = false,
        hasNonEmptyPhotoCaption: Bool = false
    ) -> Bool {
        BlogItemDetailView.hasUnsavedChanges(
            isNewItem: isNewItem,
            blogText: blogText,
            location: location,
            temperatureText: temperatureText,
            condition: condition,
            currentDate: currentDate,
            baseline: baseline,
            didReorderPhotos: didReorderPhotos,
            hasNonEmptyPhotoCaption: hasNonEmptyPhotoCaption
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

    @Test("Non-empty photo caption counts as a change")
    func photoCaptionChangeDetected() {
        #expect(hasChanges(hasNonEmptyPhotoCaption: true) == true)
        #expect(hasChanges(hasNonEmptyPhotoCaption: false) == false)
    }

    @Test("Entering location counts as a change")
    func locationChangeDetected() {
        #expect(hasChanges(location: "Paris") == true)
        #expect(hasChanges(location: "   ") == false)
    }

    @Test("Entering exactly 0 degrees Celsius counts as a change")
    func zeroDegreesChangeDetected() {
        #expect(hasChanges(temperatureText: "0") == true)
    }

    @Test("Missing temperature is not a change")
    func missingTemperatureNotAChange() {
        #expect(hasChanges(temperatureText: TemperatureText.missingValue) == false)
    }

    @Test("Entering a weather condition counts as a change")
    func conditionChangeDetected() {
        #expect(hasChanges(condition: "clear") == true)
        #expect(hasChanges(condition: "") == false)
    }

    @Test("Date changed from baseline counts as a change")
    func dateChangeDetected() {
        let changedDate = itemDate.addingTimeInterval(3600)
        #expect(hasChanges(currentDate: changedDate) == true)
    }

    @Test("Date matching baseline is not a change")
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

    @Test("Automatic camera enrichment matching the baseline is not a change")
    func enrichmentMatchingBaselineIsNotAChange() {
        let baseline = BlogItemCancelBaseline(
            location: "San Francisco",
            temperatureText: "18.5",
            condition: "partly-cloudy",
            date: itemDate
        )
        #expect(
            hasChanges(
                location: "San Francisco",
                temperatureText: "18.5",
                condition: "partly-cloudy",
                baseline: baseline
            ) == false
        )
    }

    @Test("Editing location after automatic enrichment counts as a change")
    func editingAfterEnrichmentDetected() {
        let baseline = BlogItemCancelBaseline(
            location: "San Francisco",
            temperatureText: "18.5",
            condition: "partly-cloudy",
            date: itemDate
        )
        #expect(
            hasChanges(
                location: "Los Angeles",
                temperatureText: "18.5",
                condition: "partly-cloudy",
                baseline: baseline
            ) == true
        )
    }

    @Test("Multiple simultaneous changes still report true")
    func multipleChanges() {
        #expect(
            hasChanges(
                blogText: "Hello",
                location: "London",
                temperatureText: "12",
                didReorderPhotos: true
            ) == true
        )
    }
}
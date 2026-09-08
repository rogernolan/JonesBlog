import PhotosUI
import Testing

@testable import InstaBlog

@Suite("Shared multi-photo picker")
struct SharedPhotoLibraryPickerTests {
    @Test func requestsOrderedSelection() {
        #expect(SharedMultiPhotoLibraryPicker.configuration().selection == .ordered)
    }
}

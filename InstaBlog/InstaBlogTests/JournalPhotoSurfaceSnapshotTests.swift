import SnapshotTesting
import SwiftUI
import XCTest
@testable import InstaBlog

@MainActor
final class JournalPhotoSurfaceSnapshotTests: XCTestCase {
    func testPhotoPlaceholdersOnPhoneAndPad() {
        let palettePhoto = PhotoItemDisplay(
            date: Date(timeIntervalSince1970: 0),
            caption: "Harbour view",
            palette: .harbour
        )
        let unavailablePhoto = PhotoItemDisplay(
            date: Date(timeIntervalSince1970: 0),
            caption: "Unavailable",
            availability: .unavailable
        )
        let surface = HStack(spacing: 12) {
            JournalPhotoSurface(photo: palettePhoto, scaling: .fill)
            JournalPhotoSurface(photo: unavailablePhoto, scaling: .fit)
        }
        .padding()
        .frame(width: 360, height: 240)
        .background(Color(uiColor: .systemBackground))

        assertSnapshot(of: surface, as: .image(layout: .device(config: .iPhone13)))
        assertSnapshot(of: surface, as: .image(layout: .device(config: .iPadPro11)))
    }
}

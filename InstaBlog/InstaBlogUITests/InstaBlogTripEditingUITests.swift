import UIKit
import XCTest

final class InstaBlogTripEditingUITests: InstaBlogUITestCase {
    @MainActor
    func testEditTripSurfacesAdaptToDarkMode() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPad uses a different trip editor."
        )

        let originalAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        addTeardownBlock {
            XCUIDevice.shared.appearance = originalAppearance
        }

        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        app.buttons["Trip actions"].tap()
        let editTripButton = app.buttons["Edit Trip"]
        XCTAssertTrue(editTripButton.waitForExistence(timeout: uiLoadTimeout))
        editTripButton.tap()

        let editTripTitle = app.staticTexts["Edit Trip"]
        XCTAssertTrue(editTripTitle.waitForExistence(timeout: uiLoadTimeout))

        let surfaces = [
            app.descendants(matching: .any)["Trip title"],
            app.descendants(matching: .any)["Trip description"],
            app.descendants(matching: .any)["Trip start date"]
        ]

        for surface in surfaces {
            XCTAssertTrue(surface.waitForExistence(timeout: uiLoadTimeout))
            XCTAssertLessThan(
                averageBrightness(of: surface),
                0.5,
                "Expected \(surface.identifier) to use a dark-mode surface color."
            )
        }
    }

    private func averageBrightness(of element: XCUIElement) -> CGFloat {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(element.identifier) in dark mode"
        attachment.lifetime = .keepAlways
        add(attachment)

        var rgba = [UInt8](repeating: 0, count: 4)
        guard let image = screenshot.image.cgImage,
              let context = CGContext(
                data: &rgba,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            XCTFail("Could not prepare the screenshot for color analysis.")
            return 1
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return (
            0.2126 * CGFloat(rgba[0])
                + 0.7152 * CGFloat(rgba[1])
                + 0.0722 * CGFloat(rgba[2])
        ) / 255
    }
}

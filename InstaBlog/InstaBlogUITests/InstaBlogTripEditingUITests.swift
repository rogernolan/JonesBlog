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

        let cancelButton = app.buttons["Cancel"]
        let saveButton = app.buttons["Save"]
        XCTAssertGreaterThanOrEqual(cancelButton.frame.width, 84)
        XCTAssertGreaterThanOrEqual(cancelButton.frame.height, 44)
        XCTAssertGreaterThanOrEqual(saveButton.frame.width, 84)
        XCTAssertGreaterThanOrEqual(saveButton.frame.height, 44)

        let titleSurface = app.descendants(matching: .any)["Trip title"]
        let descriptionSurface = app.descendants(matching: .any)["Trip description"]
        let surfaces = [
            titleSurface,
            descriptionSurface,
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

        XCTAssertEqual(
            trailingBackgroundBrightness(of: descriptionSurface),
            trailingBackgroundBrightness(of: titleSurface),
            accuracy: 0.04,
            "Expected the description editor to use the same grey background as the title field."
        )
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

    private func trailingBackgroundBrightness(of element: XCUIElement) -> CGFloat {
        guard let image = element.screenshot().image.cgImage else {
            XCTFail("Could not capture \(element.identifier) for color analysis.")
            return 1
        }

        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not prepare \(element.identifier) for color analysis.")
            return 1
        }

        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) * 0.9,
                y: -CGFloat(image.height) * 0.5,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )

        return (
            0.2126 * CGFloat(rgba[0])
                + 0.7152 * CGFloat(rgba[1])
                + 0.0722 * CGFloat(rgba[2])
        ) / 255
    }
}

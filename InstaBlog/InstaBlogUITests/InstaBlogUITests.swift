import XCTest

class InstaBlogUITestCase: XCTestCase {
    let uiLoadTimeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-in-memory-database")
        app.launchArguments.append("-ui-testing-reset-drafts")
        return app
    }

    @MainActor
    func openSeededTripJournal(in app: XCUIApplication, expectedTripName: String = "Provence by Train") {
        let tripTitle = app.staticTexts["Journal trip title"]
        if tripTitle.waitForExistence(timeout: 3), tripTitle.label.contains(expectedTripName) {
            let journalCard = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
            _ = journalCard.waitForExistence(timeout: uiLoadTimeout)
            return
        }

        if UIDevice.current.userInterfaceIdiom == .pad {
            let openMenuButton = app.buttons["Show menu"]
            if openMenuButton.waitForExistence(timeout: 2) {
                openMenuButton.tap()
            }
        }

        let tripsTab = app.buttons["Trips"]
        XCTAssertTrue(tripsTab.waitForExistence(timeout: uiLoadTimeout))
        tripsTab.tap()

        if UIDevice.current.userInterfaceIdiom != .pad {
            XCTAssertTrue(
                waitForPredicate(NSPredicate(format: "isSelected == true"), on: tripsTab),
                "Expected the Trips tab button to become selected."
            )
        }

        let trip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", expectedTripName)
        ).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: uiLoadTimeout))
        // The iOS 27 tab/sidebar transitions can leave a raw coordinate tap
        // with an infinite frame. Wait for the row to become interactable and
        // let XCTest perform the element-level tap on every device.
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isHittable == true"), on: trip),
            "Expected the seeded trip row to become interactable."
        )
        trip.tap()

        let journalCard = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
        let journalLoadTimeout = UIDevice.current.userInterfaceIdiom == .pad ? 30 : uiLoadTimeout
        XCTAssertTrue(
            journalCard.waitForExistence(timeout: journalLoadTimeout),
            "Expected the selected trip journal to finish loading."
        )
    }

    func card(withAccessibilityIdentifier identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func journalCard(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "Journal blog item card")
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    func descendant(withAccessibilityIdentifier identifier: String, in element: XCUIElement) -> XCUIElement {
        element.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func addButton(alignedWith location: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "Add blog item")
            .allElementsBoundByIndex
            .min { lhs, rhs in
                abs(lhs.frame.midY - location.frame.midY) < abs(rhs.frame.midY - location.frame.midY)
            } ?? app.descendants(matching: .any).matching(identifier: "Add blog item").firstMatch
    }

    func tapScreenPoint(_ point: CGPoint, in app: XCUIApplication) {
        let appFrame = app.frame
        app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (point.x - appFrame.minX) / appFrame.width,
                dy: (point.y - appFrame.minY) / appFrame.height
            )
        ).tap()
    }

    func assertDetailShows(caption expectedCaption: String, in app: XCUIApplication) {
        let caption = app.textViews["BlogItem blog text"]
        let timeout = UIDevice.current.userInterfaceIdiom == .pad ? 30 : uiLoadTimeout
        XCTAssertTrue(caption.waitForExistence(timeout: timeout))
        XCTAssertEqual(caption.value as? String, expectedCaption)
    }

    func waitForPredicate(_ predicate: NSPredicate, on element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: uiLoadTimeout) == .completed
    }
}

enum SyncStatusFixture: String, Equatable {
    case storedLocally
    case pending
    case synced
    case failed
}

enum PhotoAvailabilityFixture: String {
    case available
    case downloading
    case unavailable
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

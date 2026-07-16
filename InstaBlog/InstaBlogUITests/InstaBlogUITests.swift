import XCTest

class InstaBlogUITestCase: XCTestCase {
    let uiLoadTimeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-in-memory-database")
        return app
    }

    @MainActor
    func openSeededTripJournal(in app: XCUIApplication) {
        let tripsTab = app.buttons["Trips"]
        XCTAssertTrue(tripsTab.waitForExistence(timeout: uiLoadTimeout))
        tripsTab.tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isSelected == true"), on: tripsTab),
            "Expected the Trips tab button to become selected."
        )

        let trip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Provence by Train")
        ).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: uiLoadTimeout))
        trip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let tripTitle = app.staticTexts["Journal trip title"]
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "exists == true AND label CONTAINS %@", "Provence by Train"),
                on: tripTitle
            ),
            "Expected the selected trip journal to finish loading."
        )

        let journalCard = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
        XCTAssertTrue(journalCard.waitForExistence(timeout: uiLoadTimeout))
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
        XCTAssertTrue(caption.waitForExistence(timeout: uiLoadTimeout))
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
    case downloading
    case unavailable
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

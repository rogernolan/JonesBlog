import Testing
import UIKit

@testable import InstaBlog

@MainActor
@Suite("Prominent tab long-press target")
struct ProminentTabLongPressTargetTests {
    @Test func resolvesTheControllerDesignatedProminentTab() {
        let journal = UITab(title: "Journal", image: nil, identifier: "journal") { _ in
            UIViewController()
        }
        let compose = UITab(title: "New entry", image: nil, identifier: "compose") { _ in
            UIViewController()
        }
        let controller = UITabBarController()
        controller.tabs = [journal, compose]
        controller.prominentTabIdentifier = compose.identifier

        #expect(ProminentTabLongPressTarget.tab(in: controller) === compose)
    }

    @Test func returnsNilWithoutAProminentTab() {
        let controller = UITabBarController()

        #expect(ProminentTabLongPressTarget.tab(in: controller) == nil)
    }
}

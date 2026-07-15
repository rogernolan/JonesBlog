# Journal Header Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the journal’s full-width navigation-style header with a scroll-reactive title and independent top-right trip-actions menu across iPhone/iPad Journal and trip views.

**Architecture:** Keep the behavior in `JournalView`, which is shared by the Journal tab and trip journals. Report the scroll offset through a named coordinate space and preference, convert it through a small pure `JournalHeaderPresentation` value, and render the expanded/compact title from that presentation. Keep the actions menu in its own trailing overlay region and hide the root navigation bar so no back affordance is supplied by the navigation controller.

**Tech Stack:** SwiftUI, Swift Testing, XCTest UI tests, Xcode project scheme `InstaBlog`.

## Global Constraints

- Apply the behavior to both iPhone and iPad and to both the Journal tab and trip journal views.
- Do not add external dependencies or change persistence, networking, or navigation architecture beyond the journal root header.
- The expanded title is large, right-aligned, multiline-capable, and has no liquid-glass background.
- The compact title is centered, single-line, liquid-glass-backed, and width-constrained to leave room for the ellipsis menu.
- The root journal must not display a back button.
- Preserve the existing `Trip actions` menu label and Edit Trip/End Trip actions.
- Use the existing test conventions and run tests before completion.

---

## File Map

- Modify: `InstaBlog/InstaBlog/JournalScreens.swift` — add scroll-offset reporting, pure presentation mapping, and the redesigned journal header.
- Create: `InstaBlog/InstaBlogTests/JournalHeaderTests.swift` — test zero-offset and non-zero-offset presentation states.
- Modify: `InstaBlog/InstaBlogUITests/InstaBlogUITests.swift` — verify the shared Journal/trip surface has actions and no Back button.
- Create: `docs/superpowers/specs/2026-07-15-journal-header-design.md` — approved design already committed; no further changes expected.

### Task 1: Add deterministic header presentation tests

**Files:**
- Create: `InstaBlog/InstaBlogTests/JournalHeaderTests.swift`

**Interfaces:**
- Consumes: The `JournalHeaderPresentation` value and `init(scrollOffset:collapseDistance:)` produced by Task 2.
- Produces: Failing tests that lock down the requested zero-scroll and n-pixel-scroll states.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import InstaBlog

@Suite("Journal header presentation")
struct JournalHeaderTests {
    @Test("Zero scroll keeps the expanded title state")
    func zeroScrollIsExpanded() {
        let presentation = JournalHeaderPresentation(scrollOffset: 0, collapseDistance: 120)

        #expect(presentation.progress == 0)
        #expect(presentation.isExpanded)
        #expect(!presentation.isCompact)
    }

    @Test("A full collapse-distance scroll reaches the compact title state")
    func scrolledTitleIsCompact() {
        let presentation = JournalHeaderPresentation(scrollOffset: 120, collapseDistance: 120)

        #expect(presentation.progress == 1)
        #expect(!presentation.isExpanded)
        #expect(presentation.isCompact)
    }
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `rtk proxy xcodebuild -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:InstaBlogTests/JournalHeaderTests test`

Expected: FAIL because `JournalHeaderPresentation` does not yet exist.

### Task 2: Implement scroll-reactive journal header

**Files:**
- Modify: `InstaBlog/InstaBlog/JournalScreens.swift:8-188`

**Interfaces:**
- Consumes: Existing `TripDisplay`, `onEditTrip`, `onEndTrip`, and `embedsNavigationStack` values.
- Produces: `JournalHeaderPresentation`, `JournalScrollOffsetKey`, and the updated `JournalView` body/header.

- [ ] **Step 1: Add the pure presentation mapping**

Add an internal value near `JournalView`:

```swift
struct JournalHeaderPresentation: Equatable {
    let progress: CGFloat

    init(scrollOffset: CGFloat, collapseDistance: CGFloat) {
        let distance = max(collapseDistance, 1)
        progress = min(max(scrollOffset / distance, 0), 1)
    }

    var isExpanded: Bool { progress == 0 }
    var isCompact: Bool { progress == 1 }
}
```

Add a preference key for the vertical position of the scroll content in a named coordinate space. Treat a non-positive content origin as a positive scroll amount so pulling down does not push the title toward the compact state:

```swift
private struct JournalScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
```

- [ ] **Step 2: Report the journal scroll offset**

Give the `ScrollView` a stable coordinate-space name and attach a zero-height `GeometryReader` at the top of its content. Convert its `minY` to scroll distance with `max(0, -minY)`. Store the resulting `JournalHeaderPresentation` in `@State` and update it from `onPreferenceChange`, with the existing animation transaction used only for presentation updates.

- [ ] **Step 3: Replace the current header and navigation-bar configuration**

Remove the `dismiss` environment property and the `else if embedsNavigationStack` back-button branch. Replace the current material `HStack` with a header that has:

```swift
ZStack(alignment: .topTrailing) {
    journalTitle(presentation)
        .frame(maxWidth: .infinity, alignment: .trailing)

    if !trip.isUnassigned {
        tripActionsMenu
    }
}
```

The title view should interpolate between the two approved states using `presentation.progress`: expanded font/spacing/alignment/line limit at zero scroll, and compact headline/one-line/centered material pill at full collapse. Use a fixed collapse distance of `120` points. Keep a trailing layout reservation for the menu in the compact state so the title cannot overlap it. Add accessibility identifier `Journal trip title` to the title and retain the menu’s `Trip actions` accessibility label.

The independent actions menu must remain a single control at the top trailing edge, with the existing Edit Trip and conditional End Trip actions. Apply the existing 44-point hit target without wrapping the whole header in material.

Configure the journal root with `.toolbar(.hidden, for: .navigationBar)` for both embedded and non-embedded usage; retain `.navigationTitle("")` only if required by SwiftUI to suppress inherited titles. Do not hide the tab bar or alter destination views.

- [ ] **Step 4: Run the focused unit tests**

Run: `rtk proxy xcodebuild -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:InstaBlogTests/JournalHeaderTests test`

Expected: PASS for zero scroll (`progress == 0`, expanded) and 120-point scroll (`progress == 1`, compact).

### Task 3: Add UI regression coverage for Journal and trip views

**Files:**
- Modify: `InstaBlog/InstaBlogUITests/InstaBlogUITests.swift`

**Interfaces:**
- Consumes: The `Journal trip title` identifier and `Trip actions` accessibility label from Task 2.
- Produces: UI regression coverage for both entry points and the removed back affordance.

- [ ] **Step 1: Add Journal-tab header assertions**

Add a test that launches the seeded/default Journal tab, waits for `Journal trip title`, asserts `app.buttons["Trip actions"]` exists, and asserts `app.buttons["Back"]` does not exist.

- [ ] **Step 2: Add trip-journal header assertions**

Add a test that calls the existing `openSeededTripJournal(in:)` helper, waits for the same title identifier, asserts `Trip actions` exists, and asserts `Back` does not exist. This confirms the shared view behaves the same after navigation from Trips.

- [ ] **Step 3: Run the focused UI tests**

Run: `rtk proxy xcodebuild -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:InstaBlogUITests/InstaBlogUITests/testJournalTabHeaderHasActionsAndNoBackButton -only-testing:InstaBlogUITests/InstaBlogUITests/testTripJournalHeaderHasActionsAndNoBackButton test`

Expected: PASS, with the title and actions control present and no Back button in either root journal entry point.

### Task 4: Broaden verification and review the diff

**Files:**
- No new files; inspect `JournalScreens.swift`, `JournalHeaderTests.swift`, and `InstaBlogUITests.swift`.

- [ ] **Step 1: Run the unit test suite**

Run: `rtk proxy xcodebuild -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:InstaBlogTests test`

Expected: PASS.

- [ ] **Step 2: Run the UI test suite**

Run: `rtk proxy xcodebuild -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:InstaBlogUITests test`

Expected: PASS. If simulator availability prevents execution, record the exact failure and run the closest available destination before reporting the limitation.

- [ ] **Step 3: Inspect the final diff and status**

Run: `rtk git diff --check && rtk git diff --stat && rtk git status --short --branch`

Expected: no whitespace errors; only the journal header implementation, its tests, and the approved spec/plan are present.

- [ ] **Step 4: Commit the implementation**

```bash
rtk git add InstaBlog/InstaBlog/JournalScreens.swift InstaBlog/InstaBlogTests/JournalHeaderTests.swift InstaBlog/InstaBlogUITests/InstaBlogUITests.swift
rtk git commit -m "Fix journal header navigation"
```


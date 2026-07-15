# Journal Header Redesign

## Scope

Fix issue #202 for the shared journal root used by both the Journal tab and trip views on iPhone and iPad.

## User-visible behavior

- The journal root has no back button. Navigation to a journal root must not render a chevron or rely on a visible navigation-controller back affordance.
- The trip-actions ellipsis is an independent top-trailing button/menu, visually separated from the title and kept clear of the compact title state.
- At the top of the journal (zero scroll offset), the trip title is large, right-aligned, multiline-capable, and has no liquid-glass background.
- As the journal scrolls, the title animates into a centered, single-line liquid-glass pill. The compact title has a maximum width that leaves room for the ellipsis button.
- The behavior is identical across iPhone/iPad and Journal-tab/trip-journal entry points.

## Design

`JournalView` remains the single owner of this behavior. The navigation bar is hidden for the journal root, and the current material header is replaced by a layered header: a title that changes presentation based on scroll progress and an independent trailing actions menu. The scroll view reports its vertical position through a named coordinate space and a preference, allowing the header to animate continuously rather than switching at a threshold.

The title and actions are placed in a top safe-area inset/overlay so they remain available while content scrolls beneath them. The expanded title is aligned to the trailing edge and may wrap. The compact state uses a constrained frame and liquid-glass material, with the trailing action control occupying its own layout region.

## State and accessibility

Scroll position is presentation state only; it is not persisted. The actions menu retains its existing labels and actions. The title remains exposed as the trip title and header content keeps header semantics. The actions control retains the `Trip actions` accessibility label. No new persistence, networking, or dependencies are needed.

## Verification

- Add/update UI coverage for the Journal tab and a trip journal to assert that no `Back` button is present and that `Trip actions` is available.
- Build and run the relevant unit/UI test plan on the project’s recent iPhone/iPad simulator destinations, expanding verification if failures indicate a broader issue.
- Inspect the diff to confirm the change is limited to the journal header and its tests.

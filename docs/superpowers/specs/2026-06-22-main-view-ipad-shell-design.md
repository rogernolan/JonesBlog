# InstaBlog Main View — iPad Shell Design

Date: 2026-06-22

Status: **Approved for design checkpoint**

## Purpose

This document records the agreed iPad shell and app-level navigation direction for InstaBlog. It extends the approved iPhone Chaptered Journal direction in `2026-06-22-main-view-iphone-ux-checkpoint.md` without specifying BlogItem detail, editing, or capture-workspace layouts.

The design is directional rather than pixel-accurate. Final widths, spacing, toolbar placement, and column-collapse behavior must be tuned in SwiftUI previews and on simulated or physical iPads.

## Core Decision

The iPad uses an adaptive, sidebar-led shell around one continuous Journal.

- In landscape and other sufficiently wide layouts, app destinations appear in a persistent leading sidebar and the Journal occupies the remaining content region.
- In portrait and narrower layouts, the Journal uses the full width. App destinations move into a transient sidebar opened from the leading toolbar control.
- DayPosts do not have a navigation column or picker. They are chapters within one continuous scrolling Journal, not separate destinations.
- Compose remains a prominent action rather than a persistent navigation destination.

This is a two-region model at its widest: app navigation and Journal content.

## Structural Wireframes

### Landscape

```text
┌──────────────────┬─────────────────────────────────────────────┐
│ InstaBlog        │ Journal                         Provence    │
│                  ├─────────────────────────────────────────────┤
│ ▣ Journal        │ Monday, 23 June                            │
│ ▱ Trips          │ Arles → Saintes-Maries-de-la-Mer           │
│                  │                                             │
│ [ ✎ Compose ]    │ [ BlogItem ]                                │
│                  │ [ BlogItem / Gallery ]                      │
│ ⌕ Search         │                                             │
│                  │ Sunday, 22 June                             │
│ ⚙ Settings       │ Avignon → Arles                             │
│                  │ [ BlogItem ... ]                            │
└──────────────────┴─────────────────────────────────────────────┘
```

### Portrait

```text
┌──────────────────────────────────────┐
│ ☰  Journal                       ✎   │
├──────────────────────────────────────┤
│ Monday, 23 June                      │
│ Arles → Saintes-Maries-de-la-Mer     │
│                                      │
│ [ BlogItem ]                         │
│ [ BlogItem / Gallery ]               │
│                                      │
│ Sunday, 22 June                      │
│ Avignon → Arles                      │
│ [ BlogItem ... ]                     │
└──────────────────────────────────────┘
```

Opening the leading toolbar control reveals the same app destinations shown persistently in landscape. It does not reveal DayPost navigation.

## Journal Flow

The Journal is one calm, single-column editorial surface in both orientations.

When a Trip is open:

1. The Journal opens at the current or latest DayPost.
2. All BlogItems and derived Galleries for that DayPost appear in chronological order.
3. The preceding DayPost begins below the final item of the current DayPost.
4. Bloggers continue scrolling downward through progressively earlier days.

For example, all content from Monday, 23 June appears before the heading and content for Sunday, 22 June. DayPost headings, route breadcrumbs, position indicators, BlogItems, Galleries, and sync status retain the anatomy approved in the iPhone checkpoint.

The wide iPad canvas must not turn the Journal into a dashboard, masonry grid, multi-column feed, or master list of DayPosts. Content width may be constrained for comfortable reading while the surrounding space remains visually quiet.

## App Navigation

The shell retains the five concepts established on iPhone:

1. **Journal** — current Trip and its continuous DayPost flow.
2. **Trips** — completed Trips and unassigned content.
3. **Compose** — opens the focused new-BlogItem workspace.
4. **Search** — searches across the scope defined by the later Search design.
5. **Settings** — Blog configuration, subscribers, sharing, deleted items, and blogger identity.

Journal, Trips, Search, and Settings are destinations. Compose is visually grouped with them for availability but remains an action.

In landscape, Compose appears as a prominent green squircle or rounded control within the sidebar. In portrait, it moves to the trailing side of the Journal toolbar. It uses the white monochrome `square.and.pencil` symbol and retains a minimum 44-by-44-point interactive target.

Activating Compose replaces the reading shell with the capture-focused workspace. Returning restores the prior Journal reading position.

## Orientation and Adaptation

The information architecture remains stable across orientation changes; only disclosure changes.

- Landscape exposes the app sidebar persistently when width allows.
- Portrait prioritizes the Journal and hides the app sidebar until requested.
- Rotation must preserve the selected app destination and Journal scroll position.
- No bottom tab bar is introduced on iPad merely to match iPhone portrait.
- No DayPost picker appears during collapse because DayPosts remain part of the scroll flow.

Use standard SwiftUI navigation and toolbar behavior where it satisfies this design. Custom styling should be limited to the Compose control, selected-destination treatment where needed to preserve the cross-device visual language, and the Journal's editorial rhythm.

## Visual and Accessibility Principles

- Navigation is the glass/control layer; Journal content remains the content layer.
- Avoid nested glass surfaces.
- Use semantic colors and materials that adapt to light mode, dark mode, Increased Contrast, and Reduced Transparency.
- Use system typography and Dynamic Type; do not rely on fixed text sizes to maintain the column layout.
- All controls need at least 44-by-44-point targets and meaningful VoiceOver labels.
- Compose prominence cannot depend on green alone; its symbol, placement, and accessibility label communicate its purpose.
- The continuous relationship between DayPosts must remain understandable at large accessibility sizes without relying only on thin dividers.

## Platform Assumption to Verify

The design assumes SwiftUI's adaptive split navigation can provide a persistent leading sidebar at wide widths and a user-revealable transient sidebar at narrower widths while preserving destination and Journal state.

Before treating exact collapse behavior as settled implementation detail, verify it with a minimal `NavigationSplitView` prototype in both iPad orientations and at relevant multitasking widths. The prototype should confirm:

- sidebar visibility and reveal behavior;
- toolbar placement of the portrait Compose action;
- state and scroll-position preservation across rotation and column changes;
- usable Journal width at large Dynamic Type sizes.

If the system split view cannot preserve this behavior cleanly, adjust the presentation mechanics without reintroducing a DayPost navigation column or changing the continuous Journal model.

## Deferred Work

- BlogItem and Gallery detail coexistence on wide layouts
- editing and deletion presentation
- capture-workspace layout
- Search information architecture and results
- Trips and no-open-Trip layouts
- exact sidebar width and Journal reading measure
- final selected-destination styling and SF Symbols
- exact behavior in Stage Manager and narrow multitasking sizes

## Approval Boundary

The approved checkpoint is the adaptive sidebar-led iPad shell, persistent app navigation in wide landscape layouts, transient app navigation with a full-width Journal in portrait, a prominent orientation-appropriate Compose action, and one continuous reverse-day Journal with chronological content inside each DayPost.

There is explicitly no persistent DayPost navigation column or DayPost picker.

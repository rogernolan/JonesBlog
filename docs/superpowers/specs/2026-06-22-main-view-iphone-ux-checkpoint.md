# InstaBlog Main View — iPhone UX Checkpoint

Date: 2026-06-22

Status: **iPhone direction approved for checkpoint; iPad shell direction recorded separately**

## Purpose

This document records the agreed iPhone UX direction for InstaBlog's main view so that iPad exploration can proceed without losing the current decisions. It is a directional UX specification, not a pixel-accurate visual design or implementation plan.

The design draws on:

- the InstaBlog Product Requirements Document
- Issue #3, App shell and navigation skeleton
- Issue #6, BlogItem draft creation (text only)
- Issue #20, Local sync status indicators

## Experience Direction

The main view should feel first like a polished travel journal, not an activity feed or capture dashboard. Capture remains immediately available through a visually prominent compose action.

When an open Trip exists, the Journal opens at the current or latest DayPost. Bloggers can scroll backward through earlier days. The reading order within each DayPost is chronological.

The visual direction is a **Chaptered Journal**: a calm single-column narrative in which DayPosts act as chapters and individual BlogItems and Galleries share one editorial flow.

## iPhone App Shell

The bottom navigation contains five positions:

1. **Journal** — the current Trip and its DayPosts.
2. **Trips** — completed Trips and unassigned content.
3. **Compose** — an icon-only action that opens the focused new-BlogItem workspace.
4. **Search** — discovery across Trips, dates, text, places, and authors. Exact search scope remains to be specified.
5. **Settings** — gallery rules, subscribers, sharing, deleted items, and blogger identity.

The Compose control:

- occupies the middle position inside the tab-bar background
- is a larger green squircle, but does not rise outside the bar
- has no outline, border, or visible text label
- uses the monochrome white SF Symbol `square.and.pencil`
- is an action rather than a persistent destination
- may use a brief symbol bounce as activation feedback, subject to Reduce Motion

The selected navigation destination uses a dark rounded-rectangle plate with white symbol and label content. The plate is evenly inset from the tab-bar background, and its corner radius must be geometrically concentric with the outer capsule. Unselected destinations remain visually secondary.

The tab bar should be compact while retaining at least 44-by-44-point interactive targets, safe-area clearance, Dynamic Type support, and legibility in all supported accessibility appearances.

## DayPost Anatomy

Each DayPost is introduced as a journal chapter with:

- a prominent local calendar date
- a compact route breadcrumb showing the day's chronological locations, for example `Arles → Saintes-Maries-de-la-Mer`
- a position indicator where useful, such as `Day 6 of 12`

The route breadcrumb is an itinerary, not a geographic hierarchy. Repeated adjacent locations should eventually collapse according to the DayPost derivation rules still open in `DesignDecisions.md`.

## Individual BlogItems

An image-led BlogItem contains:

- a large rounded image
- a compact, legible metadata pill over the lower-left of the image
- caption text beneath the image
- location beneath the caption

The image overlay shows:

- author
- local time
- weather temperature and condition symbol

Location remains outside the overlay so longer place names have room and image contrast does not constrain them.

Text-only BlogItems use the same narrative rhythm without reserving an empty image area. Their author, local time, weather, and location still need a clear metadata treatment during the detailed component-design phase.

Tapping a BlogItem opens its full detail. Editing and deletion remain available from detail according to the PRD.

## Galleries

Galleries use a horizontal filmstrip within the DayPost rather than an editorial mosaic.

The filmstrip should:

- show approximately two complete image frames and a substantial portion of the next frame on iPhone
- make horizontal continuation visually obvious without an arrow or instructional “Swipe” label
- use consistent frame widths, spacing, and corner radii so the partial frame looks intentional
- allow each visible image to retain compact author and time context
- keep Gallery-level heading and caption content outside the horizontally moving strip
- run visually toward the screen edge while its heading and caption align with the journal text column

Tapping a Gallery image opens the Gallery at that BlogItem. The Gallery detail presents its BlogItems as a vertical sequence, consistent with the PRD.

Exact frame dimensions are intentionally unspecified. SwiftUI layout, device width, safe areas, accessibility, and preview/on-device evaluation will determine the final metrics. The design intent is the two-and-a-half-frame continuation cue.

## Sync Status

Fully synced content remains visually quiet.

Pending or failed upload state appears only when needed:

- image-led BlogItems may show a second compact status icon or pill at the image's lower-right
- text-only BlogItems need an equivalent unobtrusive status placement
- Gallery children retain their own item status rather than receiving an invented Gallery-wide sync state
- failure must be distinguishable from pending by more than colour alone

The visible status represents the combined BlogItem and required MediaAsset state described by Issue #20.

## Capture Transition

Activating Compose immediately switches from reading to a capture-focused workspace. The tab bar is not shown in that workspace. Saving is implicit as required by Issue #6, and returning from capture restores the previous journal reading position.

The detailed capture layout, empty-caption validation treatment, save feedback, keyboard behaviour, and photo affordance remain outside this checkpoint.

## Empty and Alternate App States

When no Trip is open, Journal becomes the completed-Trips landing state and provides a clear action to start a Trip. Trips remains the durable route to completed Trips and unassigned content.

The exact empty-state composition and the relationship between the Journal and Trips tabs when no Trip is open still need design validation.

## Visual and Sizing Principles

- The browser mockups used during exploration are not pixel specifications.
- Prefer standard SwiftUI and iOS 26 navigation behaviour where it satisfies this design.
- Custom dimensions are limited to the compose control, selected-tab plate, content rhythm, and Gallery frames.
- Final metrics must be tuned in SwiftUI previews and on physical or simulated iPhone sizes.
- Use semantic colours and materials that adapt to light mode, dark mode, Increased Contrast, and Reduced Transparency.
- Avoid nested glass surfaces. Navigation is the glass/control layer; journal content remains the content layer.

## Deferred or Revisited Through iPad Exploration

- The iPad shell uses the adaptive sidebar-led model recorded in `2026-06-22-main-view-ipad-shell-design.md`
- How the continuous Journal and BlogItem detail coexist on wide layouts
- Whether the iPhone shell changes after establishing a cross-device navigation model
- Final tab-bar and compose-control measurements
- Final SF Symbols for Journal, Trips, Search, and Settings
- Search information architecture and result presentation
- Text-only BlogItem visual anatomy
- Detailed capture-workspace UX

## Current Approval Boundary

The approved checkpoint consists of the iPhone Chaptered Journal direction, the five-position bottom bar, the contained green `square.and.pencil` Compose control, the dark concentric selected-tab plate, over-image BlogItem metadata, route-style DayPost breadcrumbs, and the two-and-a-half-frame Gallery filmstrip.

The iPad shell exploration is recorded in `2026-06-22-main-view-ipad-shell-design.md`. The two checkpoints should be reconciled into a final cross-platform UX specification after the remaining wide-layout detail and compact-width behavior is explored.

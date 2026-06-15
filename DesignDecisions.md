# Design Decisions

Date: 2026-06-15

## Storage and Sync

Status: Accepted for v1

### Decision

JonesBlog will use SQLiteData as its primary local persistence layer, backed by SQLite/GRDB, with CloudKit SyncEngine for automatic multi-device and multi-user sync.

The shared Blog will be represented as CloudKit-shareable structured records. BlogItem photos will be associated with their BlogItem records and synced through CloudKit assets. Derived display concepts such as DayPosts and Galleries will not be stored as first-class records in v1.

SQLiteData is an approved external dependency for this project.

### Context

The PRD's decisive storage requirement is shared, offline-capable collaboration:

- Every Blog is multi-user by default.
- All Bloggers can create, edit, and delete shared Blog data in v1.
- BlogItems, Trips, locations, weather, media, settings, and the subscriber list must sync automatically.
- Sync should be prompt when connected, but live cursor-style collaboration is not required.
- Concurrent edits may use last-saved-version-wins conflict behavior in v1.
- The app should prefer free storage and native Apple options where practical.

A plain local database is not enough because the Blog must be shared between devices and users. A hosted backend is not needed for v1 because CloudKit can provide the required shared Apple-native sync layer without a separate service.

### Why SQLiteData

SQLiteData is the best fit for v1 because it provides:

- Local-first writes and reads, so capture remains fast and works offline.
- Type-safe SQLite tables and queries.
- Value-type models that work well with Swift 6 concurrency.
- Good performance for deriving Trip, DayPost, itinerary, and Gallery views from BlogItems.
- Explicit foreign keys and query control for date, location, author, and Trip queries.
- CloudKit SyncEngine support, including sharing.

SwiftData was not chosen as the default because its strongest path is simple CRUD with private CloudKit sync. JonesBlog needs shared Blog collaboration and more explicit control over sync state and shared records.

Core Data with CloudKit remains a viable fallback if SQLiteData becomes unsuitable, but it would add more object-context complexity and is less pleasant for a new SwiftUI app.

Hosted services such as Firebase, Supabase, or a custom server are not part of the v1 default architecture.

### Storage Locations

The app should use different storage locations for different data shapes:

- SQLite database: `Library/Application Support`
- Durable local originals for captured/imported media before and after sync: `Library/Application Support`
- Cloud-synced media representation: CloudKit assets associated with BlogItem records
- Generated thumbnails and resized email/export images: `Library/Caches`
- Temporary image-processing and email-composition files: `tmp`

No user-created Blog data should live only in `Caches` or `tmp`.

### Sync Architecture

The app should follow an offline-first sync model:

1. Save user changes to SQLiteData first.
2. Queue changes for CloudKit SyncEngine.
3. Show local data immediately.
4. Pull remote changes in the background.
5. Merge fetched changes into the local database.

For v1, conflict handling can be last-saved-version-wins, matching the PRD. The app should still track sync state so UI can indicate pending upload, download, failed sync, or fully synced states.

CloudKit sharing should be used for Blog collaboration. A Blog owner creates the shared Blog, presents the native sharing UI, and invited Bloggers accept the share. In v1, all accepted Bloggers have read/write access.

### Model Shape

This is the intended v1 persistence shape. Names may change during implementation, but the responsibilities should stay close to this split.

#### Blog

Represents one complete shared blog workspace.

Suggested fields:

- `id: UUID`
- `title: String`
- `createdAt: Date`
- `updatedAt: Date`
- `activeTripID: Trip.ID?`
- `galleryIntervalSeconds: Int`
- `galleryDistanceMeters: Double`
- `syncMetadataID`

Notes:

- Each app instance can view and edit one Blog at a time.
- Accepting a shared Blog hides any local Blog after a warning.
- Blog settings can live directly on `Blog` for v1 unless they grow enough to justify a separate table.

#### Blogger

Represents a contributor to a Blog.

Suggested fields:

- `id: UUID`
- `blogID: Blog.ID`
- `displayName: String`
- `createdAt: Date`
- `updatedAt: Date`
- `cloudKitParticipantIdentifier: String?`
- `syncMetadataID`

Notes:

- v1 permissions are intentionally flat: every Blogger can edit everything in the shared Blog.
- Future public versions may add role and permission fields.

#### BlogItem

Represents the atomic authored entry used to derive feeds, Galleries, DayPosts, itineraries, and email output.

Suggested fields:

- `id: UUID`
- `blogID: Blog.ID`
- `authorID: Blogger.ID`
- `caption: String?`
- `createdAt: Date`
- `updatedAt: Date`
- `itemDate: Date`
- `itemTimeZoneIdentifier: String?`
- `localDay: String`
- `latitude: Double?`
- `longitude: Double?`
- `locationName: String?`
- `countryCode: String?`
- `weatherTemperatureCelsius: Double?`
- `weatherConditionCode: String?`
- `photoAssetID: MediaAsset.ID?`
- `deletedAt: Date?`
- `syncMetadataID`

Notes:

- A BlogItem must have at least `caption` or `photoAssetID`.
- `itemDate` is the absolute datetime used for ordering.
- `itemTimeZoneIdentifier` and `localDay` allow the app to reconstruct the DayPost date even when the device timezone changes later.
- Soft delete via `deletedAt` is preferable for sync conflict tolerance. Hard delete can be considered after sync behavior is proven.

#### MediaAsset

Represents a durable media file associated with a BlogItem or Trip.

Suggested fields:

- `id: UUID`
- `blogID: Blog.ID`
- `kind: String`
- `localOriginalPath: String?`
- `cloudAssetIdentifier: String?`
- `filename: String`
- `mimeType: String`
- `pixelWidth: Int?`
- `pixelHeight: Int?`
- `createdAt: Date`
- `updatedAt: Date`
- `syncMetadataID`

Notes:

- v1 supports photos only.
- Future video support can reuse this table by adding video-specific metadata.
- Thumbnails should be generated cache files, not source-of-truth records.

#### Trip

Represents a user-defined date range and metadata for grouping DayPosts.

Suggested fields:

- `id: UUID`
- `blogID: Blog.ID`
- `title: String`
- `description: String`
- `startLocalDay: String`
- `endLocalDay: String?`
- `heroImageAssetID: MediaAsset.ID?`
- `createdAt: Date`
- `updatedAt: Date`
- `closedAt: Date?`
- `syncMetadataID`

Notes:

- Only one Trip may be open at a time for a Blog.
- The app should enforce that invariant in application logic and with database constraints if practical.
- DayPosts are derived from BlogItems whose `localDay` falls inside a Trip date range.

#### Subscriber

Represents one shared mailing-list recipient.

Suggested fields:

- `id: UUID`
- `blogID: Blog.ID`
- `emailAddress: String`
- `displayName: String?`
- `createdAt: Date`
- `updatedAt: Date`
- `syncMetadataID`

Notes:

- The subscriber list is shared Blog data.
- Sending email remains a deliberate native compose action, not automatic background publishing.

#### PublishEvent

Optional for v1, but useful if we want a local/shared audit of what was sent.

Suggested fields:

- `id: UUID`
- `blogID: Blog.ID`
- `tripID: Trip.ID?`
- `localDay: String`
- `sentAt: Date`
- `sentByBloggerID: Blogger.ID`
- `recipientCount: Int`
- `syncMetadataID`

Notes:

- This should not store full email content unless a later requirement needs sent-output history.
- If v1 does not need sent history, skip this table.

### Derived Views

#### DayPost

DayPost is not stored in v1.

It is derived by querying BlogItems for a Blog and `localDay`, ordered by `itemDate`. The itinerary is derived from the ordered locations on those BlogItems. The summary weather condition is derived from the weather fields on those BlogItems.

#### Gallery

Gallery is not stored in v1.

It is derived while displaying a Trip or DayPost by grouping adjacent BlogItems that satisfy the Blog's `galleryIntervalSeconds` and `galleryDistanceMeters` settings.

Because Galleries are derived, changing a BlogItem's date or location automatically changes Gallery membership the next time the view is computed.

#### Unassigned Trip

The Unassigned Trip is not stored in v1.

It is derived from BlogItems whose `localDay` is outside every stored Trip date range.

### Constraints and Indexes

The initial database schema should include indexes for the main read paths:

- `BlogItem(blogID, localDay, itemDate)`
- `BlogItem(blogID, itemDate)`
- `BlogItem(authorID)`
- `Trip(blogID, startLocalDay, endLocalDay)`
- `Subscriber(blogID, emailAddress)`
- `MediaAsset(blogID)`

Recommended constraints:

- BlogItem must have either caption text or a photo asset.
- Subscriber email should be unique per Blog, case-insensitively if practical.
- Only one open Trip per Blog, enforced in app logic first and later with a partial unique index if SQLiteData/GRDB support makes that clean.

### Migration Posture

All schema changes after the initial version must use explicit migrations. Before adding, renaming, or deleting columns or tables, read the Axiom database migration guidance and add focused migration tests where practical.

Initial implementation should keep the schema small and avoid speculative tables for future public permissions, rich text, web publishing, or video.

### Open Implementation Questions

- Exact CloudKit share root: likely `Blog`, with child records sharing through the Blog's zone.
- Exact media upload lifecycle and retry behavior for large photos.
- Whether to keep local original image files after CloudKit assets are confirmed uploaded.
- Whether `PublishEvent` is useful in v1 or should wait until publishing history is needed.
- Exact warning text and data handling when accepting a shared Blog hides the local Blog.

## UI Stack

Status: Accepted for v1

### Decision

JonesBlog will use SwiftUI as its primary UI stack.

UIKit will be used only for targeted interoperability where Apple framework surfaces require it or where UIKit remains plainly stronger than SwiftUI for a specific feature.

### Context

JonesBlog is a new native iOS and iPadOS app targeting iOS 26.5+. Its main interface is data-driven:

- Trip lists and completed Trip browsing.
- BlogItem creation, detail, edit, and delete flows.
- Derived DayPost and Gallery presentation.
- Subscriber list management.
- Settings for Gallery grouping.
- Sync and sharing status.
- Manual DayPost email composition.

The app does not have an existing UIKit codebase, so there is no migration value in starting with UIKit. The product also needs adaptive iPhone and iPad layouts, modern navigation, previews, and tight integration with observable app state.

### Why SwiftUI

SwiftUI is the best default because it provides:

- Modern Apple-native UI for new iOS and iPadOS apps.
- Declarative views that fit SQLiteData-backed query state and derived display models.
- Strong support for adaptive layouts across iPhone and iPad.
- Native integration with Swift concurrency and observable state.
- Fast iteration through previews for Trip, BlogItem, Gallery, and settings states.
- Good alignment with modern HIG patterns, SF Symbols, toolbars, sheets, and navigation.

SwiftUI should own the app shell, navigation structure, lists, forms, editors, detail views, settings, and status surfaces.

### UIKit Interoperability

UIKit should be treated as an interoperability island, not a competing app architecture.

Expected UIKit bridge cases:

- `MFMailComposeViewController` for composing DayPost HTML email.
- `UICloudSharingController` for CloudKit share invitation and participant management.
- `UIViewControllerRepresentable` wrappers for UIKit controllers used from SwiftUI.
- TextKit/UIKit only if rich text or advanced text editing becomes a real requirement.
- Other UIKit components only when a required Apple API has no adequate SwiftUI surface.

UIKit bridge code should stay small, focused, and isolated behind SwiftUI-facing views or services.

### Non-Goals

- Do not build the app shell in UIKit.
- Do not introduce UIKit view controllers for ordinary list, form, navigation, or detail screens.
- Do not use UIKit just to avoid learning SwiftUI layout, navigation, or state patterns.
- Do not add a separate UI architecture framework.

### Open Implementation Questions

- Exact iPad navigation structure: likely `NavigationSplitView`, but confirm against the first real Trip and BlogItem flows.
- Whether BlogItem caption editing needs plain SwiftUI text editing for v1 or a future TextKit-backed editor for rich text.
- How much Liquid Glass adoption is appropriate for iOS 26.5 while preserving readability over photos.

## Open Decisions

The following design decisions are important enough to document before or during early implementation. They are intentionally marked **OPEN** until the codebase has enough shape for a concrete decision.

### App Architecture and State Boundaries

Status: **OPEN**

Decide how SwiftUI views talk to persistence, sync, location, WeatherKit, photos, and mail composition. The likely direction is small injected services or repositories rather than broad global state, with business logic kept out of SwiftUI view bodies.

### Navigation Structure

Status: **OPEN**

Decide the app's iPhone and iPad navigation model before building many screens. The likely iPad shape is `NavigationSplitView`, with Trip and DayPost navigation separated from BlogItem detail and editing, but this should be confirmed against the first real flows.

### CloudKit Sharing Model

Status: **OPEN**

Decide the CloudKit share root, custom zone layout, participant handling, and how accepting a share replaces or hides a local Blog. The likely direction is `Blog` as the share root, with child records in the Blog's shared zone.

### Media Lifecycle

Status: **OPEN**

Decide how original photos, local durable files, CloudKit assets, thumbnails, resized display images, and email-sized images relate. This should define what is source-of-truth, what is cached, when files are deleted, and how failed uploads retry.

### Location and Weather Enrichment

Status: **OPEN**

Decide when and how BlogItems are enriched with location, reverse geocoding, and WeatherKit data. The likely direction is save-first capture, then opportunistic enrichment with retry state so entry creation is not blocked by permissions, network, or WeatherKit availability.

### Conflict and Deletion Semantics

Status: **OPEN**

Decide the exact conflict policy and deletion model for shared records. The likely direction is last-saved-version-wins for edited fields and soft delete for BlogItems and related media until CloudKit sharing behavior is proven.

### DayPost and Gallery Derivation Rules

Status: **OPEN**

Decide the exact algorithms for deriving DayPosts, Galleries, itinerary summaries, and weather summaries. This should include timezone handling, boundary cases when BlogItem dates or locations change, and how settings affect existing display groupings.

### Email Publishing Format

Status: **OPEN**

Decide the generated HTML structure, image sizing policy, attachment or inline-image behavior, and whether v1 stores a `PublishEvent`. The email should be composed manually with native Apple mail UI and should not require a third-party mail provider.

### Dependency Injection and Test Strategy

Status: **OPEN**

Decide the testing seams for persistence, sync, location, WeatherKit, photo import, clocks, and mail composition. The likely direction is small protocols with fake implementations for unit tests and focused integration tests for database behavior.

### Entitlements and Apple Service Setup

Status: **OPEN**

Decide and document the required Apple capabilities and privacy strings for CloudKit, WeatherKit, location, photo library access, and mail composition. This should include development versus production CloudKit setup and any manual Apple Developer configuration steps.

## References

- `Product Requirements Document.md`
- `.agents/skills/axiom-data/SKILL.md`
- `.agents/skills/axiom-data/skills/sqlitedata.md`
- `.agents/skills/axiom-data/skills/cloud-sync.md`
- `.agents/skills/axiom-data/skills/cloudkit-ref.md`
- `.agents/skills/axiom-data/skills/storage.md`
- `.agents/skills/axiom-swiftui/SKILL.md`
- `.agents/skills/axiom-design/SKILL.md`
- `/Users/rog/.agents/skills/axiom-uikit/SKILL.md`

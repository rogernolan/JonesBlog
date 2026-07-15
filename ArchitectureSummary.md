# InstaBlog Architecture Summary

This file is the short architecture brief for agents working in the InstaBlog repository.

Read this before broad architecture work. Do not read DesignDecisions.md, the PRD, or feature design docs unless the task directly requires deeper product or architectural context.

##Product Shape

InstaBlog is a native iOS/iPadOS app written in Swift and SwiftUI.

The app lets a small trusted group create shared travel blog entries. BlogItems can contain text and multiple photos, are enriched with location and weather, are grouped into derived DayPosts, and are manually sent as HTML email to a shared subscriber list.

V1 is in-house only for Rog and Jane. Permissions are deliberately flat: every Blogger can edit all shared Blog data.

##Core Architecture

Use a simple native Apple architecture.

* SwiftUI is the primary UI stack.
* UIKit is used only for Apple interoperability surfaces such as mail composition and CloudKit sharing.
* Business logic stays out of SwiftUI view bodies.
* Views call small injected services or focused view models.
* Do not add a repository layer unless implementation reveals real repeated mapping/query complexity.
* Do not add architectural frameworks without explicit approval.

##Persistence and Sync

Accepted v1 decision:

* Primary local persistence: SQLiteData backed by SQLite/GRDB.
* Sync and sharing: CloudKit SyncEngine.
* Blog is the CloudKit share root.
* Blog-owned records are shared through CloudKit.
* Local-first writes are required.
* UI should show local data immediately and indicate pending or failed sync where relevant.

Do not replace this with SwiftData, Core Data, Firebase, Supabase, a custom backend, or another persistence architecture unless Rog/Jane explicitly asks for a new decision.

##Main Data Model

Persisted model concepts:

* Blog: one complete shared workspace.
* Blogger: contributor identity within a Blog.
* BlogItem: atomic authored entry with blog text and/or photos, item date, location, weather, author, and sync metadata.
* PhotoItem: one photo in a BlogItem, with its MediaAsset reference, photo caption, and photo date.
* MediaAsset: metadata for a photo associated with a PhotoItem or Trip.
* Trip: user-defined local-day date range with title, description, and optional hero image.
* MailingList: the single shared mailing list for v1.
* Subscriber: recipient in the shared mailing list.
* PublishEvent: record that a DayPost email send was initiated.

Derived, not persisted in v1:

* DayPost
* Unassigned Trip

##Important Model Rules

* A BlogItem must have at least blog text or one PhotoItem.
* DayPosts are derived directly from non-deleted BlogItems grouped by `localDay`/`itemDate`; they are never persisted.
* PhotoItems are ordered by `photoDate`, then `createdAt`, then `id`.
* PhotoItems are hard-deleted. Their MediaAsset and local file are removed only when no PhotoItem or Trip references the asset.
* A Trip owns no BlogItems. Its visible entries are derived by querying BlogItems whose local days fall inside its date range.
* BlogItems outside every Trip date range appear in the derived Unassigned Trip.
* Trips must not overlap within a Blog.
* Only one Trip may be open at a time.
* There is exactly one MailingList per Blog in v1.
* Subscriber email should be unique within that MailingList where practical.
* BlogItems use soft deletion for sync conflict tolerance.

##Storage Locations

Use:

* Library/Application Support for the SQLite database.
* Library/Application Support for durable local originals while upload is pending.
* CloudKit external assets for shared photo transfer; full originals are never SQLite BLOBs.
* Library/Caches for generated thumbnails and email-sized renders.
* tmp for temporary image processing and mail-composition files.

No user-created Blog data should exist only in Caches or tmp.

##Service Boundaries

Use protocol-based dependency injection for system-facing capabilities:

* persistence
* sync
* sharing
* location
* reverse geocoding
* WeatherKit
* photo import/media processing
* mail composition
* clock/date handling
* file-system side effects

Tests should use fake implementations and avoid real CloudKit, WeatherKit, location, photo library, mail, clock, or file-system side effects unless explicitly doing integration/manual testing.

##Sharing

Accepted v1 sharing model:

* Blog is the single CloudKit share root.
* Shares are invite-only.
* Accepted participants receive read/write access.
* Accepting a shared Blog preserves but hides any meaningful local Blog.
* An untouched bootstrap Blog may be hidden without warning.
* Active Blog selection is private workspace state and must not be part of shared Blog data.
* Participant management beyond showing a placeholder “Manage Sharing” message is out of scope for the current sharing iteration.

##Media

MediaAsset.localOriginalPath is device-local and must not be treated as shared data.

Shared photo transfer uses external CloudKit assets. SQLite stores only the stable media identifier, content hash, local file reference, and remote asset identifier/hash.

Image loading may prefer a durable local file when available, but must fall back to synchronized bytes.

##Publishing

V1 publishing means manual email composition only.

* Generate simple HTML email.
* Use native Apple mail composition.
* Include inline/scaled images suitable for Apple Mail, Gmail, and Outlook-family clients.
* Do not add a third-party mail provider or SMTP service.
* If mail composition is unavailable, show a clear in-app message.

Website publishing is future work and out of scope for v1.

##Dependency Policy

Prefer Apple frameworks and standard library APIs.

SQLiteData is already approved.

Any new external dependency requires explicit approval from Rog/Jane and must use Swift Package Manager. Do not use CocoaPods, Carthage, or vendored third-party source.

##Testing Posture

Add tests proportional to risk.

Prioritise unit tests for:

* model rules
* persistence logic
* derived Trip and DayPost behaviour
* multi-photo ordering and orphan cleanup
* sharing state mapping
* active Blog switching
* Blogger identity idempotency
* external media file persistence and asset sync status
* publishing duplicate/resend logic

Use UI tests only for critical user-visible flows where behaviour changes visibly.

##Agent Context Discipline

For ordinary implementation tasks, inspect narrowly:

1. issue text
2. current git status/diff
3. directly relevant source and test files
4. this summary

Read larger docs only when required:

* PRD: product requirement ambiguity
* DesignDecisions.md: durable architecture/storage/sync/publishing decisions
* feature design docs: the task is explicitly part of that feature
* Axiom/Superpowers skills: only when the task genuinely needs that guidance

Do not reread large docs by default.

# Data Storage Layer Design

Date: 2026-06-22

Issues: [#4 Core persistence models](https://github.com/rogernolan/JonesBlog/issues/4), [#5 First-run blog bootstrap](https://github.com/rogernolan/JonesBlog/issues/5)

## Objective

Implement InstaBlog's first local persistence slice using SQLiteData. This slice defines the v1 persisted model types, creates and migrates the local SQLite database, and idempotently bootstraps a usable local Blog workspace.

The schema must be ready for SQLiteData's CloudKit SyncEngine later, but this slice does not configure or run CloudKit synchronization or sharing.

## Scope

The implementation includes:

- SQLiteData as an approved Swift Package Manager dependency.
- Persisted `Blog`, `Blogger`, `BlogItem`, `MediaAsset`, `Trip`, `MailingList`, `Subscriber`, and `PublishEvent` value types.
- The fields, constraints, and indexes recorded in `DesignDecisions.md`.
- An explicit initial database migration.
- A production database stored in `Library/Application Support`.
- In-memory database creation for deterministic tests.
- A small bootstrap service that creates or recovers the initial local Blog workspace.
- Focused model, schema, and bootstrap tests.

This slice excludes:

- CloudKit SyncEngine setup, upload, download, sharing, and sync-status UI.
- Contacts permission or automatic lookup of the Blogger's name.
- Onboarding and editing of bootstrap names.
- Media file copying, caching, upload, or eviction.
- DayPost, Gallery, itinerary, weather-summary, and Unassigned Trip derivation.
- Trip management and overlap workflows.
- Location or weather enrichment.
- App-screen integration beyond any minimal database preparation required at app launch.

## Architecture

SQLiteData `@Table` value types are also the app's persisted domain models. This avoids a second set of persistence records and the mapping or repository layer that would accompany them. Views and later workflows will access persistence through small injected services rather than writing database operations in SwiftUI view bodies.

An `AppDatabase` factory owns database creation and migration:

- Production creates the database in the app's Application Support directory.
- Tests create isolated in-memory databases.
- Both paths run the same explicit migrations.

A `BlogBootstrapService` owns first-run setup. Its live implementation receives a database connection, clock, and ID generator. These dependencies make generated records exact and testable while preserving ordinary random IDs and the current time in production.

CloudKit remains a later concern. Model identifiers and SQLiteData sync metadata identifiers are included now so the same records can participate in SyncEngine without replacing the local schema.

## Persisted Models

The eight table models follow the accepted v1 shape in `DesignDecisions.md`:

- `Blog` stores its identity, title, timestamps, gallery interval, gallery distance, and sync metadata identifier.
- `Blogger` stores its Blog relationship, display name, timestamps, optional CloudKit participant identifier, and sync metadata identifier.
- `BlogItem` stores authorship, content, absolute and local date context, optional location and weather, optional photo relationship, soft-deletion time, timestamps, and sync metadata identifier.
- `MediaAsset` stores its Blog relationship, photo metadata, optional local and CloudKit references, dimensions, timestamps, and sync metadata identifier.
- `Trip` stores its Blog relationship, title, description, local-day range, optional hero image, closure time, timestamps, and sync metadata identifier.
- `MailingList` stores its Blog relationship, name, timestamps, and sync metadata identifier.
- `Subscriber` stores its Blog and MailingList relationships, email address, optional display name, timestamps, and sync metadata identifier.
- `PublishEvent` stores the Blog, optional Trip, local day, MailingList, initiating Blogger, initiation time, recipient count, and sync metadata identifier.

Galleries, DayPosts, and the Unassigned Trip remain derived values and do not receive tables.

## Defaults and Validation

Defaults are named constants rather than values hidden in database or UI code:

- Blog title: `My Blog`
- Blogger display name: `Me`
- MailingList name: `Subscribers`
- Gallery interval: 900 seconds
- Gallery distance: 500 metres
- Media kind: `photo`

Bootstrap does not request Contacts access. A later onboarding flow may offer to replace `Me` with the Contacts Me-card name after an explicit user action and permission grant.

Validation reports focused typed errors before a write:

- A BlogItem must have a nonblank caption or a photo asset identifier.
- A BlogItem's `itemDate` must be less than or equal to the injected current time.
- A MediaAsset must use the v1 `photo` kind.
- A Subscriber email address must be nonblank and unique within its MailingList, compared case-insensitively.

The initial database schema also enforces invariants that are stable and local to a row or index. These include BlogItem content, one MailingList per Blog, supported media kind, and case-insensitive Subscriber uniqueness. The no-future-date rule remains write-boundary validation because a time-dependent database constraint can interact poorly with device clock skew and later remote imports.

Trip overlap validation belongs to the Trip management workflow in issue #11 because it requires a query across records. The initial schema supplies the indexes needed for that workflow.

## Schema and Migrations

The first migration creates all eight tables and the indexes documented in `DesignDecisions.md`:

- `BlogItem(blogID, localDay, itemDate)`
- `BlogItem(blogID, itemDate)`
- `BlogItem(authorID)`
- `Trip(blogID, startLocalDay, endLocalDay)`
- `MailingList(blogID)`
- `Subscriber(mailingListID, emailAddress)`
- `PublishEvent(blogID, localDay)`
- `PublishEvent(mailingListID, initiatedAt)`
- `MediaAsset(blogID)`

The migration additionally creates unique indexes for one MailingList per Blog and case-insensitive Subscriber email addresses per MailingList. Relationship columns are explicit and indexed, but the initial schema does not add SQLite foreign-key constraints. Application write workflows enforce relationship validity so that later CloudKit imports are not rejected merely because related records arrive in a different order.

The initial migration becomes immutable once shipped. Later schema changes must use new additive migrations and preserve existing data.

## Bootstrap Data Flow

The bootstrap operation runs in one database transaction:

1. Find the existing local Blog or insert `My Blog` using the injected ID and time.
2. Find a Blogger for that Blog or insert `Me`.
3. Find the Blog's MailingList or insert `Subscribers`.
4. Return a `BootstrapWorkspace` value containing the three persisted records.

Running bootstrap repeatedly returns the same records and does not duplicate data. If a prior launch created the Blog but not one of its dependent records, bootstrap creates only the missing Blogger or MailingList. Any failure rolls back the entire transaction.

Bootstrap does not attempt to merge multiple Blogs or select among shared Blogs. Those behaviors belong to the later CloudKit sharing and acceptance flows.

## Error Handling

Model validation errors are specific and equatable where practical so callers and tests can distinguish empty BlogItem content, a future BlogItem date, unsupported media, invalid Subscriber input, and duplicate Subscriber addresses.

Database opening, migration, and transaction errors preserve their underlying SQLite error information. Startup code must not silently replace or delete a database after a migration failure. A bootstrap transaction failure leaves the store unchanged.

## Testing

Swift Testing coverage uses in-memory databases and injected IDs and timestamps. It verifies:

- Exact model and bootstrap defaults.
- BlogItem validation for missing content, whitespace-only captions, caption content, photo-only content, and caption-plus-photo content.
- BlogItem dates before, equal to, and after the injected current time.
- Photo-only media validation.
- Subscriber email uniqueness ignoring case within one MailingList and allowance of the same address in a different list.
- Fresh migration creation of the expected tables, columns, indexes, and constraints.
- Constraint enforcement when callers bypass model validation.
- Empty-store bootstrap creation of exactly one Blog, Blogger, and MailingList.
- Repeated bootstrap returning the original records without changing table counts.
- Partial-store bootstrap creating only missing dependent records.
- Transaction rollback when bootstrap fails.

No UI tests are added because this slice introduces no visible user behavior. Final verification uses the narrowest relevant `xcodebuild test` command against an iOS 26.5 simulator.

## Completion Criteria

The slice is complete when issues #4 and #5's acceptance criteria pass, the local database is created in the correct durable location, tests demonstrate the schema and idempotent bootstrap behavior, and the existing app and unit-test target build successfully without CloudKit configuration.

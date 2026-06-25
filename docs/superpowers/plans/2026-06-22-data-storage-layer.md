# Data Storage Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the SQLiteData-backed v1 persistence models, durable local database, validation, and idempotent first-run Blog bootstrap required by issues #4 and #5.

**Architecture:** SQLiteData `@Table` structs are the persisted domain models. `AppDatabase` owns one explicit initial migration and creates either a durable Application Support database or an isolated in-memory test database; focused validators protect workflow rules, and `BlogBootstrapService` creates the neutral default workspace in one transaction.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, SQLiteData 1.6.6, GRDB APIs re-exported by SQLiteData, Xcode 26.5, iOS 26.5.

---

## File Map

- Modify `InstaBlog/InstaBlog.xcodeproj/project.pbxproj`: add and link SQLiteData.
- Create `InstaBlog/InstaBlog/PersistenceModels.swift`: eight `@Table` value types and stable defaults.
- Create `InstaBlog/InstaBlog/ModelValidation.swift`: typed row-local validation.
- Create `InstaBlog/InstaBlog/AppDatabase.swift`: live/in-memory connections and initial migration.
- Create `InstaBlog/InstaBlog/SubscriberValidator.swift`: normalized per-list email uniqueness.
- Create `InstaBlog/InstaBlog/BlogBootstrapService.swift`: idempotent default workspace creation.
- Modify `InstaBlog/InstaBlog/InstaBlogApp.swift`: prepare SQLiteData and bootstrap at launch.
- Create focused test files matching each production file under `InstaBlog/InstaBlogTests/`.
- Modify `DesignDecisions.md`: record date validation and computed sync metadata behavior.

### Task 1: Add and pin SQLiteData

**Files:**
- Modify: `InstaBlog/InstaBlog.xcodeproj/project.pbxproj`
- Create: `InstaBlog/InstaBlog.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (generated)

- [ ] **Step 1: Add the package reference and product dependency**

Add `XCRemoteSwiftPackageReference` for `https://github.com/pointfreeco/sqlite-data` with `upToNextMinorVersion = 1.6.6`. Add `XCSwiftPackageProductDependency` named `SQLiteData`, then reference it from the InstaBlog target's Frameworks phase and `packageProductDependencies`. Add the package reference to `PBXProject.packageReferences`. Do not add direct test-target linkage.

- [ ] **Step 2: Resolve and verify the package**

```bash
xcodebuild -resolvePackageDependencies -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog
```

Expected: exit 0, SQLiteData 1.6.6 appears, and `Package.resolved` is created.

- [ ] **Step 3: Verify the app builds**

```bash
xcodebuild build -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add InstaBlog/InstaBlog.xcodeproj/project.pbxproj \
  InstaBlog/InstaBlog.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "Add SQLiteData dependency"
```

### Task 2: Define persisted models and row-local validation

**Files:**
- Create: `InstaBlog/InstaBlog/PersistenceModels.swift`
- Create: `InstaBlog/InstaBlog/ModelValidation.swift`
- Create: `InstaBlog/InstaBlogTests/PersistenceModelTests.swift`

- [ ] **Step 1: Write failing model tests**

Create Swift Testing suites that use fixed UUIDs and dates and assert:

```swift
let now = Date(timeIntervalSince1970: 1_750_000_000)
let blogID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let blog = Blog(id: blogID, createdAt: now, updatedAt: now)
#expect(blog.title == "My Blog")
#expect(blog.galleryIntervalSeconds == 900)
#expect(blog.galleryDistanceMeters == 500)
#expect(BootstrapDefaults.bloggerDisplayName == "Me")
#expect(BootstrapDefaults.mailingListName == "Subscribers")
```

Add BlogItem tests for nil/empty/whitespace captions without photos, caption content, photo-only content, dates before/equal to/after `now`, and MediaAsset kinds `photo`/`video`. Prove computed sync metadata with `#expect(blog.syncMetadataID == SyncMetadata.ID(recordPrimaryKey: blog.id.uuidString, recordType: Blog.tableName))`.

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' \
  -only-testing:InstaBlogTests/PersistenceModelDefaultTests \
  -only-testing:InstaBlogTests/BlogItemValidationTests
```

Expected: compile failure because the models do not exist.

- [ ] **Step 3: Implement the table models**

Create the following exact shapes as `@Table nonisolated struct`, each conforming to `Hashable, Identifiable`:

```swift
enum BootstrapDefaults {
    static let blogTitle = "My Blog"
    static let bloggerDisplayName = "Me"
    static let mailingListName = "Subscribers"
    static let galleryIntervalSeconds = 900
    static let galleryDistanceMeters = 500.0
}

@Table nonisolated struct Blog: Hashable, Identifiable {
    let id: UUID; var title = BootstrapDefaults.blogTitle
    var createdAt: Date; var updatedAt: Date
    var galleryIntervalSeconds = BootstrapDefaults.galleryIntervalSeconds
    var galleryDistanceMeters = BootstrapDefaults.galleryDistanceMeters
}
@Table nonisolated struct Blogger: Hashable, Identifiable {
    let id: UUID; var blogID: Blog.ID; var displayName = BootstrapDefaults.bloggerDisplayName
    var createdAt: Date; var updatedAt: Date; var cloudKitParticipantIdentifier: String?
}
@Table nonisolated struct BlogItem: Hashable, Identifiable {
    let id: UUID; var blogID: Blog.ID; var authorID: Blogger.ID; var caption: String?
    var createdAt: Date; var updatedAt: Date; var itemDate: Date
    var itemTimeZoneIdentifier: String?; var localDay: String
    var latitude: Double?; var longitude: Double?; var locationName: String?; var countryCode: String?
    var weatherTemperatureCelsius: Double?; var weatherConditionCode: String?
    var photoAssetID: MediaAsset.ID?; var deletedAt: Date?
}
@Table nonisolated struct MediaAsset: Hashable, Identifiable {
    let id: UUID; var blogID: Blog.ID; var kind = "photo"
    var localOriginalPath: String?; var cloudAssetIdentifier: String?
    var filename: String; var mimeType: String; var pixelWidth: Int?; var pixelHeight: Int?
    var createdAt: Date; var updatedAt: Date
}
@Table nonisolated struct Trip: Hashable, Identifiable {
    let id: UUID; var blogID: Blog.ID; var title: String; var description: String
    var startLocalDay: String; var endLocalDay: String?; var heroImageAssetID: MediaAsset.ID?
    var createdAt: Date; var updatedAt: Date; var closedAt: Date?
}
@Table nonisolated struct MailingList: Hashable, Identifiable {
    let id: UUID; var blogID: Blog.ID; var name = BootstrapDefaults.mailingListName
    var createdAt: Date; var updatedAt: Date
}
@Table nonisolated struct Subscriber: Hashable, Identifiable {
    let id: UUID; var blogID: Blog.ID; var mailingListID: MailingList.ID
    var emailAddress: String; var displayName: String?; var createdAt: Date; var updatedAt: Date
}
@Table nonisolated struct PublishEvent: Hashable, Identifiable {
    let id: UUID; var blogID: Blog.ID; var tripID: Trip.ID?; var localDay: String
    var mailingListID: MailingList.ID; var initiatedAt: Date
    var initiatedByBloggerID: Blogger.ID; var recipientCount: Int
}
```

Use the defaults above for Blog title/settings, Blogger name, MediaAsset kind (`photo`), and MailingList name. Use UUID primary keys so SQLiteData 1.6.6 computes `syncMetadataID`; do not persist that computed identifier as a column.

- [ ] **Step 4: Implement typed validation**

```swift
nonisolated enum ModelValidationError: Error, Equatable {
    case missingBlogItemContent
    case futureBlogItemDate
    case unsupportedMediaKind(String)
    case emptySubscriberEmail
    case duplicateSubscriberEmail
}

nonisolated extension BlogItem {
    func validate(relativeTo now: Date) throws {
        let hasCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasCaption || photoAssetID != nil else {
            throw ModelValidationError.missingBlogItemContent
        }
        guard itemDate <= now else { throw ModelValidationError.futureBlogItemDate }
    }
}

nonisolated extension MediaAsset {
    func validate() throws {
        guard kind == "photo" else { throw ModelValidationError.unsupportedMediaKind(kind) }
    }
}
```

- [ ] **Step 5: Run and verify GREEN**

Run Step 2's command. Expected: all model/default/validation tests pass.

- [ ] **Step 6: Commit**

```bash
git add InstaBlog/InstaBlog/PersistenceModels.swift InstaBlog/InstaBlog/ModelValidation.swift \
  InstaBlog/InstaBlogTests/PersistenceModelTests.swift
git commit -m "Add core persistence models"
```

### Task 3: Create and verify the initial schema

**Files:**
- Create: `InstaBlog/InstaBlog/AppDatabase.swift`
- Create: `InstaBlog/InstaBlogTests/AppDatabaseTests.swift`

- [ ] **Step 1: Write failing schema tests**

Use `try AppDatabase.makeInMemory()` and assert all eight table names exist. Query `sqlite_master` for the eleven named indexes below. Add direct insert tests proving SQLite rejects a contentless BlogItem, non-photo MediaAsset, second MailingList for a Blog, and case-variant duplicate Subscriber.

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' \
  -only-testing:InstaBlogTests/AppDatabaseTests
```

Expected: compile failure because `AppDatabase` does not exist.

- [ ] **Step 3: Implement database factories**

```swift
nonisolated enum AppDatabase {
    static func makeLive(fileManager: FileManager = .default) throws -> any DatabaseWriter {
        let directory = try fileManager.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let database = try DatabasePool(path: directory.appending(path: "InstaBlog.sqlite").path())
        try migrator.migrate(database)
        return database
    }

    static func makeInMemory() throws -> any DatabaseWriter {
        let database = try DatabaseQueue()
        try migrator.migrate(database)
        return database
    }

    static var migrator: DatabaseMigrator {
        var value = DatabaseMigrator()
        value.registerMigration("001 Create v1 persistence schema") { db in
            try createV1Schema(in: db)
        }
        return value
    }
}
```

- [ ] **Step 4: Implement the migration**

Create eight `STRICT` tables whose columns exactly match Task 2. UUIDs and Dates use `TEXT`, Int uses `INTEGER`, Double uses `REAL`; required fields are `NOT NULL`. Add stable defaults only for Blog title/settings, Blogger name, MediaAsset kind, and MailingList name. Add:

```sql
CREATE TABLE "blogs" (
  "id" TEXT PRIMARY KEY NOT NULL, "title" TEXT NOT NULL DEFAULT 'My Blog',
  "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
  "galleryIntervalSeconds" INTEGER NOT NULL DEFAULT 900,
  "galleryDistanceMeters" REAL NOT NULL DEFAULT 500
) STRICT;
CREATE TABLE "bloggers" (
  "id" TEXT PRIMARY KEY NOT NULL, "blogID" TEXT NOT NULL,
  "displayName" TEXT NOT NULL DEFAULT 'Me', "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL, "cloudKitParticipantIdentifier" TEXT
) STRICT;
CREATE TABLE "blogItems" (
  "id" TEXT PRIMARY KEY NOT NULL, "blogID" TEXT NOT NULL, "authorID" TEXT NOT NULL,
  "caption" TEXT, "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL,
  "itemDate" TEXT NOT NULL, "itemTimeZoneIdentifier" TEXT, "localDay" TEXT NOT NULL,
  "latitude" REAL, "longitude" REAL, "locationName" TEXT, "countryCode" TEXT,
  "weatherTemperatureCelsius" REAL, "weatherConditionCode" TEXT,
  "photoAssetID" TEXT, "deletedAt" TEXT,
  CHECK ("photoAssetID" IS NOT NULL OR length(trim(coalesce("caption", ''))) > 0)
) STRICT;
CREATE TABLE "mediaAssets" (
  "id" TEXT PRIMARY KEY NOT NULL, "blogID" TEXT NOT NULL,
  "kind" TEXT NOT NULL DEFAULT 'photo' CHECK ("kind" = 'photo'),
  "localOriginalPath" TEXT, "cloudAssetIdentifier" TEXT,
  "filename" TEXT NOT NULL, "mimeType" TEXT NOT NULL,
  "pixelWidth" INTEGER, "pixelHeight" INTEGER,
  "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL
) STRICT;
CREATE TABLE "trips" (
  "id" TEXT PRIMARY KEY NOT NULL, "blogID" TEXT NOT NULL,
  "title" TEXT NOT NULL, "description" TEXT NOT NULL,
  "startLocalDay" TEXT NOT NULL, "endLocalDay" TEXT, "heroImageAssetID" TEXT,
  "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL, "closedAt" TEXT
) STRICT;
CREATE TABLE "mailingLists" (
  "id" TEXT PRIMARY KEY NOT NULL, "blogID" TEXT NOT NULL,
  "name" TEXT NOT NULL DEFAULT 'Subscribers', "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL
) STRICT;
CREATE TABLE "subscribers" (
  "id" TEXT PRIMARY KEY NOT NULL, "blogID" TEXT NOT NULL, "mailingListID" TEXT NOT NULL,
  "emailAddress" TEXT NOT NULL, "displayName" TEXT,
  "createdAt" TEXT NOT NULL, "updatedAt" TEXT NOT NULL
) STRICT;
CREATE TABLE "publishEvents" (
  "id" TEXT PRIMARY KEY NOT NULL, "blogID" TEXT NOT NULL, "tripID" TEXT,
  "localDay" TEXT NOT NULL, "mailingListID" TEXT NOT NULL,
  "initiatedAt" TEXT NOT NULL, "initiatedByBloggerID" TEXT NOT NULL,
  "recipientCount" INTEGER NOT NULL
) STRICT;
```

Do not create a time-dependent date check, foreign-key constraints, or sync metadata columns. Create:

```sql
CREATE INDEX "blogItems_blogID_localDay_itemDate" ON "blogItems"("blogID","localDay","itemDate");
CREATE INDEX "blogItems_blogID_itemDate" ON "blogItems"("blogID","itemDate");
CREATE INDEX "blogItems_authorID" ON "blogItems"("authorID");
CREATE INDEX "trips_blogID_startLocalDay_endLocalDay" ON "trips"("blogID","startLocalDay","endLocalDay");
CREATE INDEX "mailingLists_blogID" ON "mailingLists"("blogID");
CREATE INDEX "subscribers_mailingListID_emailAddress" ON "subscribers"("mailingListID","emailAddress");
CREATE INDEX "publishEvents_blogID_localDay" ON "publishEvents"("blogID","localDay");
CREATE INDEX "publishEvents_mailingListID_initiatedAt" ON "publishEvents"("mailingListID","initiatedAt");
CREATE INDEX "mediaAssets_blogID" ON "mediaAssets"("blogID");
CREATE UNIQUE INDEX "mailingLists_blogID_unique" ON "mailingLists"("blogID");
CREATE UNIQUE INDEX "subscribers_list_email_unique" ON "subscribers"("mailingListID","emailAddress" COLLATE NOCASE);
```

- [ ] **Step 5: Run and verify GREEN**

Run Step 2's command. Expected: all schema and constraint tests pass.

- [ ] **Step 6: Commit**

```bash
git add InstaBlog/InstaBlog/AppDatabase.swift InstaBlog/InstaBlogTests/AppDatabaseTests.swift
git commit -m "Create initial SQLiteData schema"
```

### Task 4: Add Subscriber uniqueness validation

**Files:**
- Create: `InstaBlog/InstaBlog/SubscriberValidator.swift`
- Create: `InstaBlog/InstaBlogTests/SubscriberValidatorTests.swift`

- [ ] **Step 1: Write failing validator tests**

Seed two MailingLists in different Blogs and assert trimming, empty rejection, case-insensitive duplicate rejection within one list, allowance in the other list, and allowance when editing the same Subscriber via `excluding:`.

```swift
let validator = SubscriberValidator(database: database)
#expect(try validator.validatedEmail("  Rog@example.com ", mailingListID: first.id)
    == "Rog@example.com")
#expect(throws: ModelValidationError.duplicateSubscriberEmail) {
    try validator.validatedEmail("rog@EXAMPLE.com", mailingListID: first.id)
}
#expect(throws: ModelValidationError.emptySubscriberEmail) {
    try validator.validatedEmail(" \n ", mailingListID: second.id)
}
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' \
  -only-testing:InstaBlogTests/SubscriberValidatorTests
```

Expected: compile failure because `SubscriberValidator` does not exist.

- [ ] **Step 3: Implement the validator**

```swift
nonisolated struct SubscriberValidator {
    let database: any DatabaseReader

    func validatedEmail(
        _ emailAddress: String,
        mailingListID: MailingList.ID,
        excluding subscriberID: Subscriber.ID? = nil
    ) throws -> String {
        let email = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw ModelValidationError.emptySubscriberEmail }
        let duplicate = try database.read { db in
            try Subscriber.where {
                $0.mailingListID.eq(#bind(mailingListID))
                    && #sql("lower(\($0.emailAddress)) = lower(\(bind: email))")
                    && (subscriberID.map { id in $0.id.neq(#bind(id)) } ?? true)
            }.fetchCount(db) > 0
        }
        guard !duplicate else { throw ModelValidationError.duplicateSubscriberEmail }
        return email
    }
}
```

- [ ] **Step 4: Run and verify GREEN**

Run Step 2's command and Task 3's schema tests. Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add InstaBlog/InstaBlog/SubscriberValidator.swift \
  InstaBlog/InstaBlogTests/SubscriberValidatorTests.swift
git commit -m "Validate subscriber email uniqueness"
```

### Task 5: Implement idempotent first-run bootstrap

**Files:**
- Create: `InstaBlog/InstaBlog/BlogBootstrapService.swift`
- Create: `InstaBlog/InstaBlogTests/BlogBootstrapServiceTests.swift`

- [ ] **Step 1: Write failing bootstrap tests**

Using fixed dates and a UUID iterator, verify: empty store creates one of each record with neutral names; a second call returns equal records and consumes no IDs; Blog-only and Blog-plus-Blogger stores create only missing dependents; and a temporary `BEFORE INSERT ON bloggers` trigger that raises `ABORT` rolls the entire transaction back to zero rows.

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' \
  -only-testing:InstaBlogTests/BlogBootstrapServiceTests
```

Expected: compile failure because bootstrap types do not exist.

- [ ] **Step 3: Implement bootstrap types**

```swift
nonisolated struct BootstrapWorkspace: Equatable {
    let blog: Blog
    let blogger: Blogger
    let mailingList: MailingList
}

struct BlogBootstrapService {
    let database: any DatabaseWriter
    var now: () -> Date = Date.init
    var uuid: () -> UUID = UUID.init

    func bootstrap() throws -> BootstrapWorkspace {
        let timestamp = now()
        return try database.write { db in
            let blog: Blog
            if let existing = try Blog.order(by: \.createdAt).fetchOne(db) {
                blog = existing
            } else {
                blog = Blog(id: uuid(), createdAt: timestamp, updatedAt: timestamp)
                try Blog.insert { blog }.execute(db)
            }

            let blogger: Blogger
            if let existing = try Blogger.where({ $0.blogID.eq(#bind(blog.id)) })
                .order(by: \.createdAt).fetchOne(db) {
                blogger = existing
            } else {
                blogger = Blogger(id: uuid(), blogID: blog.id,
                    createdAt: timestamp, updatedAt: timestamp)
                try Blogger.insert { blogger }.execute(db)
            }

            let mailingList: MailingList
            if let existing = try MailingList.where({ $0.blogID.eq(#bind(blog.id)) }).fetchOne(db) {
                mailingList = existing
            } else {
                mailingList = MailingList(id: uuid(), blogID: blog.id,
                    createdAt: timestamp, updatedAt: timestamp)
                try MailingList.insert { mailingList }.execute(db)
            }
            return BootstrapWorkspace(blog: blog, blogger: blogger, mailingList: mailingList)
        }
    }
}
```

- [ ] **Step 4: Run and verify GREEN**

Run Step 2's command. Expected: all bootstrap and rollback tests pass.

- [ ] **Step 5: Commit**

```bash
git add InstaBlog/InstaBlog/BlogBootstrapService.swift \
  InstaBlog/InstaBlogTests/BlogBootstrapServiceTests.swift
git commit -m "Bootstrap the local Blog workspace"
```

### Task 6: Prepare persistence at launch and update decisions

**Files:**
- Modify: `InstaBlog/InstaBlog/AppDatabase.swift`
- Modify: `InstaBlog/InstaBlog/InstaBlogApp.swift`
- Modify: `InstaBlog/InstaBlogTests/AppDatabaseTests.swift`
- Modify: `DesignDecisions.md`

- [ ] **Step 1: Write a failing launch-preparation test**

Pass an in-memory database to `AppPersistence.prepare(database:)`, then assert that Blog, Blogger, and MailingList counts are one. Call it again and assert counts remain one.

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild test -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' \
  -only-testing:InstaBlogTests/AppPersistenceTests
```

Expected: compile failure because `AppPersistence` does not exist.

- [ ] **Step 3: Implement launch preparation**

```swift
enum AppPersistence {
    static func prepare(database: any DatabaseWriter) throws {
        _ = try BlogBootstrapService(database: database).bootstrap()
        prepareDependencies { $0.defaultDatabase = database }
    }
}
```

In `InstaBlogApp.init()`, call `try AppPersistence.prepare(database: AppDatabase.makeLive())`. Preserve the existing temporary SwiftData `ModelContainer` because `ContentView` on `main` still uses template `Item`; the parallel UX branch will remove it. On error, call `fatalError("Could not prepare app persistence: \(error)")` so migration failures never cause silent data replacement.

- [ ] **Step 4: Update durable decisions**

In `DesignDecisions.md`, add the no-future-date rule, clarify that `syncMetadataID` is computed by SQLiteData from the primary key and table name, and record that relationship validity is initially enforced at write boundaries instead of SQLite foreign-key constraints.

- [ ] **Step 5: Run all unit tests**

```bash
xcodebuild test -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' \
  -only-testing:InstaBlogTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add InstaBlog/InstaBlog/AppDatabase.swift InstaBlog/InstaBlog/InstaBlogApp.swift \
  InstaBlog/InstaBlogTests/AppDatabaseTests.swift DesignDecisions.md
git commit -m "Prepare local persistence at launch"
```

### Task 7: Final verification and human review

**Files:**
- Review all files changed from `main`

- [ ] **Step 1: Apply verification-before-completion**

Read and follow `superpowers:verification-before-completion` before making any completion claim.

- [ ] **Step 2: Verify dependency resolution**

```bash
xcodebuild -resolvePackageDependencies -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog
```

Expected: SQLiteData remains at 1.6.6 with no `Package.resolved` diff.

- [ ] **Step 3: Run the complete unit target and app build**

```bash
xcodebuild test -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' \
  -only-testing:InstaBlogTests
xcodebuild build -project InstaBlog/InstaBlog.xcodeproj -scheme InstaBlog \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro'
```

Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Inspect scope and hygiene**

```bash
git status --short
git diff --check main...HEAD
git diff --stat main...HEAD
git log --oneline main..HEAD
```

Expected: clean worktree, no whitespace errors, and only issues #4/#5 storage changes, docs, and package metadata.

- [ ] **Step 5: Request code review**

Read and follow `superpowers:requesting-code-review`, address validated findings, rerun Steps 2–4, then ask Rog to inspect the local diff. Do not push or open a PR until Rog explicitly approves it.

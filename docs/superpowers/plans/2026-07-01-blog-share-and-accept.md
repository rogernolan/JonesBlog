# Blog Share and Accept Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement tickets #21–#24 so a Blog owner can share the complete Blog and its photos from Settings, while invitees can safely accept, activate, and join the Blog as an idempotent Blogger.

**Architecture:** SQLiteData's `SyncEngine` synchronizes the Blog-rooted record graph and turns photo BLOBs into CloudKit assets. A protocol-backed sharing service isolates CloudKit and database orchestration, while an app-level acceptance coordinator stages scene-delivered invitations until the user confirms any required warning. SwiftUI presents Settings, alerts, progress, and SQLiteData's native `CloudSharingView`.

**Tech Stack:** Swift 6, SwiftUI, UIKit scene interoperability, CloudKit, SQLiteData 1.6.6, GRDB, Swift Testing, Xcode 26.5.

---

## File Structure

- `InstaBlog/InstaBlog/PersistenceModels.swift`: add `MediaAssetData` and private `AppWorkspace` row types.
- `InstaBlog/InstaBlog/AppDatabase.swift`: add migration 002, attach SQLiteData metadata, and construct the live sync engine.
- `InstaBlog/InstaBlog/BlogSharingService.swift`: define share state, service protocol, live SQLiteData implementation, meaningful-Blog query, active-Blog switching, and Blogger upsert.
- `InstaBlog/InstaBlog/ShareAcceptanceCoordinator.swift`: observable pending-invite state and cancel/confirm orchestration.
- `InstaBlog/InstaBlog/CloudKitSceneBridge.swift`: small `UIWindowSceneDelegate` bridge forwarding CloudKit metadata.
- `InstaBlog/InstaBlog/SettingsView.swift`: Settings sharing section, native sharing sheet, participant display-name editor, progress, and alerts.
- `InstaBlog/InstaBlog/InstaBlogApp.swift`: dependency construction, scene bridge registration, active-Blog loading, and acceptance presentation.
- `InstaBlog/InstaBlog/IPhoneShell.swift`: replace the Settings placeholder with `SettingsView`.
- `InstaBlog/InstaBlog/JournalService.swift`: persist synchronized photo bytes and load a received image when no durable file exists.
- `InstaBlog/InstaBlog/Info.plist`: declare `CKSharingSupported`.
- `InstaBlog/InstaBlog/InstaBlog.entitlements`: enable the approved CloudKit container.
- `InstaBlog/InstaBlog.xcodeproj/project.pbxproj`: reference Info.plist/entitlements only where Xcode does not auto-discover them.
- `InstaBlog/InstaBlogTests/AppDatabaseTests.swift`: migration, relationship, metadata, and asset storage coverage.
- `InstaBlog/InstaBlogTests/BlogSharingServiceTests.swift`: share-state, meaningful-Blog, activation, and Blogger identity coverage.
- `InstaBlog/InstaBlogTests/ShareAcceptanceCoordinatorTests.swift`: cancel, warning, direct accept, success, and failure coverage.
- `InstaBlog/InstaBlogTests/JournalServiceTests.swift`: photo byte persistence and fallback-loading coverage.
- `InstaBlog/InstaBlogTests/InstaBlogTests.swift`: Settings presentation-state coverage.
- `DesignDecisions.md`: record accepted implementation details for active workspace state and CloudKit-backed photo BLOBs.
- `docs/cloudkit-sharing-setup.md`: manual capability, container, schema, and two-account smoke-test instructions.

### Task 1: Add the Share-Compatible Persistence Shape

**Files:**
- Modify: `InstaBlog/InstaBlog/PersistenceModels.swift`
- Modify: `InstaBlog/InstaBlog/AppDatabase.swift`
- Modify: `InstaBlog/InstaBlogTests/AppDatabaseTests.swift`

- [ ] **Step 1: Write failing schema tests**

Add tests that assert migration 002 creates:

```swift
#expect(try tableNames(in: database).contains("mediaAssetData"))
#expect(try tableNames(in: database).contains("appWorkspaces"))
```

Assert `mediaAssetData.mediaAssetID` is its primary key and sole cascading foreign key to `mediaAssets(id)`, `appWorkspaces.id` is a singleton text primary key, and `appWorkspaces.activeBlogID` is nullable. Add a round-trip test inserting `Data([0x01, 0x02])` into `MediaAssetData` and reading the same bytes.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
rtk proxy xcodebuild test -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:'InstaBlogTests/AppDatabaseTests'
```

Expected: FAIL because the new tables and model types do not exist.

- [ ] **Step 3: Add the table models**

Add:

```swift
@Table
nonisolated struct MediaAssetData: Hashable, Identifiable {
    @Column(primaryKey: true)
    var mediaAssetID: MediaAsset.ID
    var data: Data
    var id: MediaAsset.ID { mediaAssetID }
}

@Table
nonisolated struct AppWorkspace: Hashable, Identifiable {
    let id: String
    var activeBlogID: Blog.ID?

    static let singletonID = "default"
}
```

- [ ] **Step 4: Add migration 002**

Register `002 Add sharing workspace and media data` after migration 001:

```sql
CREATE TABLE mediaAssetData (
  mediaAssetID TEXT PRIMARY KEY NOT NULL
    REFERENCES mediaAssets(id) ON DELETE CASCADE,
  data BLOB NOT NULL
) STRICT;

CREATE TABLE appWorkspaces (
  id TEXT PRIMARY KEY NOT NULL,
  activeBlogID TEXT
) STRICT;

INSERT INTO appWorkspaces (id, activeBlogID)
SELECT 'default', id FROM blogs ORDER BY createdAt LIMIT 1;
INSERT OR IGNORE INTO appWorkspaces (id, activeBlogID)
VALUES ('default', NULL);
```

Keep `activeBlogID` free of a SQL foreign-key constraint because `AppWorkspace` is a private table and must not become part of the shared Blog relationship graph.

- [ ] **Step 5: Run the focused tests**

Run the Task 1 command again.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add InstaBlog/InstaBlog/PersistenceModels.swift InstaBlog/InstaBlog/AppDatabase.swift InstaBlog/InstaBlogTests/AppDatabaseTests.swift
rtk git commit -m 'Add sharing workspace and media asset data'
```

### Task 2: Configure SQLiteData Cloud Sync and Share State

**Files:**
- Create: `InstaBlog/InstaBlog/BlogSharingService.swift`
- Modify: `InstaBlog/InstaBlog/AppDatabase.swift`
- Create: `InstaBlog/InstaBlogTests/BlogSharingServiceTests.swift`

- [ ] **Step 1: Write failing share-state mapping tests**

Define tests for this public app-facing state:

```swift
nonisolated enum BlogShareState: Equatable {
    case notShared
    case sharedOwner
    case sharedParticipant
    case unavailable(message: String)
    case error(message: String)
}
```

Test mapping from a small, CloudKit-free metadata value:

```swift
nonisolated struct BlogShareMetadata: Equatable {
    var isShared: Bool
    var currentUserIsOwner: Bool
    var currentUserCanWrite: Bool
}
```

Expected mappings: unshared → `.notShared`; shared owner → `.sharedOwner`; shared non-owner with write permission → `.sharedParticipant`; shared without write permission → `.unavailable(message:)`.

- [ ] **Step 2: Run the focused test and verify failure**

Run:

```bash
rtk proxy xcodebuild test -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:'InstaBlogTests/BlogSharingServiceTests'
```

Expected: FAIL because `BlogSharingService` and its state types do not exist.

- [ ] **Step 3: Define the service boundary**

Define:

```swift
@MainActor
protocol BlogSharingServiceProtocol {
    func shareState(for blogID: Blog.ID) async -> BlogShareState
    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord
    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool
    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog
    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws
}

nonisolated struct AcceptedBlog: Equatable {
    let blogID: Blog.ID
    let bloggerID: Blogger.ID
}
```

Keep `SharedRecord` and `CKShare.Metadata` only on the live boundary; coordinator tests will fake the whole protocol.

- [ ] **Step 4: Attach metadata and build the sync engine**

In the database configuration call:

```swift
try db.attachMetadatabase()
```

Construct one `SyncEngine` with:

```swift
SyncEngine(
    for: database,
    tables: Blog.self,
    Blogger.self,
    BlogItem.self,
    MediaAsset.self,
    MediaAssetData.self,
    Trip.self,
    MailingList.self,
    Subscriber.self,
    PublishEvent.self,
    privateTables: AppWorkspace.self
)
```

Expose the database and sync engine through a small `AppPersistence` value returned by live setup so every feature shares the same instances.

- [ ] **Step 5: Implement live share preparation and state mapping**

Query `SyncMetadata` using `Blog.syncMetadataID`. Treat a missing share as `.notShared`; compare the share owner/current participant metadata for owner and participant states. Prepare a share with:

```swift
try await syncEngine.share(record: blog) { share in
    share[CKShare.SystemFieldKey.title] = title as CKRecordValue
    share.publicPermission = .none
}
```

Ensure the native controller's default participant permission is read/write.

- [ ] **Step 6: Run focused tests**

Run the Task 2 command.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
rtk git add InstaBlog/InstaBlog/AppDatabase.swift InstaBlog/InstaBlog/BlogSharingService.swift InstaBlog/InstaBlogTests/BlogSharingServiceTests.swift
rtk git commit -m 'Configure Blog CloudKit sharing'
```

### Task 3: Implement Meaningful-Blog and Acceptance Semantics

**Files:**
- Modify: `InstaBlog/InstaBlog/BlogSharingService.swift`
- Modify: `InstaBlog/InstaBlogTests/BlogSharingServiceTests.swift`

- [ ] **Step 1: Add failing meaningful-Blog tests**

Create an in-memory workspace and verify:

- bootstrap defaults alone return `false`;
- a BlogItem returns `true`;
- a non-bootstrap Trip returns `true`;
- a Subscriber returns `true`;
- a PublishEvent returns `true`;
- changed Blog title, gallery interval, or gallery distance returns `true`;
- changed Blogger display name returns `true`.

- [ ] **Step 2: Add failing acceptance identity tests**

Using an internal acceptance seam that supplies accepted Blog and participant metadata, verify:

```swift
ParticipantIdentity(identifier: "ck-user-1", displayName: "Jane Jones")
```

creates one Blogger, repeated acceptance reuses it, a later display name updates it, and missing CloudKit names use `"Blogger"` without producing duplicates.

- [ ] **Step 3: Run focused tests and verify failure**

Run the Task 2 test command.

Expected: FAIL on meaningful-Blog and identity behavior.

- [ ] **Step 4: Implement meaningful-Blog queries**

Perform database existence/count queries scoped to `blogID`, and compare the root Blog/Blogger values with `BootstrapDefaults`. Treat development seed records as bootstrap only when they match the known seeded workspace rather than treating all Trips as user content.

- [ ] **Step 5: Implement live acceptance**

Call:

```swift
try await syncEngine.acceptShare(metadata: metadata)
try await syncEngine.syncChanges()
```

Resolve the shared root record identifier from the metadata/root record and fetch the matching local Blog. Derive a stable participant identifier from CloudKit user identity metadata when present. Inside one database transaction, find-or-insert/update the Blogger and update `AppWorkspace.singletonID.activeBlogID`. Do not change the workspace row before all preceding async CloudKit work succeeds.

- [ ] **Step 6: Run focused tests**

Run the Task 2 test command.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
rtk git add InstaBlog/InstaBlog/BlogSharingService.swift InstaBlog/InstaBlogTests/BlogSharingServiceTests.swift
rtk git commit -m 'Implement shared Blog acceptance'
```

### Task 4: Add the Pending Invitation Coordinator and Scene Bridge

**Files:**
- Create: `InstaBlog/InstaBlog/ShareAcceptanceCoordinator.swift`
- Create: `InstaBlog/InstaBlog/CloudKitSceneBridge.swift`
- Create: `InstaBlog/InstaBlogTests/ShareAcceptanceCoordinatorTests.swift`
- Modify: `InstaBlog/InstaBlog/InstaBlogApp.swift`

- [ ] **Step 1: Write failing coordinator tests**

Use a fake `BlogSharingServiceProtocol` and test:

- an empty Blog begins acceptance without presenting a warning;
- a meaningful Blog exposes `.confirmation(blogTitle:)`;
- cancel clears the pending invite and makes no service acceptance call;
- confirm accepts once and publishes `.accepted(AcceptedBlog)`;
- failure publishes `.error(message:)` and preserves the old active Blog in the fake;
- repeated confirm taps while loading call accept once.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
rtk proxy xcodebuild test -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:'InstaBlogTests/ShareAcceptanceCoordinatorTests'
```

Expected: FAIL because the coordinator does not exist.

- [ ] **Step 3: Implement coordinator state**

Use:

```swift
@MainActor
@Observable
final class ShareAcceptanceCoordinator {
    enum Presentation: Equatable {
        case none
        case confirmation(blogTitle: String)
        case accepting
        case accepted(AcceptedBlog)
        case error(message: String)
    }
}
```

Store pending metadata privately. `receive(metadata:activeBlogID:)` evaluates meaningful use, `cancel()` clears it, and `confirm()` guards against duplicate calls.

- [ ] **Step 4: Add the small scene bridge**

Implement `UIWindowSceneDelegate` callbacks:

```swift
func windowScene(
    _ windowScene: UIWindowScene,
    userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
)

func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
)
```

Forward metadata to an app-owned handler on `MainActor`. Do not accept directly inside the delegate.

- [ ] **Step 5: Wire the bridge to app dependencies**

Use a scene delegate adaptor or scene-configuration bridge compatible with the SwiftUI lifecycle. Route both callback paths into the single coordinator.

- [ ] **Step 6: Run focused tests**

Run the Task 4 command.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
rtk git add InstaBlog/InstaBlog/ShareAcceptanceCoordinator.swift InstaBlog/InstaBlog/CloudKitSceneBridge.swift InstaBlog/InstaBlog/InstaBlogApp.swift InstaBlog/InstaBlogTests/ShareAcceptanceCoordinatorTests.swift
rtk git commit -m 'Handle incoming Blog share invitations'
```

### Task 5: Build the Settings Sharing UI

**Files:**
- Create: `InstaBlog/InstaBlog/SettingsView.swift`
- Modify: `InstaBlog/InstaBlog/IPhoneShell.swift`
- Modify: `InstaBlog/InstaBlog/ContentView.swift`
- Modify: `InstaBlog/InstaBlogTests/InstaBlogTests.swift`

- [ ] **Step 1: Write failing presentation-state tests**

Extract a small `SettingsSharingPresentation` mapper and verify:

```swift
#expect(SettingsSharingPresentation(.notShared).buttonTitle == "Share Blog")
#expect(SettingsSharingPresentation(.sharedOwner).buttonTitle == "Manage Sharing")
#expect(SettingsSharingPresentation(.sharedParticipant).buttonTitle == "Manage Sharing")
```

Verify unavailable/error states expose their messages and loading disables the action.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
rtk proxy xcodebuild test -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:'InstaBlogTests/IPhoneTabSelectionHighlightTests' -only-testing:'InstaBlogTests/SettingsSharingPresentationTests'
```

Expected: FAIL because Settings sharing presentation does not exist.

- [ ] **Step 3: Implement Settings**

Create a `NavigationStack` and `Form` with:

```swift
Section("Blog Sharing") {
    LabeledContent("Status", value: statusText)
    Button(actionTitle) { Task { await performAction() } }
        .disabled(isLoading)
}

Section("Your Identity") {
    TextField("Display name", text: $displayName)
    Button("Save Name") { Task { await saveDisplayName() } }
}
```

For `.notShared`, call `prepareShare` and present:

```swift
.sheet(item: $sharedRecord) {
    CloudSharingView(sharedRecord: $0)
}
```

For owner/participant states, show a standard alert saying “Sharing management is coming later.” Use a progress indicator during preparation and clear error/unavailable alerts.

- [ ] **Step 4: Replace the Settings placeholder**

Pass the active Blog, active Blogger, and injected sharing service through `ContentView`/`IPhoneShell`. Replace `PlaceholderDestinationView(title: "Settings", ...)` with `SettingsView`.

- [ ] **Step 5: Add app-level acceptance UI**

Present the coordinator's warning with **Cancel** and **Join Blog**, show a blocking “Joining Blog…” progress presentation during acceptance, and show retryable failure copy. On `.accepted`, reload the active Blog and shell data.

- [ ] **Step 6: Run focused tests and build**

Run the Task 5 test command, then:

```bash
rtk proxy xcodebuild build -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Expected: tests PASS and `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
rtk git add InstaBlog/InstaBlog/SettingsView.swift InstaBlog/InstaBlog/IPhoneShell.swift InstaBlog/InstaBlog/ContentView.swift InstaBlog/InstaBlog/InstaBlogApp.swift InstaBlog/InstaBlogTests/InstaBlogTests.swift
rtk git commit -m 'Add Blog sharing Settings flow'
```

### Task 6: Synchronize and Render Photo Bytes

**Files:**
- Modify: `InstaBlog/InstaBlog/JournalService.swift`
- Modify: `InstaBlog/InstaBlog/PhotoPostCaptureFlow.swift`
- Modify: `InstaBlog/InstaBlogTests/JournalServiceTests.swift`

- [ ] **Step 1: Write failing photo byte tests**

Extend the photo creation test to assert the original JPEG bytes are inserted into `mediaAssetData` with the new media ID. Add a load test where `localOriginalPath` is absent but synchronized BLOB bytes exist and verify the display model resolves usable image data.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
rtk proxy xcodebuild test -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:'InstaBlogTests/JournalServiceTests'
```

Expected: FAIL because photo bytes are not persisted or used as fallback.

- [ ] **Step 3: Persist BLOB bytes transactionally**

When creating a photo BlogItem, read the staged durable photo URL once and insert:

```swift
try MediaAssetData.insert {
    MediaAssetData.Draft(mediaAssetID: mediaID, data: photoData)
}
.execute(db)
```

in the same database transaction as `MediaAsset` and `BlogItem`. A failure rolls back all three rows.

- [ ] **Step 4: Add received-image fallback**

When constructing photo display data, prefer a readable durable local file. If unavailable, query `MediaAssetData` and supply its bytes to the existing display/image decoding boundary. Do not write synchronized bytes to `Caches` unless the UI requires a URL; if it does, use a deterministic cache filename and recreate it as needed.

- [ ] **Step 5: Run focused tests**

Run the Task 6 command.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add InstaBlog/InstaBlog/JournalService.swift InstaBlog/InstaBlog/PhotoPostCaptureFlow.swift InstaBlog/InstaBlogTests/JournalServiceTests.swift
rtk git commit -m 'Sync Blog photo data through CloudKit assets'
```

### Task 7: Add Capabilities and Operational Documentation

**Files:**
- Create or modify: `InstaBlog/InstaBlog/Info.plist`
- Create: `InstaBlog/InstaBlog/InstaBlog.entitlements`
- Modify: `InstaBlog/InstaBlog.xcodeproj/project.pbxproj`
- Modify: `DesignDecisions.md`
- Create: `docs/cloudkit-sharing-setup.md`

- [ ] **Step 1: Inspect current generated Info.plist and signing settings**

Run:

```bash
rtk proxy xcodebuild -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -showBuildSettings
```

Confirm whether the target uses a generated Info.plist and whether an entitlements file already exists. Make the smallest project-file edit necessary.

- [ ] **Step 2: Enable CloudKit sharing declarations**

Ensure the built app contains:

```xml
<key>CKSharingSupported</key>
<true/>
```

Add iCloud/CloudKit and remote-notification entitlements using the existing app identifier and the project-approved container identifier. Do not invent or create a paid/external service.

- [ ] **Step 3: Document manual setup**

Document:

- selecting the CloudKit container in Signing & Capabilities;
- enabling Background Modes → Remote notifications;
- development versus production CloudKit environments;
- deploying the schema before release;
- testing signed-out iCloud behavior;
- two-account owner/invitee testing for data, writes, and photos.

- [ ] **Step 4: Update durable design decisions**

Record that active-Blog selection is private workspace state excluded from shares, and that photo bytes live in the Blog relationship graph as SQLiteData BLOBs/CloudKit assets.

- [ ] **Step 5: Build and inspect the product**

Run:

```bash
rtk proxy xcodebuild build -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Expected: `** BUILD SUCCEEDED **`.

Inspect the built Info.plist and entitlements with `plutil`/`codesign` through `rtk proxy` and verify `CKSharingSupported`, CloudKit services, container identifiers, and remote notifications are present.

- [ ] **Step 6: Commit**

```bash
rtk git add InstaBlog/InstaBlog/Info.plist InstaBlog/InstaBlog/InstaBlog.entitlements InstaBlog/InstaBlog.xcodeproj/project.pbxproj DesignDecisions.md docs/cloudkit-sharing-setup.md
rtk git commit -m 'Configure CloudKit sharing capability'
```

### Task 8: Full Verification and Human Review Handoff

**Files:**
- Modify only files required by discovered defects.

- [ ] **Step 1: Run all unit tests**

```bash
rtk proxy xcodebuild test -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:'InstaBlogTests'
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Run a clean simulator build**

```bash
rtk proxy xcodebuild clean build -project 'InstaBlog/InstaBlog.xcodeproj' -scheme 'InstaBlog' -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Review the complete diff**

Run:

```bash
rtk git status --short
rtk git diff main...HEAD --check
rtk git diff main...HEAD --stat
```

Confirm the branch contains only tickets #21–#24, the approved spec/plan, tests, and required documentation.

- [ ] **Step 4: Perform available UI smoke checks**

Launch the app on iPhone 17 simulator and verify:

- Settings shows **Share Blog** for an unshared Blog;
- loading prevents duplicate taps;
- unavailable CloudKit produces clear copy rather than a crash;
- shared fake/preview state shows **Manage Sharing** and the coming-later alert;
- display name editing persists.

Record that real invitation and two-account CKAsset verification remain manual-device checks if simulator/iCloud accounts are unavailable.

- [ ] **Step 5: Request code review**

Use `superpowers:requesting-code-review` for the complete branch and address any high-confidence findings before handoff.

- [ ] **Step 6: Present the local diff for human inspection**

Report commits, tests, build evidence, manual checks completed, and any Apple Developer/iCloud actions Rog must perform. Do not push or open a PR until Rog approves the local diff.

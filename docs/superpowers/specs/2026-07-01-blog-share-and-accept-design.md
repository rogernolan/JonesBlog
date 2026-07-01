# Blog Share and Accept Design

Date: 2026-07-01

Issues: #21, #22, #23, #24

## Goal

Allow the owner of the active Blog to invite collaborators from Settings using Apple's native CloudKit sharing UI. Allow an invited user to accept the Blog, preserve and hide any meaningful local Blog, make the shared Blog active, and create or update that participant's Blogger identity. The shared Blog includes every Blog-owned record and every photo.

Participant-management behavior behind **Manage Sharing** is not part of this iteration.

## Product Decisions

- `Blog` is the single CloudKit share root.
- Shares are invite-only. Accepted participants receive read/write access.
- A local Blog is preserved, never deleted, when a shared Blog becomes active.
- Accepting a share warns before hiding a meaningfully used local Blog.
- An untouched bootstrap Blog does not trigger the warning.
- A Blog is meaningfully used when it contains non-bootstrap content or configuration: a BlogItem, a user-created or edited Trip, a Subscriber, a PublishEvent, changed Blog title or gallery settings, or edited Blogger identity.
- The initial participant display name comes from CloudKit identity metadata when available. Settings allows the participant to edit it later.
- When a Blog is already shared, Settings shows an enabled **Manage Sharing** button. In this iteration it presents a message that sharing management is coming later.

## Architecture

### SQLiteData and CloudKit

Configure SQLiteData's `SyncEngine` with all Blog-owned tables. Use `SyncEngine.share(record:configure:)` to create or fetch a share for the active Blog and SQLiteData's `CloudSharingView` to present Apple's `UICloudSharingController`.

The database attaches SQLiteData's metadata database so share state can be derived from `SyncMetadata`. The app maps that metadata and CloudKit availability into:

- `notShared`
- `sharedOwner`
- `sharedParticipant`
- `unavailable`
- `error`

Every synchronized child table must have exactly one foreign-key path to `Blog`. This lets SQLiteData associate the entire graph with the Blog's `CKShare`.

### Sharing Service

A protocol-backed `BlogSharingService` is the system boundary for:

- loading share state for the active Blog;
- preparing the native `SharedRecord`;
- validating CloudKit/account availability;
- staging incoming share metadata;
- accepting a confirmed invitation;
- fetching accepted shared records;
- identifying and activating the shared Blog;
- creating or updating the participant Blogger.

SwiftUI views and their presentation model depend on the protocol. Tests use a fake and do not contact CloudKit.

### Active Blog State

Add private workspace state that stores the active Blog identifier. It may synchronize across the current user's devices, but it is excluded from Blog sharing using SQLiteData's `privateTables` configuration.

Changing the active Blog hides the previous Blog without deleting its records. This creates the storage boundary needed for a future “leave shared Blog and return to local Blog” flow.

## Image Data

`MediaAsset.localOriginalPath` is device-local and cannot carry a photo to collaborators.

Add a `MediaAssetData` table whose primary key is also a foreign key to `MediaAsset`, with a BLOB column containing durable photo bytes. SQLiteData automatically encodes BLOB columns as `CKAsset` values and restores them on receiving devices.

Photo creation writes both the existing media metadata and its bytes. Existing durable file behavior can remain for upload lifecycle and cache management, but the BLOB is the synchronized source for the share graph. Image loading can prefer an available durable local file and fall back to synchronized bytes.

## Owner Flow

1. Settings loads the active Blog and share state.
2. For `notShared`, the sharing section shows **Share Blog**.
3. Tapping it disables repeat interaction and shows progress while the service prepares the share.
4. The share title uses the Blog title. Public permission remains disabled and participant permission is read/write.
5. The app presents `CloudSharingView`, which hosts Apple's native sharing controller.
6. On success or dismissal, Settings reloads share state.
7. `unavailable` shows a clear iCloud/CloudKit account message. `error` shows a retryable alert.
8. Shared owners and participants see **Manage Sharing**. For now, tapping it shows “Sharing management is coming later.”

## Acceptance Flow

Incoming `CKShare.Metadata` can arrive while connecting a scene or through the scene acceptance callback. The scene hands metadata to app-level pending-invitation state instead of accepting immediately.

If the active local Blog is meaningful, the app asks:

> Join “{Blog title}”?
>
> Your current Blog will be hidden, not deleted. You can return to it after leaving the shared Blog.

**Cancel** clears pending metadata and does not change the active Blog. **Join Blog** begins acceptance. An empty bootstrap Blog skips the warning and begins acceptance directly.

Acceptance proceeds as follows:

1. Preserve the current active Blog identifier.
2. Ask SQLiteData's sync engine to accept the share.
3. Fetch the accepted shared changes.
4. Resolve the accepted Blog root from share metadata and synchronized records.
5. Upsert the current participant's Blogger.
6. Set the accepted Blog as active.

The active identifier changes only after acceptance, fetch, root resolution, and Blogger upsert succeed. If any step fails, the old Blog remains active and the user receives a retryable error.

## Blogger Identity

When CloudKit supplies a stable participant identity, store it in `cloudKitParticipantIdentifier` and use it to find an existing Blogger. Repeated acceptance or synchronization updates that Blogger rather than inserting another.

Use CloudKit name components for the initial display name when available, with a neutral local fallback when unavailable. Settings exposes the active participant's display name for later editing. Application logic enforces participant idempotency because CloudKit-synchronized schemas cannot rely on an additional SQL uniqueness constraint.

## State and Error Handling

- Share preparation and acceptance expose explicit loading states and ignore duplicate taps.
- Cancellation is not treated as an error.
- CloudKit account or capability failures map to `unavailable` with actionable copy.
- Other failures map to `error` while retaining the active Blog and pending user data.
- Participant write permission is checked through share metadata; read-only or missing permission prevents editing and is surfaced clearly.
- No view performs CloudKit or database orchestration directly.

## Testing

Unit tests cover:

- all share-state mappings using fake sharing services;
- owner share preparation and unavailable/error states;
- cancellation with no active-Blog change;
- direct acceptance for an empty bootstrap Blog;
- warning and confirmation for a meaningful local Blog;
- failure before activation retaining the previous Blog;
- active-Blog switching after successful acceptance;
- meaningful-Blog threshold cases;
- Blogger insertion, identity-based idempotency, display-name update, and missing-name fallback;
- photo bytes being persisted in the synchronized asset table;
- Settings labels and presentation-model behavior where practical.

Manual device testing with two iCloud accounts covers:

- native sharing-controller presentation;
- invitation delivery and both scene callback paths;
- accepting and opening the shared Blog;
- read/write collaboration;
- transfer and rendering of existing and newly added photos;
- iCloud signed-out/unavailable behavior.

## Out of Scope

- Participant listing, removal, role changes, or stopping a share.
- Leaving a shared Blog and returning to a preserved local Blog.
- Public links or read-only sharing.
- A custom sharing interface.
- Destructive replacement of a local Blog.

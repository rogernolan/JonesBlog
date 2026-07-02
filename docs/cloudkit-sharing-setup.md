# CloudKit Sharing Setup

InstaBlog uses the CloudKit container `iCloud.com.jonesthevan.blog.InstaBlog` for the app bundle identifier `com.jonesthevan.blog.InstaBlog`.

## Checked-in configuration

The repository contains:

- `AppCloudKitConfiguration.containerIdentifier` set to the container above.
- CloudKit, container, key-value-store, and development push entitlements in `InstaBlog.entitlements`.
- iCloud and Push Notifications target capability metadata.
- `CKSharingSupported = true` and the `remote-notification` background mode in `Info.plist`.

These files do not create the container, update the App ID, or generate a provisioning profile. Those are manual Apple Developer/Xcode actions.

## One-time Apple Developer and Xcode setup

1. In Certificates, Identifiers & Profiles, open the explicit App ID for `com.jonesthevan.blog.InstaBlog`.
2. Enable iCloud with CloudKit and Push Notifications. Create or select exactly `iCloud.com.jonesthevan.blog.InstaBlog`; do not select a differently named container.
3. Grant the App ID access to that container and save it.
4. Regenerate development and distribution provisioning profiles after changing capabilities, or allow Xcode automatic signing to refresh them.
5. In Xcode, select the InstaBlog target, then Signing & Capabilities. Confirm iCloud is enabled with CloudKit selected and the same container checked. Confirm Push Notifications is enabled.
6. Add Background Modes if Xcode does not already show it and select Remote notifications. The checked-in Info.plist already contains `remote-notification`.

Do not change the checked-in development team merely to resolve a local signing error. A team administrator must grant container access or refresh the correct profile.

## Development and production

CloudKit development and production are separate environments with separate data. Debug/device development builds normally use the development environment. TestFlight and App Store builds use production.

Create representative development records first. Before distributing a build, use CloudKit Console to inspect the schema and deploy the development schema to production. Schema deployment does not copy records. Repeat deployment after later record-type or field changes.

The checked-in `aps-environment` value supports development signing. Distribution signing/provisioning must supply the production push entitlement. Verify the archived app's signed entitlements before upload.

## Account and device behavior

CloudKit sharing requires an iCloud account. When signed out, InstaBlog remains local-first, but sharing and CloudKit synchronization are unavailable; the app must not discard local Blog data.

End-to-end share testing needs two different iCloud accounts, preferably on two physical devices. Simulator builds verify configuration and local presentation but do not establish that production signing, push delivery, or invitation handoff works on devices.

Suggested owner/invitee test:

1. On the owner device, create a Blog with text records and photos, and wait for synchronization.
2. Create a share and invite the second account.
3. Accept the invitation on the invitee device and verify the shared Blog becomes active while the invitee's former local Blog remains preserved but hidden.
4. On the invitee device, read existing records and photos, then add and edit text and photo content.
5. Verify the owner receives the writes and photo bytes, then edit on the owner device and verify the invitee receives those changes.
6. Relaunch both devices and repeat a write after an offline/online transition.

The current Manage Sharing control is a placeholder; participant-management UI is not yet complete.

## Troubleshooting

- An error that the container is missing or unauthorized usually means the App ID is not associated with `iCloud.com.jonesthevan.blog.InstaBlog`, or the signed provisioning profile predates that association.
- If `codesign -d --entitlements :- InstaBlog.app` does not show the expected iCloud container, CloudKit service, key-value-store, push, and application identifier values, refresh signing assets rather than adding unrelated entitlements.
- If invitations arrive but content does not sync, confirm both accounts are signed into iCloud, the app environments match, and the CloudKit schema has been deployed for TestFlight/App Store testing.
- If background updates do not arrive, confirm Push Notifications, the `remote-notification` background mode, device network access, and the signed `aps-environment`.
- Entitlement/profile mismatch failures must be fixed in the Developer portal and provisioning profile. Do not hand-add unsupported entitlement keys to bypass signing validation.

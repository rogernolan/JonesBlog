# Blogging App — Product Requirements Document

## Summary

Groups of friends or travellers currently lack a simple, shared way to document experiences together in a structured, publishable format. Existing options — group chats, Instagram, or traditional blogs — are either too ephemeral, too personal, or too effortful to maintain collaboratively.

This app provides a shared, multi-user blogging experience where individual photo/video entries are auto-enriched with location and weather context, then automatically assembled into day-level posts that can be published to a static blog or sent to a mailing list.

## Goals

- Make it effortless for a group to collectively document an experience in real time, with minimal manual input.
- Automatically enrich entries with location and weather context so contributors do not have to.
- Produce a publishable, shareable day-by-day narrative from raw individual entries.
- Support both in-group real-time consumption and outward publishing to a wider audience (mailing list, static blog).

## Users and Needs

**Primary users:** Small, trusted friend or travel groups (2-10 people) who want to document a trip and share the result with friends and family.

**Secondary audience:** Mailing list subscribers and static blog readers who receive the published output but do not contribute.

**Core needs:**

- Low-friction entry creation — capture a moment quickly without tagging, categorising, or writing much.
- Shared visibility — see what others in the group have posted, in context.
- A coherent narrative output — the day's entries should read as a story, not a feed of fragments.
- Control over publishing — choose when and how to share outward, without it being automatic.

## User Stories, Features and Requirements

### Entry Creation

- As a contributor, I can create a new entry with a single photo or video and a text caption, so I can quickly capture a moment.
- As a contributor, when I create an entry, the app automatically tags it with my current location — reverse geocoded to a human-readable city name and a country flag — so I do not have to type where I am.
- As a contributor, when I create an entry, the app automatically fetches current weather conditions via Apple WeatherKit and attaches an appropriate weather icon, so the context is captured without effort.
- As a contributor, I can edit or delete any entry I have created.

### Day Posts

- The app automatically groups all entries from the same calendar day into a single Day post.
- A Day post displays an itinerary derived from the locations of its entries, in chronological order (e.g. London to Paris to Lyon).
- A Day post displays a summary weather condition derived from the conditions across its entries.
- Day posts are not manually created — they are always derived from entry data.

### Main Feed

- The main view shows a chronological list of entries with: thumbnail, author name, date, and location label.
- A prominent + button is always visible to create a new entry.
- Tapping an entry opens the full view showing the photo or video, caption, location, and weather.

### Multi-User and Data Sharing

- Every blog is multi-user by default — there is no single-owner or private mode.
- One user creates a blog and becomes its owner. They share it with others via a standard iOS share sheet, backed by CloudKit's CKShare mechanism (invite by iCloud contact or shareable link).
- Invited users accept the share and gain full contributor access — they can create, edit, and delete their own entries.
- All entries and day posts are visible to all group members and sync in real time via CoreData with CloudKit (NSPersistentCloudKitContainer) using a shared CloudKit zone.
- All data — entries, locations, weather, media — is shared across users. There is no private content within a blog.
- User identity is shown per entry as the author name, derived from the user's iCloud account.
- All contributors must have an iCloud account; CloudKit handles sync and conflict resolution automatically.

### Publishing

- As a group member, I can send a Day post to the blog's mailing list. The app composes an HTML email via MailKit and opens it in Mail.app, pre-addressed to all subscribers, ready to send.
- The email is formatted as HTML with images scaled to render well on iPad and MacBook Pro screens.
- As a blog owner or contributor, I can manage the blog's subscriber list — adding and removing email addresses. The subscriber list is stored in CloudKit and shared between all authors, so any contributor can send to it.
- As a group member, I can publish a Day post to a static self-hosted blog.
- Publishing and sending are deliberate, manual actions — Day posts are not automatically sent or published.

## Success Metrics

- **Adoption:** All members of a group actively contribute entries during a shared experience, not just one person.
- **Enrichment reliability:** 95% or more of entries are successfully auto-tagged with location and weather at creation time.
- **Publishing usage:** At least one Day post per trip or experience is published or sent to a mailing list.
- **Time to publish:** A Day post can be published within minutes of the day ending, without manual assembly.

## Risks and Open Questions

- **Location permissions:** Resolved — location is optional for MVP. If unavailable or denied, the entry is saved without a location tag. No prompt or warning required.
- **Weather API:** Resolved — Apple WeatherKit. Requires a WeatherKit entitlement. Offline fallback behaviour (e.g. retry on next sync or omit icon) to be defined during implementation.
- **Data backend:** Open.
- **Group management:** Open
- **Static blog format:** TBD — an open-source static site generator will be used. Specific tooling and hosting to be decided in a follow-up spec.
- **Mailing list integration:** Resolved — the blog maintains its own subscriber list stored in CloudKit and shared across all authors. Any contributor can manage subscribers or send a Day post. Emails are composed as HTML via MailKit and sent through Mail.app. No third-party provider required.
- **Video support:** Resolved — video is in scope. Storage overhead against users' iCloud quotas is accepted.
- **Day post timezone:** Resolved — the primary assumption is that all contributors are together and in the same timezone. In the edge case where they are not, the blog owner's timezone defines the day boundary.


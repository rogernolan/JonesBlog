# InstaBlog app — Product Requirements Document

## Version 7

## Summary

Groups of friends or travellers currently lack a simple, shared way to document experiences together in a structured, publishable format. Existing options — group chats, Instagram, or traditional blogs — are either too ephemeral, too personal, or too effortful to maintain collaboratively.

This InstaBlog app provides a shared, multi-user blogging experience where individual photo/video entries are auto-enriched with location and weather context, then automatically assembled each day, into a post that can be sent to a mailing list. (Or, in the next version, published to a website, but we are not fleshing that out for v1)

The InstaBlog app is native iOS, running on iPhone and iPad. Target OS is iOS 26.5+

This document describes an in-house only v1 of InstaBlog, which is intended for the personal use of the two coders and will not address any permission issues, granting them equally to both Bloggers. If this app shows potential for a full release to the public, this issue will have to be addressed. This document specifically targets v1 of InstaBlog.

## Definitions and data model

Blogger - one of a small group of people who all create BlogItems to contribute to a shared Blog. In v1, all Bloggers are equal owners of the Blog, and may perform all functions on the shared Blog. In v1, the two coders will be the only Bloggers in the BloggerGroup.

BloggerGroup - the set of Bloggers who are allowed to create BlogItems in a particular Blog.

BlogItem - the unit created by one person as a contribution to the shared narrative. To start with, this will be one photo or one video, with a small amount of explanatory text (the caption). A BlogItem may be created at the time the photo was taken, or days later - its date can be changed by the user, but should be set to the date of the Photo or Video by default. Part of the underlying data model.

Caption - a sentence or two of text, describing a photo or video. Part of a BlogItem

Gallery - a collection of BlogItems, all in the same geographic location and created within the same time period. Note that this is a display artefact only, and does not need to exist in the model. BlogItems may be part of a Gallery, but they do not have to be. A Gallery is automatically shown by InstaBlog when two or more BlogItems are close enough together in time and space to count as "at the same event." How this is defined is an open question - one suggestion is that when a BlogItem is displayed, InstaBlog checks certain time and distance criteria from the previous BlogItem it displayed, and if those are within certain bounds, the display of those BlogItems is in Gallery form. Note that this means a Gallery will change if a BlogItem is edited so that its date or location are changed - this is correct behaviour.

DayPost - all the top level BlogItems and Galleries made (or dated) for one particular day. Again, a display artefact which can be constructed when needed from BlogItems.

Trip - all the DayPosts for a certain time period (usually weeks or months), set by a Blogger. A Blogger will usually start an open Trip, to which all DayPosts are assigned, until a Blogger closes the Trip. If a BlogItem's date changes such that it is within a different DayPost, then it should move to that DayPost. In effect, DayPosts are constructed on the fly by finding all BlogItems and Galleries with a certain date, and a Trip is created on-the-fly by finding DayPosts within a range of days. A Trip exists in the data model as a start date and possibly an end date. The viewable Trip, with all its DayPosts and their BlogItems is constructed on the fly as the Trip is viewed.

Any BlogItems or Galleries which are not contained within a Trip show in an Unassigned Trip. The assumption is that the Blogger either needs to edit their dates or to create a Trip to contain them.

Blog - the entirety of the blog data - multiple Trips.

SubscriberMailList - a list of email addresses to send DayPosts to.



## InstaBlog Goals

- Make it effortless for a group to collectively document an experience in real time, with minimal manual input.
- Automatically enrich BlogItems with location and weather context so Bloggers do not have to.
- Produce a publishable, shareable day-by-day narrative (DayPost) from raw individual entries (BlogItems and Galleries)
- Support both real-time consumption by Bloggers of each other's content (in the iOS app) and outward publishing to a wider audience (mailing list, website). The outward publishing in v1 will solely be the ability to send a DayPost to a mailing list of subscribers. For v1, we will not concern ourselves with any web publishing.

## InstaBlog Users and Needs

**Primary users:** Bloggers - small groups of family and friends - trusted contributors who want to document a trip together and share the result with others. In v1, there will be just two Bloggers, the coders of the app.

**Secondary audience:** Initially just mailing list subscribers and later web readers who read/receive the published output but do not contribute.

**Blogger needs:**

- Low-friction entry creation — capture a moment quickly without tagging, categorising, or writing much.
- Shared visibility — see what other Bloggers have posted, in context.
- Shared editing - in v1, at least, all Bloggers can edit all other Bloggers' content.
- A coherent narrative output — the day's entries should read as a story, not a feed of fragments.
- Control over publishing — choose when and how to share outward, without it being automatic.

## User Stories, Features and Requirements

### Entry Creation

- As a Blogger, I can create a new BlogItem with a single photo or video and a text caption, so I can quickly capture a moment.
- As a Blogger, when I create a BlogItem, the app automatically tags it with my current location — reverse geocoded to a human-readable city name and a country flag — so I do not have to type where I am.
- As a Blogger, when I create an entry, the app automatically fetches current weather conditions and attaches a temperature and appropriate weather icon(s), so the context is captured without effort.
- As a Blogger, I can edit or delete any entry I have created. In v1, at least, I can also edit or delete any BlogItem created by others in my group.

### DayPosts

- The InstaBlog app automatically groups all entries from the same calendar day into a single DayPost.
- At its end, a DayPost displays an itinerary derived from the locations of its entries, in chronological order (e.g. London to Paris to Lyon).
- At its end, a DayPost displays a summary weather condition derived from the conditions across its entries.
- DayPosts are not created by Bloggers — the app always derives them from BlogItems and Galleries.

### InstaBlog reader

- The InstaBlog app's main view shows the current Trip - a chronological list of BlogItems and Galleries with: thumbnail, author name, date, weather icons and location label. If Galleries have multiple authors, the author field is omitted. There is UI to allow the opening of a past (completed Trip) instead.
- If a Trip is not in progress, the main view shows a list of all the completed Trips, with the UI to allow the creation of a new one.
- Once within a Trip, a prominent + button is always visible to create a new entry.
- Tapping a BlogItem opens a full view showing the photo or video, caption, location, and weather. An edit control, when tapped, allows any Blogger to edit the BlogItem or delete it.
- Tapping a Gallery shows the multiple BlogItems that make it up, in a side-swipe carousel view. Each BlogItem shows the photo or video, caption, location, and weather, as when tapping a BlogItem. An edit control, when tapped, allows any Blogger to edit the BlogItem or delete it. If all BlogItems in a Gallery are deleted, the Gallery is deleted.

### Multi-User and Data Sharing (InstaBlog v1 only)

- Every Blog is multi-user by default — there is no single-owner or private mode. When the first Blogger downloads the app and creates a Blog, he can invite others to become Bloggers, i.e. equal contributors to the Blog.
- Invited users may accept the share and become Bloggers. They gain full contributor access — they can create, edit, and delete their own entries, and those of others.
- Any Blogger can also remove any other Blogger. This lax permissions model is for v1 and would be refined were this app to find a public audience.
- Any Blogger in the BloggerGroup can create a new Trip. There can only be one Trip open at one time, as Trips are defined by time periods consisting of multiple days. If a Trip is open when a Blogger tries to create a new one, the create fails. The existing Trip must be closed first.
- All BlogItems and DayPosts are visible to all Bloggers in the BlogGroup and they sync in real time.
- All data — BlogItems, Galleries, locations, weather, media — is shared across Bloggers. There is no private content within a blog.
- The author of each BlogItem is shown as a name (which was entered by the Blogger on accepting the invitation and is able to be edited by that Blogger).

### Publishing

- As a Blogger, I can send a DayPost to the blog's mailing list, the SubscriberMailList. The app composes an HTML email via MailKit and opens it in Mail.app, pre-addressed to all subscribers, ready to send.
- The email is formatted as HTML with images scaled to render well on iPad and MacBook Pro screens.
- As a Blogger, I can manage the blog's subscriber list — adding and removing email addresses. The subscriber list is shared between all authors, so any contributor can send to it.
- In versions after the first, as a Blogger, I can publish a DayPost to a website (details to be confirmed).
- Publishing and sending are deliberate, manual actions — DayPosts are not automatically sent or published.

## Success Metrics

- **Adoption:** All Bloggers in the BloggerGroup actively contribute BlogItems during a shared experience, not just one person.
- **Enrichment reliability:** 95% or more of entries are successfully auto-tagged with location and weather, ideally at creation time, but at least as soon as the InstaBlog app is run with suitable network coverage.
- **Publishing usage:** At least one DayPost per Trip is published or sent to a SubscriberMailList.
- **Time to publish:** A DayPost can be published within minutes of the day ending, without manual assembly.

## Next Design Decision

- It is key to next work on the data backend and technical requirements of this specification. That is the next large piece of work once this document is agreed.

## Other Risks and Open Questions

- **Location permissions:** Resolved — location is optional for MVP. If unavailable or denied, the entry is saved without a location tag. No prompt or warning required.
- **Weather API:** Resolved — Apple WeatherKit. Requires a WeatherKit entitlement. Offline fallback behaviour (e.g. retry on next sync or omit icon) to be defined during implementation.
- **Group management:** Open
- **Static blog format:** TBD — an open-source static site generator will be used. Specific tooling and hosting to be decided in a follow-up spec.
- **Mailing list integration:** Resolved — the blog maintains its own subscriber list stored in CloudKit and shared across all authors. Any contributor can manage subscribers or send a Day post. Emails are composed as HTML via MailKit and sent through Mail.app. No third-party provider required.
- **Video support:** Resolved — video is in scope. Storage overhead against users' iCloud quotas is accepted.
- **DayPost timezone:** Resolved — the primary assumption is that all contributors are together and in the same timezone. In the edge case where they are not, the initial Blogger's timezone defines the day boundary.


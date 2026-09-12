# Trip closing and replacement design

Implements GitHub issues #404 and #409 together. Both workflows decide how an
open trip ends, so they share one planning model and one persistence boundary.

## Scope

### End an open trip (#404)

The app derives choices from the open trip's entry days:

- If it has entries today, present **Today** and **Yesterday**.
- If it has none today but has entries yesterday, end it on **Yesterday**
  without a confirmation choice.
- If it has entries on neither day, present **Today**, **Yesterday**, and
  **Last entry: 12 September** (using the actual local date) when a last entry
  exists.
- If it has no entries, omit the last-entry choice and show: "Closing this
  trip will leave it with no entries."

The selected local day is passed to a service operation that closes the trip.

### Start a new open trip while one is open (#409)

After the user enters the new trip's details and taps Save, the app determines
whether another open trip exists. It presents a confirmation before changing
anything:

- The current trip will close on the day before the new trip starts.
- Automatic replacement is available only when that close day is on or after
  the current trip's start day. Otherwise the editor explains that the new
  trip must start later, because the current trip cannot end before it starts.
- The message names the trip and says how many entries will belong to the new
  trip after the date ranges change.
- When the prior trip has no entries, it also says: "Closing this trip will
  leave it with no entries."
- Cancel keeps the editor and leaves both persisted data and navigation
  unchanged.

Membership is derived from each entry's local day and trip date ranges; no
entry rows are moved or rewritten.

## Architecture

Add a pure, Sendable trip-transition planner alongside the existing trip
validation models. It accepts the open trip, relevant entry local days, the
current local day, and (for replacement) the proposed new-trip start date. It
returns display-ready close-day choices, warnings, affected-entry count, and
the requested service action. This gives iPhone and iPad identical behaviour
and makes date rules independently testable.

Add a small shared SwiftUI confirmation component driven by that plan. The
existing `TripDetailsEditor` remains the common entry editor. Its create save
path asks its host to resolve a replacement plan when needed. The iPhone and
iPad shells own only presentation state and their existing, platform-specific
navigation cleanup after a successful mutation.

## Persistence and failure handling

Extend `JournalStore` with explicit close-on-day and replace-open-trip
operations. Replacement runs in one database write transaction: re-read the
active blog and open trip, validate the final ranges, close the old trip, and
create the new trip. Any validation or database failure rolls back the entire
transition. Existing error presentation reports the mutation failure and keeps
the UI available for retry.

The store remains authoritative: it re-checks open-trip state and date ranges
inside the transaction in case the state changed after the confirmation was
shown.

## Tests

- Planner tests cover today, yesterday, last-entry, and no-entry options and
  warning text; replacement affected-entry counts are also covered.
- Store/service tests prove closing on a selected day, atomic replacement,
  date-derived membership in the new trip, and rollback when final dates are
  invalid.
- Existing focused UI/editor tests will be extended only where the shared save
  callback's contract changes. A build and the narrow relevant test suite will
  be run before any commit.

## Non-goals

- Editing existing closed trips beyond the current editor behaviour.
- Reassigning or mutating `BlogItem` rows to represent trip membership.
- Changing trip display ordering or other journal navigation.

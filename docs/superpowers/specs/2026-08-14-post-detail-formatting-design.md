# Post detail formatting (issue 328)

## Scope

Correct two presentation details in the post-detail editor. The temperature row
will use the label `Temperature ºC`. The location text field will remain
trailing aligned, take the available horizontal space, and reserve the existing
chevron control's width so location text is flush to it with normal row padding.

## Design

The change is contained in `JournalScreens.swift`:

- Update the existing `JournalTemperatureEditor` label.
- Give the location `TextField` priority for the remaining row width while
  preserving its trailing alignment and the chevron's explicit frame.

No persistence, navigation, accessibility identifier, or interaction behavior
will change.

## Verification

Add a focused UI-test assertion for the temperature label and location-field
layout behavior where the existing test architecture supports it. Build and run
the narrowest applicable tests, then request a human visual check on an iPhone
and iPad before any longer UI-test suite.

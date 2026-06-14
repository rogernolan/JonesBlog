# AGENTS.md

Guidance for AI agents working in this repository.

## Project

JonesBlog is a native iOS app written in Swift and SwiftUI.

Primary project:

- `JonesBlog/JonesBlog.xcodeproj`
- App sources: `JonesBlog/JonesBlog`
- Unit tests: `JonesBlog/JonesBlogTests`
- UI tests: `JonesBlog/JonesBlogUITests`

## Required Skill Usage

Use the local Axiom skills and the installed Superpowers skills by default.

Before Apple platform work, read the most relevant Axiom skill from `.agents/skills/`:

- Swift language and API design: `.agents/skills/axiom-swift/SKILL.md`
- SwiftUI views, navigation, previews, and layout: `.agents/skills/axiom-swiftui/SKILL.md`
- Build, Xcode, LLDB, and simulator debugging: `.agents/skills/axiom-build/SKILL.md`
- Data persistence, SwiftData, Core Data, CloudKit, SQLite: `.agents/skills/axiom-data/SKILL.md`
- Concurrency, actors, isolation, synchronization: `.agents/skills/axiom-concurrency/SKILL.md`
- Testing: `.agents/skills/axiom-testing/SKILL.md`
- Accessibility and UX audits: `.agents/skills/axiom-accessibility/SKILL.md`
- Performance or memory work: `.agents/skills/axiom-performance/SKILL.md`
- Security, signing, entitlements, privacy: `.agents/skills/axiom-security/SKILL.md`
- App Store, TestFlight, shipping: `.agents/skills/axiom-shipping/SKILL.md`

If a task spans multiple areas, read each relevant Axiom `SKILL.md` before making changes.

Use Superpowers process skills for engineering workflow:

- Use brainstorming before meaningful feature or UX work.
- Use test-driven development for feature work and bug fixes when practical.
- Use systematic debugging before fixing unclear failures or unexpected behavior.
- Use verification-before-completion before claiming work is done.
- Use requesting-code-review for substantial changes before merge or PR work.

If a required skill is unavailable, say so explicitly and continue with the closest local guidance.

## Dependency Policy

Do not add external dependencies without explicit permission from Rog.

When dependencies are approved:

- Use Swift Package Manager only.
- Do not use CocoaPods or Carthage.
- Do not vendor third-party source code into the repo.
- Prefer Apple frameworks and standard library APIs over third-party packages.
- Keep `Package.resolved` committed when SwiftPM dependencies are present.

## Swift Style

Keep Swift modern, clean, and idiomatic.

- Prefer SwiftUI and native Apple APIs.
- Prefer value types where they fit naturally.
- Use structured concurrency (`async`/`await`, `Task`, actors) instead of callback-heavy designs.
- Keep actor isolation explicit and avoid papering over concurrency warnings.
- Avoid force unwraps and implicitly unwrapped optionals except where Apple lifecycle APIs make them unavoidable.
- Keep view bodies small by extracting focused private views and helpers.
- Keep model, view, and persistence responsibilities separate.
- Prefer clear names over clever abstractions.
- Add comments only when they explain non-obvious intent or tradeoffs.

## Architecture

Favor simple, native architecture until the app proves it needs more.

- Keep business logic out of SwiftUI view bodies.
- Keep persistence and networking behind small, testable boundaries.
- Use dependency injection for services that touch the network, disk, clocks, randomness, or system APIs.
- Avoid broad global state.
- Avoid adding new architectural frameworks without permission.

## Testing

Changes should include tests proportional to risk.

- Add or update unit tests for model, persistence, parsing, and business logic changes.
- Add UI tests for critical user flows when behavior changes visibly.
- Keep tests deterministic.
- Prefer small focused tests over large brittle end-to-end tests.

Before completion, run the narrowest useful verification. For project-wide changes, prefer an Xcode build/test command for the relevant scheme and simulator.

## Xcode Project Hygiene

- Keep generated build products out of git.
- Do not commit `xcuserdata`, `DerivedData`, local schemes, or local signing state.
- Keep shared project files, shared schemes, assets, entitlements, and source files committed.
- Do not rewrite `project.pbxproj` unnecessarily.

## Git

Keep commits focused and reviewable.

- Separate dependency, project-structure, feature, and cleanup changes when possible.
- Do not revert user changes unless Rog explicitly asks.
- Before committing, inspect `git status --short` and make sure the commit contains only the intended files.

# AGENTS.md

Guidance for AI agents working in this repository.

## Project

InstaBlog is a native iOS app written in Swift and SwiftUI.

Product context:

- Product requirements live in `Product Requirements Document.md`
- Design decisions live in `DesignDecisions.md`.
- Treat the PRD's user needs, feature requirements, and success metrics as product context.
- Do not blindly adopt implementation choices embedded in the PRD. Look in `DesignDecisions.md`; if no decision exists there, evaluate storage, sync, publishing, and backend choices against the requirements and this `AGENTS.md`.
- If architecture, product, storage, sync, publishing, backend, or other durable technical decisions are made or changed during implementation, keep `DesignDecisions.md` up to date.
- Only change the PRD at the request of Rog or Jane.

Primary project:

- `InstaBlog/InstaBlog.xcodeproj`
- App sources: `InstaBlog/InstaBlog`
- Unit tests: `InstaBlog/InstaBlogTests`
- UI tests: `InstaBlog/InstaBlogUITests`

## Token discipline:

- Prefer narrow inspection over broad repo exploration.
- Do not read PRD or DesignDecisions.md unless product or architecture context is directly relevant.
- For rebase/cherry-pick/diff-transfer tasks, inspect only the source diff and target files.
- Run `xcodebuild` commands with quoted arguments through `rtk proxy`, not `rtk test`, so destinations containing spaces remain a single argument.

## Command and Verification Discipline

- Run the commands reasonably needed to inspect, implement, and verify a change.
- Keep verification proportional to the change. Start with the narrowest relevant check, then broaden only when the result or risk justifies it.
- Avoid repeatedly running substantially identical build or test commands without learning something new between runs.
- If a command fails because of Xcode, simulator, signing, scheme, or environment configuration, investigate with focused diagnostic commands. Do not attempt speculative or invasive workarounds without approval.
- Prefer clear, direct commands over clever shell automation.
- Do not use generated shell loops, `sed`/`awk` pipelines, regex-based bulk rewrites, or other opaque scripting to modify source code.
- Use `apply_patch` for deliberate source edits. Formatting tools and established project scripts may perform mechanical changes when their scope is understood and reviewed.
- Before completion, run enough relevant verification to provide credible evidence that the change works. Report the commands run and any checks that could not be completed.

## Required Skill Usage

Use Axiom/Superpowers skills selectively, not by default.
For small mechanical tasks, rebases, conflict resolution, typo fixes, narrow UI changes, or one-file edits:
- Do not read Axiom or Superpowers skills unless explicitly asked.
- Do not run brainstorming, TDD, or requesting-code-review process skills.

For feature work:
- Read at most one Axiom skill initially.
- Read additional skills only if the task clearly requires them.
- State which skill was read and why.

For debugging:

- Follow the command and verification discipline above.
- Use focused diagnostics to understand failures before proposing or making fixes.

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

## Workflow

The project uses a GitHub project to schedule and plan work. You should always work from tickets.

1. Rog/Jane instructs you to work on an issue or implement a feature
2. Use Superpowers brainstorming and other skills as appropriate to refine the ticket/feature. If a feature is altered as a result of this, document that in the relevant issue or if needed in the Design Doc or PRD.
3. Before modifying files, create or switch to a feature branch or worktree unless Rog/Jane explicitly says otherwise
4. Implements the change, updates relevant tests/docs, and verifies with the narrowest useful build or test command
5. Request a human to inspect the local diff
6. When the human is happy with the local diff, they ask Codex to open a PR
7. Another person reviews the PR
8. Optional @codex review for risky changes
9. Squash merge

- Do not push a broken build or failing test to GitHub
- If verification is blocked by a local environment or simulator issue, report the exact command and failure, run the closest useful fallback verification, and get explicit approval before pushing
- Do not work on main unless Rog/Jane explicitly says otherwise

## Dependency Policy

Do not add external dependencies without explicit permission from Rog or Jane.

Do not propose an external hosted service, paid backend, SDK, package, or non-Apple platform dependency as the default architecture unless Rog or Jane has explicitly asked for one or the requirements cannot reasonably be met with native Apple/local options. If mentioning one as an alternative, label it clearly as requiring explicit approval and explain why native options are insufficient.

When dependencies are approved:

- Use Swift Package Manager only.
- Do not use CocoaPods or Carthage.
- Do not vendor third-party source code into the repo.
- Prefer Apple frameworks and standard library APIs over third-party packages.
- Keep `Package.resolved` committed when SwiftPM dependencies are present.

## Storage and Backend Decisions

Storage recommendations must start from the app's requirements and repository constraints, not from generic web-app defaults.

Default posture:

- Prefer local-first, native Apple storage and sync options for this iOS app.
- Use Axiom data guidance before recommending SwiftData, Core Data, CloudKit, SQLite, GRDB, SQLiteData, file storage, or a backend.
- Separate product requirements from solution proposals in the PRD.
- document major design decisions in the DesignDocument and refer to this document as needed
- Consider external services only after documenting why native Apple/local options fail the requirements.
- Call out cost, account, privacy, operational, and dependency implications for any external service.

Current storage decision framing:

- Multi-user shared editing, offline capture, media storage, publishing, and subscriber management are first-class requirements.
- SwiftData, Core Data with CloudKit, SQLiteData/GRDB with CloudKit, and plain local file storage should be evaluated before any hosted backend.
- External services such as Supabase, Firebase, custom servers, hosted databases, or paid APIs are not acceptable default recommendations without Rog's explicit approval.
- If a third-party library such as SQLiteData or GRDB is considered, state that it is an external dependency and requires approval under the dependency policy.

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
- Add comments only when they explain non-obvious intent or tradeoffs or identify areas where code review needs guidance e.g. scaffolding or placeholder code which is designed to be deleted before the next release

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
- Unless a test is incorrect and generating a false positive, do not fix failures by changing the test. If you do need to fix a test, seek explicit permission with clear explanations before changing a test

Before completion, run the narrowest useful verification. For project-wide changes, prefer an Xcode build/test command for the relevant scheme and simulator.

## Xcode Project Hygiene

- Keep generated build products out of git.
- Do not commit `xcuserdata`, `DerivedData`, local schemes, or local signing state.
- Keep shared project files, shared schemes, assets, entitlements, and source files committed.
- Do not rewrite `project.pbxproj` unnecessarily.
- keep references to all project docs (PRD etc) within Xcode (but outside any builds)

## Git

Keep commits focused and reviewable.

- Separate dependency, project-structure, feature, and cleanup changes when possible.
- Do not revert user changes unless Rog or Jane explicitly asks.
- Before committing, inspect `git status --short` and make sure the commit contains only the intended files.

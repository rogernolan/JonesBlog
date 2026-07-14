# AGENTS.md

Guidance for AI agents working in this repository.

## Project

InstaBlog is a native iOS app written in Swift and SwiftUI. It targets iOS 26.5 on iPhone and iPad. Favour recent phones and iPads when testing, specifically iPhone 17 and iPhone 17 Pro.

## Project document loading

Do not read the PRD, DesignDecisions.md, or design docs unless the task directly asks for product, architecture, storage, sync, publishing, sharing, or data-model context.

For implementation tasks, prefer:
1. the instructions from the human
2. the issue text
3. the existing code near the change
4. the specific test or failing error
5. only then the smallest relevant project document section

Product context:

- Product requirements live in `Product Requirements Document.md`
- Design decisions live in `DesignDecisions.md` with a summary in `ArchitectureSummary.md`
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

## Skill usage

## Skill usage

Do not read Axiom or Superpowers skills by default.

For small changes, rebases, cherry-picks, conflict resolution, UI tweaks, one-file edits, test fixes, and mechanical edits:
- read no skills
- inspect only the changed files and immediately adjacent types

For feature work:
- prefer existing code patterns and ArchitectureSummary.md
- read at most one relevant Axiom skill only if existing code and ArchitectureSummary.md are insufficient

For debugging:

- use focused diagnostics first
- read the build/debug skill only if diagnostics do not explain the failure

Do not read multiple Axiom skills unless Rog or Jane explicitly asks.
Do not use Superpowers unless Rog or Jane explicitly asks.

## Workflow

The project uses a GitHub project to schedule and plan work. You should work from tickets. If there is no ticket, ask Rog or Jane before proceeding.

- Always run tests before declaring a task complete.
- *Do not* push a broken build or failing test to GitHub
- If verification is blocked by a local environment or simulator issue, report the exact command and failure, run the closest useful fallback verification, and get explicit approval before pushing
- Do not work on main unless Rog/Jane explicitly says otherwise
- Before committing or pushing, re-check the branch name, upstream, and merge-base against `origin/main`. After a ticket branch is merged or abandoned, delete its local and remote branches when safe to do so.
- Do not reuse random stale branches for new work.

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

The storage architecture is settled for v1: SQLiteData backed by SQLite/GRDB with CloudKit SyncEngine.
Do not reconsider persistence technologies unless Rog or Jane explicitly asks for a new architecture decision.

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

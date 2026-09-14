# AGENTS.md

## Project

InstaBlog is a native SwiftUI app targeting iOS 26.5 on iPhone and iPad. Prefer recent test devices, especially iPhone 17 and iPhone 17 Pro.

Primary project: `InstaBlog/InstaBlog.xcodeproj`; sources: `InstaBlog/InstaBlog`; unit tests: `InstaBlog/InstaBlogTests`; UI tests: `InstaBlog/InstaBlogUITests`.

## Context

Inspect the request, ticket, nearby code, and failing test before project documents. Read only relevant sections of `ArchitectureSummary.md`, `DesignDecisions.md`, or `Product Requirements Document.md` when product, architecture, storage, sync, publishing, sharing, or data-model context is required. Treat the PRD as product context, not an implementation mandate. Update `DesignDecisions.md` when a durable technical decision changes; edit the PRD only when Rog or Jane explicitly requests it. Keep project documents referenced in Xcode but outside build targets.

## Workflow and verification

- Work from a ticket; if none exists, ask Rog or Jane before implementing.
- Do not work on `main` without explicit permission.
- Inspect narrowly. For rebases, cherry-picks, and diff transfers, inspect only the source diff and affected files.
- Start with the narrowest relevant build or test and broaden according to risk. Avoid rerunning substantially identical commands without new evidence.
- Never push failing tests, a broken build, or new warnings. If Xcode or simulator problems block verification, report the exact failure, run the closest useful fallback, and obtain explicit approval before pushing.
- For visual UI changes, stop after fast build/unit verification and request a human visual check before long UI suites; run those suites afterward or report that they were intentionally deferred.
- Use clear commands and `apply_patch` for deliberate source edits. Do not use generated shell loops, regex bulk rewrites, or opaque `sed`/`awk` pipelines to edit source.
- Select simulators by UDID. RTK wrappers may split whitespace-containing arguments; use the narrowest suitable fallback only when necessary to preserve them or recover omitted diagnostics.
- Prefer RTK-compatible commands and tell Rog when bypassing RTK. Never return raw `xcodebuild` output unless filtered output cannot explain a failure; do not routinely use `rtk proxy xcodebuild` or `rtk proxy xcrun xcresulttool`.
- Prefer `-only-testing` for the narrowest relevant test and avoid unnecessary rebuilds while iterating.

## Skills

Do not load Axiom or Superpowers unless Rog or Jane explicitly requests them. For feature work only, load at most one relevant Axiom skill when nearby code and `ArchitectureSummary.md` are insufficient.

## Architecture and dependencies

- The v1 storage architecture is settled: SQLiteData backed by SQLite/GRDB with CloudKit SyncEngine. Reconsider it only when Rog or Jane explicitly requests a new architecture decision.
- Adding an external dependency or hosted service requires explicit approval. Prefer Apple frameworks; approved Swift dependencies must use Swift Package Manager with `Package.resolved` committed. Do not use CocoaPods, Carthage, or vendored third-party source.
- Use SwiftUI and native Apple APIs. Keep business logic out of view bodies and persistence/networking behind small, injected, testable boundaries. Use structured concurrency with explicit actor isolation.
- Log all errors. Show a user-visible error when a user action fails or data may be affected.
- Avoid new architectural frameworks without permission.

## Tests

Add deterministic tests proportional to risk: unit tests for model, persistence, parsing, and business logic; UI tests for critical visible flows. Do not change a valid test merely to make it pass. If a test itself is wrong, explain why and obtain explicit permission before editing it.

## Git and project hygiene

- Before committing or pushing, verify the branch, upstream, merge-base against `origin/main`, test/build status, warnings, and intended files with `git status --short`.
- Keep commits focused. Do not reuse stale branches or revert user changes. Delete merged or abandoned ticket branches locally and remotely when safe.
- Do not commit build products, `xcuserdata`, `DerivedData`, local schemes, or local signing state. Commit shared project files, schemes, assets, entitlements, and dependency resolution.
- Avoid unnecessary `project.pbxproj` rewrites.

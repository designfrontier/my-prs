# CLAUDE.md

## Project structure

- `Sources/MyPRs.swift` — SwiftUI menu bar app (`LSUIElement`): `MenuBarExtra` popover with the grouped PR list, polling `Store`, change detection that badges the menu bar icon, and the Settings window (server type/URL/token, orgs, author, drafts, archived repos, poll interval)
- `Sources/Gitea.swift` — Gitea/Forgejo REST client (`/api/v1`, shared by both), per-PR detail fetches, and the Keychain token store
- `Sources/GitHub.swift` — Swift port of `~/dots/bin/my-prs`: GraphQL search against api.github.com, bucketing, bot detection; borrows the token from `gh auth token`
- `build.sh` — compiles `Sources/*.swift` with `swiftc -O -swift-version 6` into `build/MyPRs.app`; `./build.sh install` copies to `~/Applications`
- `icon.swift` — CoreGraphics renderer for the app icon; `swift icon.swift && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns` regenerates it
- `AppIcon.icns` — generated app icon bundled by `build.sh`
- `DISTRIBUTION.md` — options for shipping to other people (source, unsigned release, Developer ID + notarization, Homebrew tap)

### Key directories
- `Sources/` — app Swift sources (only these are compiled into the app)
- `build/` — generated `.app` bundle and iconset output (safe to delete)

## Gotchas
- `withTaskGroup` result collection silently returned nothing under `-O` with Swift 6.3; per-org `Task.detached` + `await task.result` is used instead.
- Gitea/Forgejo review decision is derived from `/pulls/{n}/reviews` (latest decisive review per user) since the API has no `reviewDecision`.
- Bucketing (`PR.bucket` in `GitHub.swift`) mirrors the original script; keep them in sync if the script changes, or diff outputs (`my-prs --json` vs `GitHub.fetch`) to verify.

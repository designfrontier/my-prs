# CLAUDE.md

## Project structure

- `MyPRs.swift` — single-file SwiftUI menu bar app (`LSUIElement`); polls `~/dots/bin/my-prs --json` per configured org, shows the grouped PR list in a `MenuBarExtra` popover, badges the menu bar icon when PRs change bucket/appear/disappear since the popover was last closed, plus a Settings window (orgs, author, drafts, poll interval)
- `build.sh` — compiles with `swiftc -O -swift-version 6` into `build/MyPRs.app`, bakes the shell `PATH` and script path into Info.plist; `./build.sh install` copies to `~/Applications`
- `icon.swift` — CoreGraphics renderer for the app icon; `swift icon.swift && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns` regenerates it
- `AppIcon.icns` — generated app icon bundled by `build.sh`

### Key directories
- `build/` — generated `.app` bundle and iconset output (safe to delete)

## Gotchas
- `withTaskGroup` result collection silently returned nothing under `-O` with Swift 6.3; per-org `Task.detached` + `await task.result` is used instead.

# Distribution

The app is self-contained apart from [`gh`](https://cli.github.com), which it
uses for the user's GitHub token. Every option below assumes users have `gh`
installed and logged in.

URLs assume the repo is published as `designfrontier/my-prs`; adjust if not.

## Before shipping to anyone

- **Default org**: `Settings.defaults` in `Sources/MyPRs.swift` uses `voze-hq`.
  Fine for Voze colleagues; for a public release, default to empty and show
  "Add an org in Settings" in the empty state.
- **Intel Macs**: `build.sh` targets `arm64` only. For a universal binary, build
  both architectures and merge them:

  ```sh
  swiftc -parse-as-library -O -swift-version 6 -target arm64-apple-macos14  -o build/MyPRs-arm64  Sources/*.swift
  swiftc -parse-as-library -O -swift-version 6 -target x86_64-apple-macos14 -o build/MyPRs-x86_64 Sources/*.swift
  lipo -create -output "$APP/Contents/MacOS/MyPRs" build/MyPRs-arm64 build/MyPRs-x86_64
  ```

- **Version**: bump `CFBundleShortVersionString` in `build.sh` for each release.
- **Not the Mac App Store**: the App Store requires the sandbox, which blocks
  running `gh`. Moving there would mean an in-app GitHub OAuth login instead.

## Option 1: build from source

Users run:

```sh
git clone https://github.com/designfrontier/my-prs && cd my-prs && ./build.sh install
```

- Cost: nothing.
- Needs: Xcode command line tools on each machine.
- Gatekeeper: no prompts, because a locally built app is never quarantined.
- Updates: `git pull && ./build.sh install`.

Best for a handful of engineers, who already have the tools.

## Option 2: unsigned zip on GitHub Releases (plus a Homebrew tap)

```sh
./build.sh
ditto -c -k --keepParent build/MyPRs.app MyPRs.zip
gh release create v1.0.0 MyPRs.zip --title "v1.0.0" --notes "…"
```

- Cost: nothing.
- Gatekeeper: blocks the first launch of a downloaded unsigned app. On macOS 15+
  the right-click → Open bypass is gone; users must either go to System Settings
  → Privacy & Security → **Open Anyway**, or run:

  ```sh
  xattr -dr com.apple.quarantine ~/Applications/MyPRs.app
  ```

- The friction is real, and Homebrew is phasing out casks for unsigned apps.
  Treat this as a stopgap.

## Option 3: Developer ID signed and notarized (recommended for wide use)

Downloads open with no warnings. This is how most apps outside the App Store
ship.

One-time setup:

1. Join the [Apple Developer Program](https://developer.apple.com/programs/)
   ($99/yr).
2. In Xcode → Settings → Accounts → Manage Certificates, create a
   **Developer ID Application** certificate.
3. Create an app-specific password at [account.apple.com](https://account.apple.com)
   and save the credentials:

   ```sh
   xcrun notarytool store-credentials myprs \
     --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
   ```

Each release (replaces the ad-hoc `codesign` line in `build.sh`):

```sh
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" build/MyPRs.app
ditto -c -k --keepParent build/MyPRs.app MyPRs.zip
xcrun notarytool submit MyPRs.zip --keychain-profile myprs --wait
xcrun stapler staple build/MyPRs.app
ditto -c -k --keepParent build/MyPRs.app MyPRs.zip   # re-zip with the stapled ticket
gh release create v1.0.0 MyPRs.zip
```

`--options runtime` turns on the hardened runtime, which notarization
requires. It doesn't stop the app from running `gh`.

### Automating it

A GitHub Actions workflow on a `macos-latest` runner, triggered by `v*` tags,
can run the steps above. Store these as repo secrets:

- the certificate exported as a base64 `.p12`, plus its password (import it
  into a temporary keychain in the workflow)
- `APPLE_ID`, `TEAM_ID`, and the app-specific password, passed straight to
  `notarytool submit --apple-id … --team-id … --password …`

## Homebrew tap (works with option 2 or 3)

Create a repo named `designfrontier/homebrew-tap` and add `Casks/my-prs.rb`:

```ruby
cask "my-prs" do
  version "1.0.0"
  sha256 "…"  # shasum -a 256 MyPRs.zip
  url "https://github.com/designfrontier/my-prs/releases/download/v#{version}/MyPRs.zip"
  name "My PRs"
  desc "Menu bar list of your open GitHub pull requests"
  homepage "https://github.com/designfrontier/my-prs"

  depends_on formula: "gh"
  depends_on macos: ">= :sonoma"

  app "MyPRs.app"
end
```

Users install with:

```sh
brew install --cask designfrontier/tap/my-prs
```

The cask also installs `gh`. Users upgrade with `brew upgrade`.

## Auto-updates

Only worth adding with option 3. [Sparkle](https://sparkle-project.org) is the
standard framework, but it needs a Swift package or Xcode project rather than a
bare `swiftc` build. Until then, Homebrew's `brew upgrade` handles updates.

## Recommendation

1. **Now**: option 1 for colleagues.
2. **When more than a few people want it**: option 3 via GitHub Releases, with
   the Homebrew tap and a tag-triggered Actions workflow.

Skip option 2 unless a download is needed before the Developer account exists.

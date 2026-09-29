# My PRs

A macOS menu bar app that shows your open pull requests, grouped by what each
one is waiting on: ready to merge, changes requested, conflicting, CI failing,
CI running, or waiting on review.

It queries GitHub, Gitea or Forgejo on an interval and puts a dot on the menu
bar icon when a PR changes state, appears, or is merged/closed since you last
looked.

## Requirements

- macOS 14+ on Apple Silicon
- GitHub: [`gh`](https://cli.github.com), authenticated (`gh auth login`)
- Gitea / Forgejo: an access token with read access to repositories and issues
- To build from source: Xcode command line tools (`xcode-select --install`)

## Install

```sh
./build.sh install          # builds and copies to ~/Applications/MyPRs.app
open ~/Applications/MyPRs.app
```

The app uses `gh`'s existing login (`gh auth token`), so there is no separate
sign-in. It looks for `gh` in `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`.

For Gitea or Forgejo, pick the server type in Settings, enter the instance URL
(e.g. `codeberg.org`) and paste a token. The token is stored in the Keychain.

## Use

Click the icon in the menu bar to open the list. Click a PR to open it in the browser.

- **Blue dot on a row**: that PR changed since you last closed the list.
- **Dot on the menu bar icon**: something changed. Closing the list clears it.
- **⌘R** refreshes, **⌘,** opens Settings, **⌘Q** quits.

### Settings

| Setting        | Default   |                                        |
| -------------- | --------- | -------------------------------------- |
| Server         | GitHub    | GitHub, Gitea or Forgejo               |
| URL, Token     |           | Gitea / Forgejo only                   |
| Orgs           | `voze-hq` | Comma or space separated; each is queried |
| Author         | `@me`     | Any login on the selected server       |
| Include drafts | off       |                                        |
| Poll every     | 5 min     | 1–60                                   |

On Gitea / Forgejo, "approved" means at least one approval and no outstanding
change requests; branch protection's required approval count is not checked.

See [DISTRIBUTION.md](DISTRIBUTION.md) for ways to ship it to other people.

## Development

```sh
./build.sh                  # builds build/MyPRs.app
swift icon.swift && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns   # regenerate the icon
```

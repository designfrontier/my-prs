# My PRs

A macOS menu bar app that shows your open pull requests, grouped by what each
one is waiting on: ready to merge, changes requested, conflicting, CI failing,
CI running, or waiting on review.

It polls on an interval and puts a dot on the menu bar icon when a PR changes
state, appears, or is merged/closed since you last looked.

## Requirements

- macOS 14+ on Apple Silicon
- Xcode command line tools (`xcode-select --install`)
- [`gh`](https://cli.github.com), authenticated (`gh auth login`)
- Node.js
- The [`my-prs`](https://github.com/designfrontier/dots/blob/master/bin/my-prs) script, by default at `~/dots/bin/my-prs`

## Install

```sh
./build.sh install          # builds and copies to ~/Applications/MyPRs.app
open ~/Applications/MyPRs.app
```

The build records your current shell `PATH` so the app can find `node` and
`gh`. Rebuild if either moves (e.g. switching Node versions with nvm).

To use a script somewhere else:

```sh
MY_PRS_SCRIPT=/path/to/my-prs ./build.sh install
```

## Use

Click the icon in the menu bar to open the list. Click a PR to open it on GitHub.

- **Blue dot on a row**: that PR changed since you last closed the list.
- **Dot on the menu bar icon**: something changed. Closing the list clears it.
- **⌘R** refreshes, **⌘,** opens Settings, **⌘Q** quits.

### Settings

| Setting        | Default   |                                        |
| -------------- | --------- | -------------------------------------- |
| Orgs           | `voze-hq` | Comma or space separated; each is queried |
| Author         | `@me`     | Any GitHub login                       |
| Include drafts | off       |                                        |
| Poll every     | 5 min     | 1–60                                   |

## Development

```sh
./build.sh                  # builds build/MyPRs.app
swift icon.swift && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns   # regenerate the icon
```

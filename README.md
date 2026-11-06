# LidAwake

A tiny macOS menu bar app that toggles `pmset -a disablesleep`, so your Mac keeps running with the lid closed.

- Moon icon: the Mac sleeps normally.
- Sun icon: sleep is disabled, closing the lid won't suspend it.

Left-click the icon to toggle. Right-click (or control-click) for the menu.

While it's keeping your Mac awake, it also watches the Mac's heat and battery and alerts your phone if it runs hot or low (see [Phone alerts](#phone-alerts)).

## Install

```sh
brew install innowellteam/lidawake/lidawake
brew services start lidawake   # start now and at every login
```

The repo is internal to the Innowell GitHub, so brew clones it with your GitHub login. If the install can't read the repo, run `gh auth login` and then `gh auth setup-git` so git can use that login. Brew installs a prebuilt app that runs on Apple Silicon and Intel, so there's nothing to compile.

LidAwake keeps itself up to date. Once a day it runs `brew update` and `brew upgrade lidawake`, then restarts into the new version. To update right away instead: `brew update && brew upgrade lidawake && brew services restart lidawake`. Versions before 1.2.0 don't update themselves, so they need that once.

## Recommended usage

1. Connect to your phone's hotspot.
2. Enable `/remote-control` in Claude Code.
3. Start your long-running prompt.
4. Close your laptop and toss it in your bag.
5. Go to the pub.
6. Check your phone each time you go to the bathroom.

## Phone alerts

While sleep is disabled, LidAwake sends alerts to your phone through [ntfy](https://ntfy.sh).

Heat, from macOS's thermal pressure (the heat level macOS itself uses to decide when to slow the Mac down):

- Hot: a high-priority alert suggesting you give it some air.
- Critical: an urgent alert. With "Let Mac Sleep If Critically Hot" ticked in the menu (the default), LidAwake then turns sleep back on, so a closed Mac goes to sleep and cools down. Untick it to only get the alert.
- Back to normal: an all-clear.

Battery, at the same moments macOS shows its own low battery warnings on the Mac's screen (which nobody sees with the lid closed):

- 10%: a high-priority alert.
- 2%: an urgent alert.

Each alert gives macOS's estimate of the time left. LidAwake sends them when macOS raises its low battery event, so each fires once until the Mac is back on power.

To set it up, install the ntfy app on your phone, choose "Phone Alerts…" from the menu, copy the topic, subscribe to it in the app, then hit "Send Test Alert".

Things worth knowing:

- The topic is random and created on first launch. Anyone who knows it can read your alerts, so keep it to yourself.
- Alerts go through ntfy.sh's public servers. To use your own ntfy server, run `defaults write org.innowell.lidawake NtfyURL https://ntfy.example.com/<topic>` and restart LidAwake.
- macOS reports heat as a level (normal, warm, hot, critical), not a temperature, so the menu shows the level rather than a °C figure.
- Alerts need a network connection, so a phone hotspot works fine.

## How it gets root

`pmset` needs root. The first time you toggle, LidAwake asks for your admin password once and installs `/etc/sudoers.d/lidawake`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

The rule is written and validated with `visudo` as root, and only allows those two exact commands. After that, toggles run `sudo -n pmset ...` with no prompt. Use "Remove sudo Rule…" in the menu to take it out again.

## Things to know

- With sleep disabled the Mac never sleeps, including idle sleep and Apple menu > Sleep. Before it goes in a bag, set up [phone alerts](#phone-alerts).
- The setting is system-wide and outlives the app. Quitting LidAwake doesn't change it, and the icon always reflects the real state (it re-checks every 15 seconds, so changes made in a terminal show up too).

## Uninstall

```sh
sudo pmset -a disablesleep 0
sudo rm /etc/sudoers.d/lidawake
brew services stop lidawake
brew uninstall lidawake
brew untap innowellteam/lidawake
```

## Build locally

Building needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
brew services stop lidawake   # so you don't get two icons
make                          # builds build/LidAwake.app
open build/LidAwake.app
```

To try whatever is on `main` through brew: `brew update && brew reinstall --HEAD lidawake`.

## Release a new version

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, commit, then `git tag vX.Y.Z`.
2. `make clean bottle` builds the app and replaces `bottles/` with the new prebuilt bottle, printing its sha256.
3. In `Formula/lidawake.rb`, set `tag:` to `vX.Y.Z`, `revision:` to the output of `git rev-parse vX.Y.Z^{}`, and the bottle `sha256` to the one `make` printed.
4. Commit the formula and `bottles/`, then `git push origin main vX.Y.Z`.
5. `brew update && brew upgrade lidawake && brew services restart lidawake`

Brew reads the bottle from its own clone of this repo, the same way it reads the source, so neither needs a GitHub token.

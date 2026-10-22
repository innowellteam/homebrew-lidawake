# LidAwake

A tiny macOS menu bar app that toggles `pmset -a disablesleep`, so your Mac keeps running with the lid closed.

- Moon icon: the Mac sleeps normally.
- Sun icon: sleep is disabled, closing the lid won't suspend it.

Left-click the icon to toggle. Right-click (or control-click) for the menu.

## Install

```sh
brew tap sheldon-innowell/lidawake https://github.com/sheldon-innowell/lidawake.git
brew trust sheldon-innowell/lidawake
HOMEBREW_GITHUB_API_TOKEN=$(gh auth token) brew install lidawake
brew services start lidawake   # start now and at every login
```

The repo is private, so brew fetches it with git using your GitHub login. You need access to the repo and git set up to use `gh` for GitHub (`gh auth setup-git`). Homebrew downloads source inside a sandbox where `gh` can't read its token from the keychain, so pass it on the command line as above. Do the same for `brew upgrade lidawake`. Don't export it from your shell profile; the `gh` token has far broader access than brew needs.

It builds from source, so it also needs the Xcode Command Line Tools (`xcode-select --install`).

## How it gets root

`pmset` needs root. The first time you toggle, LidAwake asks for your admin password once and installs `/etc/sudoers.d/lidawake`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

The rule is written and validated with `visudo` as root, and only allows those two exact commands. After that, toggles run `sudo -n pmset ...` with no prompt. Use "Remove sudo Rule…" in the menu to take it out again.

## Things to know

- With sleep disabled the Mac never sleeps, including idle sleep and Apple menu > Sleep. Don't put it in a bag like that.
- The setting is system-wide and outlives the app. Quitting LidAwake doesn't change it, and the icon always reflects the real state (it re-checks every 15 seconds, so changes made in a terminal show up too).

## Uninstall

```sh
sudo pmset -a disablesleep 0
sudo rm /etc/sudoers.d/lidawake
brew services stop lidawake
brew uninstall lidawake
brew untap sheldon-innowell/lidawake
```

## Build locally

```sh
brew services stop lidawake   # so you don't get two icons
make                          # builds build/LidAwake.app
open build/LidAwake.app
```

To try whatever is on `main` through brew: `HOMEBREW_GITHUB_API_TOKEN=$(gh auth token) brew reinstall --HEAD lidawake`.

## Release a new version

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, commit.
2. `git tag vX.Y.Z && git push origin main vX.Y.Z`
3. In `Formula/lidawake.rb`, set `tag:` to `vX.Y.Z` and `revision:` to the output of `git rev-parse vX.Y.Z^{}`. Commit and push.
4. `brew update && HOMEBREW_GITHUB_API_TOKEN=$(gh auth token) brew upgrade lidawake && brew services restart lidawake`

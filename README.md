# WellAwake

A tiny macOS menu bar app that toggles `pmset -a disablesleep`, so your Mac keeps running with the lid closed.

- Moon icon: the Mac sleeps normally.
- Sun icon: sleep is disabled, closing the lid won't suspend it.

Left-click the icon to toggle. Right-click (or control-click) for the menu.

To stay awake for a set time, right-click and choose **Stay Awake For** 15, 30, 45 minutes or 1 hour. When the time is up WellAwake turns sleep back on, and a closed Mac goes to sleep. The menu shows how long is left. Left-click to stop early, or pick another time to restart the clock.

When sleep is disabled and you close the lid with no monitor on, WellAwake adds a stand-in screen the size of the built-in one and switches the built-in screen off, so macOS moves your windows onto the stand-in. They keep running there, so browser automation such as Claude in Chrome keeps working. Open the lid and the built-in screen comes back and the stand-in goes. With a monitor on, WellAwake leaves screens alone so you can keep using clamshell mode. See [Screens with the lid closed](#screens-with-the-lid-closed).

Tick "Virtual Screen" in the menu to add a 1920x1080 screen that exists only in software, to run things such as Claude in Chrome on out of your way, so you don't need BetterDisplay or a dummy plug.

While it's keeping your Mac awake, it also watches the Mac's heat and battery and alerts your phone if it runs hot or low (see [Phone alerts](#phone-alerts)).

## Install

```sh
brew install innowellteam/wellawake/wellawake
brew services start wellawake   # start now and at every login
```

Brew installs a prebuilt app that runs on Apple Silicon and Intel, so there's nothing to compile.

WellAwake keeps itself up to date. Once a day it runs `brew update` and `brew upgrade wellawake`, then restarts into the new version. Update checks and automatic restarts wait while WellAwake is keeping the Mac awake, so they do not interrupt a closed-lid session. To update right away instead: `brew update && brew upgrade wellawake && brew services restart wellawake`.

## Coming from LidAwake

WellAwake was called LidAwake until 2.0. A LidAwake install from 1.2.0 on moves over by itself at its next daily update: its last version installs WellAwake and starts it at login, and WellAwake then uninstalls LidAwake. Your settings come across, including the phone alert topic, so the ntfy app keeps working. LidAwake's sudo rule keeps working too, so there's no new password prompt.

The tap has been renamed to `innowellteam/wellawake`. LidAwake's move-over still works: the last LidAwake version and WellAwake find the tap by its formula, even after Homebrew renames its local copy. On Homebrew 7, if `brew` reports that the renamed tap is untrusted, run `brew trust innowellteam/wellawake` once. WellAwake's updater already runs `brew trust --tap` for its own tap.

To move over straight away, or from a version before 1.2.0:

```sh
brew services stop lidawake && brew uninstall lidawake
brew install innowellteam/wellawake/wellawake && brew services start wellawake
```

`Bridge/` and `Formula/lidawake.rb` are that last LidAwake version. Leave them in place while any LidAwake installs might still be around.

## Recommended usage

1. Connect to your phone's hotspot.
2. Enable `/remote-control` in Claude Code.
3. Start your long-running prompt.
4. Close your laptop and toss it in your bag.
5. Go to the pub.
6. Check your phone each time you go to the bathroom.

## Phone alerts

While sleep is disabled, WellAwake sends alerts to your phone through [ntfy](https://ntfy.sh).

Heat, from macOS's thermal pressure (the heat level macOS itself uses to decide when to slow the Mac down):

- Hot: a high-priority alert suggesting you give it some air.
- Critical: an urgent alert. With "Let Mac Sleep If Critically Hot" ticked in the menu (the default), WellAwake then turns sleep back on, so a closed Mac goes to sleep and cools down. Untick it to only get the alert.
- Back to normal: an all-clear.

Battery, at the same moments macOS shows its own low battery warnings on the Mac's screen (which nobody sees with the lid closed):

- 10%: a high-priority alert.
- 2%: an urgent alert.

Each alert gives macOS's estimate of the time left. WellAwake sends them when macOS raises its low battery event, so each fires once until the Mac is back on power.

To set it up, install the ntfy app on your phone, choose "Phone Alerts…" from the menu, copy the topic, subscribe to it in the app, then hit "Send Test Alert".

Things worth knowing:

- The topic is random and created on first launch. Anyone who knows it can read your alerts, so keep it to yourself.
- Alerts go through ntfy.sh's public servers. To use your own ntfy server, run `defaults write org.innowell.wellawake NtfyURL https://ntfy.example.com/<topic>` and restart WellAwake.
- macOS reports heat as a level (normal, warm, hot, critical), not a temperature, so the menu shows the level rather than a °C figure.
- Alerts need a network connection, so a phone hotspot works fine.

## How it gets root

`pmset` needs root. The first time you toggle, WellAwake asks for your admin password once and installs `/etc/sudoers.d/wellawake`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -b lowpowermode 0, /usr/bin/pmset -b lowpowermode 1, /usr/bin/pmset -c lowpowermode 0, /usr/bin/pmset -c lowpowermode 1
```

The rule is written and validated with `visudo` as root, and only allows those six exact commands. The `lowpowermode` ones are only used if you tick **Low Power Mode When Lid Closes**. A rule installed by an older version covers sleep only, so ticking that option the first time asks for your password once more to update it. After that, toggles run `sudo -n pmset ...` with no prompt. Use "Remove sudo Rule…" in the menu to take it out again.

## Things to know

- With sleep disabled the Mac never sleeps, including idle sleep and Apple menu > Sleep. Before it goes in a bag, set up [phone alerts](#phone-alerts).
- When WellAwake disables sleep, a separate worker restores sleep if the app quits or crashes. If both processes stop before recovery, the next launch retries it. A failed restore stays pending until the required sudo rule is available. If the lid is closed when sleep is restored and no external display is connected, WellAwake also puts the Mac to sleep, because macOS won't do that for a lid that is already shut.
- The setting is system-wide. Avoid running another app that manages `pmset disablesleep` at the same time. WellAwake does not claim an override it finds already active at launch. The icon re-checks the real setting every 15 seconds.

## Uninstall

```sh
sudo pmset -a disablesleep 0
sudo rm -f /etc/sudoers.d/wellawake /etc/sudoers.d/lidawake
brew services stop wellawake
brew uninstall wellawake
brew untap innowellteam/wellawake
```

## Build locally

Building needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
brew services stop wellawake  # so you don't get two icons
make                          # builds build/WellAwake.app
make test                     # exercises recovery with simulated power settings
open build/WellAwake.app
```

To try whatever is on `main` through brew: `brew update && brew reinstall --HEAD wellawake`.

## Release a new version

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, commit, then `git tag vX.Y.Z`.
2. `make clean bottle` builds the app and replaces the WellAwake bottle in `bottles/` with the new one, printing its sha256.
3. In `Formula/wellawake.rb`, set `tag:` to `vX.Y.Z`, `revision:` to the output of `git rev-parse vX.Y.Z^{}`, and the bottle `sha256` to the one `make` printed.
4. Commit the formula and `bottles/`, then `git push origin main vX.Y.Z`.
5. `brew update && brew upgrade wellawake && brew services restart wellawake`

Brew reads the bottle from its own clone of this repo, the same way it reads the source, so neither needs a GitHub token.

## Screens with the lid closed

WellAwake makes two kinds of screen that exist only in software. macOS treats them as external monitors.

Virtual Screen, ticked in the menu: a 1920x1080 screen called WellAwake. It's there while WellAwake is running with the option ticked, and it's off by default.

- Put a browser for Claude in Chrome, or anything else, on it, out of your way. Closing the lid doesn't affect it.
- Recording demos: it's a fixed 1080p screen to put a browser window on. Move windows to it with the mouse, or set where it sits in System Settings > Displays (macOS remembers).
- From a script: `defaults write org.innowell.wellawake VirtualScreen -bool true` (or `false`). WellAwake picks it up within 2 seconds.

The stand-in for a closed lid: a screen the size of the built-in one, called "WellAwake (lid closed)". WellAwake adds it while it's keeping the Mac awake with the lid closed and no monitor on, unless Virtual Screen is ticked, which does the same job.

With either screen there and the lid closed, WellAwake switches the built-in screen off, and macOS moves its windows onto WellAwake's screen. Without that, the built-in display would sleep, the Mac would lock, and Chrome would stop drawing pages nobody can see. While keeping the Mac awake on one of its screens, WellAwake also holds off idle display sleep, which would lock the Mac. So the Mac stays unlocked while the lid is closed. When the lid opens, WellAwake switches the built-in screen back on. It also does that when it quits, crashes or restarts.

Both use unpublished parts of macOS: CGVirtualDisplay for the screens (as BetterDisplay and DeskPad do) and SkyLight's switch for turning a screen off (as Displays settings does). A macOS update could change them. If macOS refuses the Virtual Screen, WellAwake says so and unticks it. If it refuses the stand-in, WellAwake alerts your phone and puts the built-in display to sleep instead, which locks the Mac. If it refuses to switch the built-in screen off, WellAwake alerts your phone, and the windows keep running on the built-in screen behind the closed lid.

## Low Power Mode with the lid closed

Tick **Low Power Mode When Lid Closes** to have WellAwake turn on macOS Low Power Mode whenever it is keeping the Mac awake and the lid is closed. It is off by default. WellAwake checks every 15 seconds, so it switches on shortly after you close the lid.

It only switches back what it changed. If Low Power Mode was already on for battery, for example, WellAwake leaves that alone. Its change is undone when you open the lid, sleep comes back on, you untick the option, you remove the sudo rule, or WellAwake quits. If WellAwake crashes, it undoes the change the next time it runs.

In one afternoon of session logs on a MacBook Pro running on battery with the lid closed, Low Power Mode used about 8 W against 14 to 19 W without it, and battery drain fell from about 26% to 11% an hour. Without it, macOS reported "Warm" after 17 minutes. With it, heat stayed "Normal" for 70 minutes. That was one run each with everyday apps open, so treat the numbers as a guide. The cost is slower performance while the lid is closed.

## Session logs

To collect a baseline, turn on **Record Session Logs** in the menu. This is off by default and stays on until you turn it off. While sleep is disabled, WellAwake saves a local JSON Lines file for each logging session. Choose **Show Session Logs in Finder** to open the folder. Nothing is uploaded.

Each sample records the time, lid state, macOS thermal pressure, Low Power Mode, battery charge, power source, and the battery's reported voltage and current when available. Samples are taken about once a minute and when the lid, heat level, or Low Power Mode changes. Battery current and voltage are hardware-reported values, and may not be available on every Mac. Battery current is signed, with negative values indicating discharge. An absent value is omitted. Thermal pressure is not a temperature reading and cannot show the temperature inside a bag. These logs cannot establish that a Mac is safe in a bag.

Low Power Mode is observed, not changed. To compare sessions, switch it yourself in macOS and use a similar workload and starting conditions. Logging stops when you turn it off or sleep is enabled again. A final sample records when logging is switched off or sleep is requested by the timer, heat safeguard, or menu. A request does not prove sleep succeeded; a failure is recorded if WellAwake observes one.

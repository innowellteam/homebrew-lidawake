import AppKit

extension AppDelegate {
    @objc func toggleVirtualScreen() {
        let enable = !UserDefaults.standard.bool(forKey: virtualScreenKey)
        UserDefaults.standard.set(enable, forKey: virtualScreenKey)
        let refused = updateScreens(awake: keepingAwake, lidClosed: lidIsClosed())
        refresh()
        guard refused else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "WellAwake couldn't add the virtual screen"
        alert.informativeText = "macOS refused to create it. It uses an unpublished part of macOS, which a macOS update may have changed."
        alert.runModal()
    }

    @objc func bringWindowsBack() {
        windowRecovery.bringAllWindowsBack()
    }

    // Every 2 seconds, so a closed lid gets its screen before the built-in screen could sleep and lock the Mac.
    func checkLid() {
        let closed = lidIsClosed()
        let awake = closed ? sleepDisabled() : keepingAwake
        // The menu's virtual screen counts as an external monitor, so macOS keeps a closed Mac running for
        // it. Unless WellAwake is keeping the Mac awake, closing the lid should still mean sleep.
        if closed, !lidWasClosed, !awake, virtualScreens.hasScreen { sleepNowIfLidClosed() }
        lidWasClosed = closed
        updateScreens(awake: awake, lidClosed: closed)
    }

    // From the 2-second lid check, refresh and the menu. True if macOS refused the menu's virtual screen.
    @discardableResult
    func updateScreens(awake: Bool, lidClosed: Bool) -> Bool {
        let displays = onlineDisplayStates() ?? []
        let realMonitorIDs = Set(displays.filter { !$0.builtIn && !$0.wellAwake }.map(\.id))
        if let lastRealMonitorIDs, lastRealMonitorIDs != realMonitorIDs {
            let existingWindows = windowsOnVirtualBeforeRealChange
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 750_000_000)
                windowRecovery.bringNewWindowsBack(excluding: existingWindows)
            }
        }
        lastRealMonitorIDs = realMonitorIDs
        windowsOnVirtualBeforeRealChange = windowRecovery.windowsOnVirtualScreen()
        let plan = screenPlan(virtualScreenTicked: UserDefaults.standard.bool(forKey: virtualScreenKey), keepingAwake: awake, lidClosed: lidClosed,
                              otherMonitor: displays.contains { !$0.builtIn && !$0.wellAwake })
        let refused = virtualScreens.apply(plan, displays: displays, lidScreenSize: builtInScreenSize)
        if refused.virtualScreen {
            // Untick it rather than ask again on every check. `toggleVirtualScreen` says why.
            NSLog("WellAwake: macOS refused the virtual screen")
            UserDefaults.standard.set(false, forKey: virtualScreenKey)
            virtualScreenItem.state = .off
        }
        if refused.lidScreen {
            NSLog("WellAwake: macOS refused the lid-closed screen")
            Task { await notifyPhone(title: "WellAwake couldn't add a screen for the closed lid",
                                     message: "So the Mac's own screen is going to sleep, which locks it, and apps that need a screen, such as Claude in Chrome, stop drawing. A macOS update may have changed the unpublished part of macOS that WellAwake uses.",
                                     priority: 4, tag: "warning") }
        }
        if refused.builtInOff {
            NSLog("WellAwake: macOS refused to switch the built-in screen off")
            Task { await notifyPhone(title: "WellAwake couldn't switch the Mac's own screen off",
                                     message: "So it stays on behind the closed lid, and its windows stay on it rather than moving to WellAwake's screen. They keep running. A macOS update may have changed the unpublished part of macOS that WellAwake uses.",
                                     priority: 4, tag: "warning") }
        }
        // No screen of WellAwake's to draw on: put the built-in screen to sleep the old way.
        if lidClosed, awake, !virtualScreens.hasScreen {
            sleepDisplayIfNeeded(lidClosed: true, displays: displays, isKeepingAwake: { true }) {
                let result = run("/usr/bin/pmset", ["displaysleepnow"])
                if result.status != 0 { NSLog("WellAwake: display sleep failed: \(result.output)") }
            }
        }
        screenWatcher.check(virtualScreen: virtualScreenDisplay())
        return refused.virtualScreen
    }
}

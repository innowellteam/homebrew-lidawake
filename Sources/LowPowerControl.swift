import AppKit

extension AppDelegate {
    @objc func toggleLowPower() {
        let enable = !UserDefaults.standard.bool(forKey: lowPowerWhenLidClosedKey)
        if enable && !ensureLowPowerPermission() { return }
        UserDefaults.standard.set(enable, forKey: lowPowerWhenLidClosedKey)
        refresh()
    }

    // Runs on every refresh, so a closed lid is picked up within the 15-second check.
    func updateLowPowerMode(awake: Bool) {
        let wanted = awake && UserDefaults.standard.bool(forKey: lowPowerWhenLidClosedKey) && lidIsClosed()
        var owned = Set(UserDefaults.standard.stringArray(forKey: lowPowerOwnedKey) ?? [])
        guard wanted || !owned.isEmpty else { return }
        let plan = lowPowerPlan(wanted: wanted, settings: wanted ? currentLowPowerSettings() : [:], owned: owned)
        for source in plan.turnOn {
            // Recorded first, so a crash mid-change still leaves LidAwake responsible for undoing it.
            owned.insert(source)
            UserDefaults.standard.set(owned.sorted(), forKey: lowPowerOwnedKey)
            if !trySetLowPowerMode(source, true) {
                owned.remove(source)
                NSLog("LidAwake: couldn't turn on Low Power Mode for pmset -\(source)")
            }
        }
        for source in plan.restore {
            if trySetLowPowerMode(source, false) { owned.remove(source) } else { NSLog("LidAwake: couldn't restore Low Power Mode for pmset -\(source)") }
        }
        UserDefaults.standard.set(owned.sorted(), forKey: lowPowerOwnedKey)
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateLowPowerMode(awake: false)
    }
}

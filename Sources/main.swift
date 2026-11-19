import AppKit
import IOKit.ps
import notify

// pmset needs root. On first toggle we install this rule (one admin prompt) so later
// toggles can run `sudo -n pmset ...` without asking. It allows exactly two commands.
let sudoersPath = "/etc/sudoers.d/wellawake"

// Heat alerts are posted here. A random ntfy.sh topic is generated on first launch; point it at
// your own server with `defaults write org.innowell.wellawake NtfyURL <url>`.
let ntfyURLKey = "NtfyURL"
let sleepWhenCriticalKey = "SleepWhenCritical"

// WellAwake keeps itself up to date through brew. Brew installs it at
// <prefix>/Cellar/wellawake/<version>/WellAwake.app; a local build lives elsewhere and never updates.
let brewPrefix: String? = {
    let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    return path.range(of: "/Cellar/wellawake/").map { String(path[..<$0.lowerBound]) }
}()
let lastUpdateCheckKey = "LastUpdateCheck"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let toggleItem = NSMenuItem(title: "Stay Awake With Lid Closed", action: #selector(toggle), keyEquivalent: "")
    let timedItem = NSMenuItem(title: "Stay Awake For", action: nil, keyEquivalent: "")
    let timeLeftItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let lowPowerItem = NSMenuItem(title: "Low Power Mode When Lid Closes", action: #selector(toggleLowPower), keyEquivalent: "")
    let virtualScreenItem = NSMenuItem(title: "Virtual Screen", action: #selector(toggleVirtualScreen), keyEquivalent: "")
    let watchScreenItem = NSMenuItem(title: "Watch Virtual Screen", action: #selector(watchVirtualScreen), keyEquivalent: "")
    let bringWindowsBackItem = NSMenuItem(title: "Bring Windows Back", action: #selector(bringWindowsBack), keyEquivalent: "")
    let virtualScreens = VirtualScreens()
    let screenWatcher = ScreenWatcher()
    let windowRecovery = WindowRecovery()
    var lastRealMonitorIDs: Set<CGDirectDisplayID>?
    var windowsOnVirtualBeforeRealChange = Set<WindowIdentity>()
    // As of the last refresh, and whether the lid was closed at the last 2-second check.
    var keepingAwake = false
    var lidWasClosed = false
    let heatItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let sleepWhenCriticalItem = NSMenuItem(title: "Let Mac Sleep If Critically Hot", action: #selector(toggleSleepWhenCritical), keyEquivalent: "")
    let sessionLoggingItem = NSMenuItem(title: "Record Session Logs", action: #selector(toggleSessionLogging), keyEquivalent: "")
    let removeRuleItem = NSMenuItem(title: "Remove sudo Rule…", action: #selector(removeRule), keyEquivalent: "")
    // Highest heat level we've alerted about since the Mac was last back below "Hot".
    var alertedState = ProcessInfo.ThermalState.nominal
    var checkingForUpdate = false
    var recovery: SleepRecovery?
    var ownsSleepOverride = false
    // The chosen length of a timed session and when it ends. Nil while sleeping normally or
    // staying awake with no time limit.
    var sessionLength: Int?
    var awakeUntil: Date?
    var sessionTimer: Timer?
    let sessionLog = SessionLog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        sessionLog.onError = { error in
            UserDefaults.standard.set(false, forKey: sessionLoggingKey)
            DispatchQueue.main.async {
                self.refresh()
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(error: error)
                alert.messageText = "WellAwake couldn't save the session log"
                alert.informativeText = "Session logging has been turned off. \(error.localizedDescription)"
                alert.runModal()
            }
        }
        adoptLidAwakeSettings()
        // In case WellAwake stopped with the lid closed and the built-in screen switched off.
        switchBuiltInScreenBackOn()
        startRecovery()
        UserDefaults.standard.register(defaults: [sleepWhenCriticalKey: true])
        if UserDefaults.standard.string(forKey: ntfyURLKey) == nil {
            let topic = "wellawake-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
            UserDefaults.standard.set("https://ntfy.sh/\(topic)", forKey: ntfyURLKey)
        }

        toggleItem.target = self
        lowPowerItem.target = self
        virtualScreenItem.target = self
        watchScreenItem.target = self
        bringWindowsBackItem.target = self
        windowRecovery.onNeedsPermission = { [unowned self] in askForAccessibility() }
        sleepWhenCriticalItem.target = self
        removeRuleItem.target = self
        sessionLoggingItem.target = self
        let showLogsItem = NSMenuItem(title: "Show Session Logs in Finder", action: #selector(showSessionLogs), keyEquivalent: "")
        showLogsItem.target = self
        let phoneAlertsItem = NSMenuItem(title: "Phone Alerts…", action: #selector(showPhoneAlerts), keyEquivalent: "")
        phoneAlertsItem.target = self
        let aboutItem = NSMenuItem(title: "About WellAwake", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        timedItem.submenu = NSMenu()
        for minutes in sessionMinutes {
            let item = NSMenuItem(title: sessionMenuTitle(minutes: minutes), action: #selector(stayAwakeFor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            timedItem.submenu!.addItem(item)
        }
        menu.addItem(toggleItem)
        menu.addItem(timedItem)
        menu.addItem(timeLeftItem)
        menu.addItem(lowPowerItem)
        menu.addItem(virtualScreenItem)
        menu.addItem(watchScreenItem)
        menu.addItem(bringWindowsBackItem)
        menu.addItem(.separator())
        menu.addItem(heatItem)
        menu.addItem(sleepWhenCriticalItem)
        menu.addItem(phoneAlertsItem)
        menu.addItem(sessionLoggingItem)
        menu.addItem(showLogsItem)
        menu.addItem(.separator())
        menu.addItem(removeRuleItem)
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem(title: "Quit WellAwake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self

        let button = statusItem.button!
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.checkHeat() }
        }
        // powerd posts this as the battery drops into each of macOS's low battery warning levels, the
        // same trigger as macOS's own warning on the Mac's screen. Each level is posted once until
        // the Mac is back on power, so there's nothing to deduplicate.
        var lowBatteryToken: Int32 = 0
        notify_register_dispatch(kIOPSNotifyLowBattery, &lowBatteryToken, .main) { _ in
            MainActor.assumeIsolated { self.warnLowBattery() }
        }
        checkHeat()
        RunLoop.main.add(Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkLid() }
        }, forMode: .common)
        // Pick up changes made outside the app, e.g. pmset run in a terminal.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.checkHeat()
                self.endSessionIfOver()
            }
        }
        // A minute after launch, so the network is up after a login, then hourly.
        RunLoop.main.add(Timer(fire: Date().addingTimeInterval(60), interval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkForUpdate() }
        }, forMode: .common)
        // After a move from LidAwake, give the stand-in that started us half a minute to finish, then
        // remove it. Update checks wait for this, so the two don't run brew at the same time.
        if let prefix = brewPrefix {
            checkingForUpdate = true
            Task.detached {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                removeLidAwake(brewPrefix: prefix)
                await MainActor.run { self.checkingForUpdate = false }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateLowPowerMode(awake: false)
        switchBuiltInScreenBackOn()
    }

    func startRecovery() {
        recovery = try? SleepRecovery(onExit: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.recovery = nil
                self.ownsSleepOverride = false
                self.startRecovery()
                self.refresh()
            }
        })
    }

    // At most once a day. A failed check (say, while offline) is retried on the next hourly tick.
    func checkForUpdate() {
        let lastCheck = UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date ?? .distantPast
        guard !ownsSleepOverride, let prefix = brewPrefix, !checkingForUpdate, Date().timeIntervalSince(lastCheck) > 24 * 60 * 60 else { return }
        checkingForUpdate = true
        Task.detached {
            let succeeded = upgradeThroughBrew(prefix)
            await MainActor.run { self.finishUpdateCheck(prefix, succeeded: succeeded) }
        }
    }

    func finishUpdateCheck(_ prefix: String, succeeded: Bool) {
        checkingForUpdate = false
        guard succeeded else { return }
        UserDefaults.standard.set(Date(), forKey: lastUpdateCheckKey)
        let installed = NSDictionary(contentsOfFile: "\(prefix)/opt/wellawake/WellAwake.app/Contents/Info.plist")!
        guard installed["CFBundleVersion"] as! String != Bundle.main.infoDictionary!["CFBundleVersion"] as! String else { return }
        // Under brew services, launchd gives our job's label (e.g. sh.brew.wellawake) in XPC_SERVICE_NAME,
        // and restarting the job starts the new version. Opened any other way, the label is
        // "application.org.innowell.wellawake.<ids>", and the new version waits for the next launch.
        guard !ownsSleepOverride, let label = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"], label.hasSuffix(".wellawake") else { return }
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    // Left click toggles; right click (or control-click) opens the menu. An accessibility press
    // (VoiceOver, System Events) has no event, and counts as a left click.
    @objc func clicked() {
        let event = NSApp.currentEvent
        if let event, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = menu
            statusItem.button!.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    @objc func toggle() {
        setAwake(!sleepDisabled(), minutes: nil)
    }

    @objc func toggleSleepWhenCritical() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: sleepWhenCriticalKey), forKey: sleepWhenCriticalKey)
        refresh()
    }

    @objc func toggleSessionLogging() {
        let wasEnabled = UserDefaults.standard.bool(forKey: sessionLoggingKey)
        if wasEnabled { logSessionEvent("logging_disabled") }
        UserDefaults.standard.set(!wasEnabled, forKey: sessionLoggingKey)
        refresh()
    }

    @objc func showSessionLogs() {
        do {
            try SessionLog.prepareDirectory(SessionLog.directory)
            NSWorkspace.shared.open(SessionLog.directory)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // Alerts only go out while sleep is disabled: that's when the Mac might be shut in a bag.
    func checkHeat() {
        refresh()
        let state = ProcessInfo.processInfo.thermalState
        if state.rawValue < ProcessInfo.ThermalState.serious.rawValue {
            if alertedState != .nominal {
                alertedState = .nominal
                Task { await notifyPhone(title: "Your Mac has cooled down", message: "Heat is back to \(state.label.lowercased()).", priority: 3, tag: "white_check_mark") }
            }
            return
        }
        guard state.rawValue > alertedState.rawValue, sleepDisabled() else { return }
        alertedState = state

        guard state == .critical else {
            Task { await notifyPhone(title: "Your Mac is running hot", message: "macOS is slowing it down to cool off. If it's in a bag, give it some air.", priority: 4, tag: "thermometer") }
            return
        }
        guard UserDefaults.standard.bool(forKey: sleepWhenCriticalKey) else {
            Task { await notifyPhone(title: "Your Mac is critically hot", message: "Sleep is still disabled. macOS will shut it down if it gets any hotter.", priority: 5, tag: "fire") }
            return
        }
        Task {
            // Alert first: once sleep is back on, a closed Mac goes to sleep and drops off the network.
            await notifyPhone(title: "Your Mac is critically hot", message: "WellAwake turned sleep back on so it can cool down. If the lid is closed it will go to sleep.", priority: 5, tag: "fire")
            logSessionEvent("critical_heat_sleep_requested")
            switch restoreSleepForHeat(recovery: { recovery?.set(false) == true }, emergency: { guard trySetSleepDisabled(false) else { return false }; sleepNowIfLidClosed(); return true }) {
            case .recovered:
                ownsSleepOverride = false
            case .emergency:
                break
            case .failed:
                logSessionEvent("critical_heat_sleep_failed")
                await notifyPhone(title: "WellAwake couldn't turn sleep back on", message: "The sleep command failed. Your Mac is still awake and critically hot.", priority: 5, tag: "warning")
            }
            refresh()
        }
    }

    @objc func removeRule() {
        if recovery == nil { startRecovery() }
        guard recovery != nil else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Sleep recovery is unavailable"
            alert.informativeText = "The sudo rule is needed until sleep recovery succeeds. Quit and reopen WellAwake, then try again."
            alert.runModal()
            return
        }
        if ownsSleepOverride {
            logSessionEvent("sudo_rule_removal_sleep_requested")
            guard recovery?.set(false) == true else {
                logSessionEvent("sudo_rule_removal_sleep_failed")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "WellAwake couldn't turn sleep back on"
                alert.informativeText = "The sudo rule was kept, because it is needed to restore sleep."
                alert.runModal()
                return
            }
            ownsSleepOverride = false
        }
        // Undo Low Power Mode while the rule still allows it.
        updateLowPowerMode(awake: false)
        runAsAdmin("/bin/rm -f \(sudoersPath) \(legacySudoersPath)", prompt: "WellAwake wants to remove its sudo rule. The next toggle will ask for your password again.")
        refresh()
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: aboutCredits()])
    }

    func logSessionEvent(_ event: String, awake: Bool? = nil) {
        sessionLog.update(enabled: UserDefaults.standard.bool(forKey: sessionLoggingKey),
                          awake: awake ?? sleepDisabled(), lidClosed: lidIsClosed(),
                          thermalPressure: ProcessInfo.processInfo.thermalState.label,
                          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                          event: event, readings: batteryReadings)
    }

    func refresh() {
        let awake = sleepDisabled()
        // Sleep came back some other way (the heat fallback, or pmset in a terminal), so the
        // session is over and updates no longer need to wait for it.
        if !awake {
            ownsSleepOverride = false
            scheduleSessionEnd(minutes: nil)
        }
        for item in timedItem.submenu!.items { item.state = item.tag == sessionLength ? .on : .off }
        timeLeftItem.isHidden = awakeUntil == nil
        if let awakeUntil { timeLeftItem.title = sessionTimeLeft(until: awakeUntil, now: Date()) }
        let image = NSImage(
            systemSymbolName: awake ? "sun.max.fill" : "moon.zzz",
            accessibilityDescription: awake ? "Lid sleep disabled" : "Lid sleep enabled"
        )!
        image.isTemplate = true
        let button = statusItem.button!
        button.image = image
        button.toolTip = awake
            ? "Staying awake with the lid closed. Click to allow sleep."
            : "Sleeping normally. Click to stay awake with the lid closed."
        updateLowPowerMode(awake: awake)
        keepingAwake = awake
        let lidClosed = lidIsClosed()
        if !lidClosed { _ = builtInScreenSize() }
        updateScreens(awake: awake, lidClosed: lidClosed)
        let logging = UserDefaults.standard.bool(forKey: sessionLoggingKey)
        sessionLoggingItem.state = logging ? .on : .off
        logSessionEvent("sample", awake: awake)
        toggleItem.state = awake ? .on : .off
        lowPowerItem.state = UserDefaults.standard.bool(forKey: lowPowerWhenLidClosedKey) ? .on : .off
        virtualScreenItem.state = UserDefaults.standard.bool(forKey: virtualScreenKey) ? .on : .off
        heatItem.title = "Heat: \(ProcessInfo.processInfo.thermalState.label)"
        sleepWhenCriticalItem.state = UserDefaults.standard.bool(forKey: sleepWhenCriticalKey) ? .on : .off
        removeRuleItem.isHidden = ![sudoersPath, legacySudoersPath].contains { FileManager.default.fileExists(atPath: $0) }
    }
}

if CommandLine.arguments.dropFirst() == ["--sleep-recovery-worker"] { exit(runRecoveryWorker(command: recoveryCommandThenSleep)) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

import AppKit
import IOKit.ps
import notify

// pmset needs root. On first toggle we install this rule (one admin prompt) so later
// toggles can run `sudo -n pmset ...` without asking. It allows exactly two commands.
let sudoersPath = "/etc/sudoers.d/lidawake"

// Heat alerts are posted here. A random ntfy.sh topic is generated on first launch; point it at
// your own server with `defaults write org.innowell.lidawake NtfyURL <url>`.
let ntfyURLKey = "NtfyURL"
let sleepWhenCriticalKey = "SleepWhenCritical"

// LidAwake keeps itself up to date through brew. Brew installs it at
// <prefix>/Cellar/lidawake/<version>/LidAwake.app; a local build lives elsewhere and never updates.
let brewPrefix: String? = {
    let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    return path.range(of: "/Cellar/lidawake/").map { String(path[..<$0.lowerBound]) }
}()
let lastUpdateCheckKey = "LastUpdateCheck"

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

// `pmset -g` prints " SleepDisabled\t\t1" under "System-wide power settings", but only once
// disablesleep has been set on this Mac. A Mac that has never been toggled has no such line, and
// its sleep isn't disabled.
func sleepDisabled() -> Bool {
    let fields = run("/usr/bin/pmset", ["-g"]).output
        .split(separator: "\n")
        .map { $0.split(whereSeparator: \.isWhitespace) }
        .first { $0.first == "SleepDisabled" }
    return fields?.last == "1"
}

@discardableResult
func runAsAdmin(_ command: String, prompt: String) -> Bool {
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let source = "do shell script \(quoted(command)) with prompt \(quoted(prompt)) with administrator privileges"
    var error: NSDictionary?
    NSAppleScript(source: source)!.executeAndReturnError(&error)
    guard let error else { return true }
    guard error[NSAppleScript.errorNumber] as? Int != -128 else { return false } // -128: user cancelled
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "LidAwake couldn't change the sleep setting"
    alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
    alert.runModal()
    return false
}

// Toggles through the sudo rule. Returns false, without prompting, if the rule isn't installed.
func trySetSleepDisabled(_ disabled: Bool) -> Bool {
    run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
}

func ensureSleepPermission() -> Bool {
    if run("/usr/bin/sudo", ["-k", "-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0,
       run("/usr/bin/sudo", ["-k", "-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).status == 0 { return true }
    let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    let tmp = sudoersPath + ".tmp"
    let command = [
        "printf '%s\\n' '\(rule)' > \(tmp)",
        "/bin/chmod 0440 \(tmp)",
        "/usr/sbin/visudo -cf \(tmp)",
        "/bin/mv \(tmp) \(sudoersPath)",
    ].joined(separator: " && ") + "; s=$?; /bin/rm -f \(tmp); exit $s"
    return runAsAdmin(command, prompt: "LidAwake needs to install a sudo rule so it can switch lid sleep on and off without asking for your password each time.")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let toggleItem = NSMenuItem(title: "Stay Awake With Lid Closed", action: #selector(toggle), keyEquivalent: "")
    let heatItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let sleepWhenCriticalItem = NSMenuItem(title: "Let Mac Sleep If Critically Hot", action: #selector(toggleSleepWhenCritical), keyEquivalent: "")
    let removeRuleItem = NSMenuItem(title: "Remove sudo Rule…", action: #selector(removeRule), keyEquivalent: "")
    // Highest heat level we've alerted about since the Mac was last back below "Hot".
    var alertedState = ProcessInfo.ThermalState.nominal
    var checkingForUpdate = false
    var recovery: SleepRecovery?
    var ownsSleepOverride = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        startRecovery()
        UserDefaults.standard.register(defaults: [sleepWhenCriticalKey: true])
        if UserDefaults.standard.string(forKey: ntfyURLKey) == nil {
            let topic = "lidawake-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
            UserDefaults.standard.set("https://ntfy.sh/\(topic)", forKey: ntfyURLKey)
        }

        toggleItem.target = self
        sleepWhenCriticalItem.target = self
        removeRuleItem.target = self
        let phoneAlertsItem = NSMenuItem(title: "Phone Alerts…", action: #selector(showPhoneAlerts), keyEquivalent: "")
        phoneAlertsItem.target = self
        let aboutItem = NSMenuItem(title: "About LidAwake", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(heatItem)
        menu.addItem(sleepWhenCriticalItem)
        menu.addItem(phoneAlertsItem)
        menu.addItem(.separator())
        menu.addItem(removeRuleItem)
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem(title: "Quit LidAwake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        // Pick up changes made outside the app, e.g. pmset run in a terminal.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkHeat() }
        }
        // A minute after launch, so the network is up after a login, then hourly.
        RunLoop.main.add(Timer(fire: Date().addingTimeInterval(60), interval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkForUpdate() }
        }, forMode: .common)
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
        let installed = NSDictionary(contentsOfFile: "\(prefix)/opt/lidawake/LidAwake.app/Contents/Info.plist")!
        guard installed["CFBundleVersion"] as! String != Bundle.main.infoDictionary!["CFBundleVersion"] as! String else { return }
        // Under brew services, launchd gives our job's label (e.g. sh.brew.lidawake) in XPC_SERVICE_NAME,
        // and restarting the job starts the new version. Opened any other way, the label is
        // "application.org.innowell.lidawake.<ids>", and the new version waits for the next launch.
        guard !ownsSleepOverride, let label = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"], label.hasSuffix(".lidawake") else { return }
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    // Left click toggles; right click (or control-click) opens the menu.
    @objc func clicked() {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
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
        let awake = !sleepDisabled()
        guard ensureSleepPermission() else { return }
        if recovery == nil { startRecovery() }
        guard let recovery, recovery.set(awake) else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "LidAwake couldn't change the sleep setting"
            alert.informativeText = "Sleep recovery is unavailable. Quit LidAwake and try again."
            alert.runModal()
            return
        }
        ownsSleepOverride = awake
        refresh()
    }

    @objc func toggleSleepWhenCritical() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: sleepWhenCriticalKey), forKey: sleepWhenCriticalKey)
        refresh()
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
            await notifyPhone(title: "Your Mac is critically hot", message: "LidAwake turned sleep back on so it can cool down. If the lid is closed it will go to sleep.", priority: 5, tag: "fire")
            if !(recovery?.set(false) ?? trySetSleepDisabled(false)) {
                await notifyPhone(title: "LidAwake couldn't turn sleep back on", message: "The sudo rule isn't installed. Your Mac is still awake and critically hot.", priority: 5, tag: "warning")
            } else {
                ownsSleepOverride = false
            }
            refresh()
        }
    }

    // Like heat alerts, battery warnings only go out while sleep is disabled.
    func warnLowBattery() {
        guard let warning = batteryWarning(IOPSGetBatteryWarningLevel()), sleepDisabled() else { return }
        let title = batteryMinutesLeft().map { "Your Mac has about \($0) minutes of battery left" } ?? "Your Mac's battery is low"
        Task { await notifyPhone(title: title, message: "It's at \(batteryPercent())%. \(warning.message)", priority: warning.priority, tag: "battery") }
    }

    // Nobody is at the Mac to see an error for a background alert, so failures are only logged.
    func notifyPhone(title: String, message: String, priority: Int, tag: String) async {
        do {
            try await sendPhoneAlert(title: title, message: message, priority: priority, tag: tag)
        } catch {
            NSLog("LidAwake: phone alert failed: \(error)")
        }
    }

    @objc func showPhoneAlerts() {
        let url = URL(string: UserDefaults.standard.string(forKey: ntfyURLKey)!)!
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Phone alerts"
        alert.informativeText = """
            Install the ntfy app, tap +, and subscribe to this topic:

            \(url.lastPathComponent)

            Server: \(url.host!)

            While LidAwake is keeping your Mac awake, it alerts you when the Mac runs hot or its battery runs low.
            """
        alert.addButton(withTitle: "Copy Topic")
        alert.addButton(withTitle: "Send Test Alert")
        alert.addButton(withTitle: "Done")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.lastPathComponent, forType: .string)
        case .alertSecondButtonReturn:
            Task {
                do {
                    try await sendPhoneAlert(title: "LidAwake test", message: "Phone alerts are working.", priority: 3, tag: "white_check_mark")
                } catch {
                    NSApp.activate(ignoringOtherApps: true)
                    let failed = NSAlert()
                    failed.messageText = "Couldn't send the test alert"
                    failed.informativeText = "\(error)"
                    failed.runModal()
                }
            }
        default:
            break
        }
    }

    @objc func removeRule() {
        if recovery == nil { startRecovery() }
        guard recovery != nil else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Sleep recovery is unavailable"
            alert.informativeText = "The sudo rule is needed until sleep recovery succeeds. Quit and reopen LidAwake, then try again."
            alert.runModal()
            return
        }
        if ownsSleepOverride {
            guard recovery?.set(false) == true else { return }
            ownsSleepOverride = false
        }
        runAsAdmin("/bin/rm -f \(sudoersPath)", prompt: "LidAwake wants to remove its sudo rule. The next toggle will ask for your password again.")
        refresh()
    }

    @objc func showAbout() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let credits = NSAttributedString(string: "Made with love at Innowell", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func refresh() {
        let awake = sleepDisabled()
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
        toggleItem.state = awake ? .on : .off
        heatItem.title = "Heat: \(ProcessInfo.processInfo.thermalState.label)"
        sleepWhenCriticalItem.state = UserDefaults.standard.bool(forKey: sleepWhenCriticalKey) ? .on : .off
        removeRuleItem.isHidden = !FileManager.default.fileExists(atPath: sudoersPath)
    }
}

if CommandLine.arguments.dropFirst() == ["--sleep-recovery-worker"] { exit(runRecoveryWorker()) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

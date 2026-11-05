import AppKit
import IOKit.ps

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

func runAsAdmin(_ command: String, prompt: String) {
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let source = "do shell script \(quoted(command)) with prompt \(quoted(prompt)) with administrator privileges"
    var error: NSDictionary?
    NSAppleScript(source: source)!.executeAndReturnError(&error)
    guard let error, error[NSAppleScript.errorNumber] as? Int != -128 else { return } // -128: user cancelled
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "LidAwake couldn't change the sleep setting"
    alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
    alert.runModal()
}

// Toggles through the sudo rule. Returns false, without prompting, if the rule isn't installed.
func trySetSleepDisabled(_ disabled: Bool) -> Bool {
    run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
}

func setSleepDisabled(_ disabled: Bool) {
    if trySetSleepDisabled(disabled) { return }

    // No rule yet. Write it as root straight into /etc/sudoers.d (sudo skips names containing
    // a dot, so the .tmp file is inert), validate it, move it into place, then toggle.
    let value = disabled ? "1" : "0"
    let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    let tmp = sudoersPath + ".tmp"
    let command = [
        "printf '%s\\n' '\(rule)' > \(tmp)",
        "/bin/chmod 0440 \(tmp)",
        "/usr/sbin/visudo -cf \(tmp)",
        "/bin/mv \(tmp) \(sudoersPath)",
        "/usr/bin/pmset -a disablesleep \(value)",
    ].joined(separator: " && ") + "; s=$?; /bin/rm -f \(tmp); exit $s"
    runAsAdmin(command, prompt: "LidAwake needs to install a sudo rule so it can switch lid sleep on and off without asking for your password each time.")
}

struct PhoneAlertError: Error, CustomStringConvertible {
    let description: String
}

// Priority and tags are ntfy's: 3 default, 4 high, 5 urgent; tags are emoji shortcodes.
func sendPhoneAlert(title: String, message: String, priority: Int, tag: String) async throws {
    var request = URLRequest(url: URL(string: UserDefaults.standard.string(forKey: ntfyURLKey)!)!, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = Data(message.utf8)
    request.setValue(title, forHTTPHeaderField: "Title")
    request.setValue(String(priority), forHTTPHeaderField: "Priority")
    request.setValue(tag, forHTTPHeaderField: "Tags")
    let (_, response) = try await URLSession.shared.data(for: request)
    let status = (response as! HTTPURLResponse).statusCode
    guard status == 200 else { throw PhoneAlertError(description: "ntfy returned HTTP \(status)") }
}

// Runs `brew update`, then upgrades LidAwake if there's a new version. False if brew failed.
func upgradeThroughBrew(_ prefix: String) -> Bool {
    let brew = "\(prefix)/bin/brew"
    for args in [[brew, "update", "--quiet"], ["HOMEBREW_NO_AUTO_UPDATE=1", brew, "upgrade", "innowellteam/lidawake/lidawake"]] {
        let result = run("/usr/bin/env", args)
        guard result.status == 0 else {
            NSLog("LidAwake: \(args.joined(separator: " ")) failed: \(result.output)")
            return false
        }
    }
    return true
}

// The battery's charge in percent while the Mac is running on it; nil on power, or with no battery.
func batteryPercentOnBattery() -> Int? {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    let battery = sources
        .map { IOPSGetPowerSourceDescription(info, $0).takeUnretainedValue() as! [String: Any] }
        .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    guard let battery, battery[kIOPSPowerSourceStateKey] as! String == kIOPSBatteryPowerValue else { return nil }
    return (battery[kIOPSCurrentCapacityKey] as! Int) * 100 / (battery[kIOPSMaxCapacityKey] as! Int)
}

// Sent as the battery runs down past each level: level, ntfy priority, message.
let batteryWarnings: [(level: Int, priority: Int, message: String)] = [
    (25, 3, "It's on battery and LidAwake is keeping it awake. Plug it in when you can."),
    (10, 4, "Plug it in soon."),
    (5, 5, "Plug it in now. It's nearly flat."),
    (2, 5, "It's about to run out, and anything running on it will stop."),
]

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
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
    // Lowest battery level we've warned about since the Mac was last on power.
    var warnedBatteryLevel = Int.max
    var checkingForUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        checkHeat()
        checkBattery()
        // Pick up changes made outside the app, e.g. pmset run in a terminal, and the battery level.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.checkHeat()
                self.checkBattery()
            }
        }
        // A minute after launch, so the network is up after a login, then hourly.
        RunLoop.main.add(Timer(fire: Date().addingTimeInterval(60), interval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkForUpdate() }
        }, forMode: .common)
    }

    // At most once a day. A failed check (say, while offline) is retried on the next hourly tick.
    func checkForUpdate() {
        let lastCheck = UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date ?? .distantPast
        guard let prefix = brewPrefix, !checkingForUpdate, Date().timeIntervalSince(lastCheck) > 24 * 60 * 60 else { return }
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
        guard let label = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"], label.hasSuffix(".lidawake") else { return }
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
        setSleepDisabled(!sleepDisabled())
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
            if !trySetSleepDisabled(false) {
                await notifyPhone(title: "LidAwake couldn't turn sleep back on", message: "The sudo rule isn't installed. Your Mac is still awake and critically hot.", priority: 5, tag: "warning")
            }
            refresh()
        }
    }

    // Like heat alerts, battery warnings only go out while sleep is disabled.
    func checkBattery() {
        guard let percent = batteryPercentOnBattery() else {
            warnedBatteryLevel = .max
            return
        }
        guard let warning = batteryWarnings.last(where: { percent <= $0.level }),
              warning.level < warnedBatteryLevel, sleepDisabled() else { return }
        warnedBatteryLevel = warning.level
        Task { await notifyPhone(title: "Your Mac's battery is at \(percent)%", message: warning.message, priority: warning.priority, tag: "battery") }
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

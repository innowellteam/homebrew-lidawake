import AppKit

// pmset needs root. On first toggle we install this rule (one admin prompt) so later
// toggles can run `sudo -n pmset ...` without asking. It allows exactly two commands.
let sudoersPath = "/etc/sudoers.d/lidawake"

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

// `pmset -g` prints " SleepDisabled\t\t1" under "System-wide power settings".
func sleepDisabled() -> Bool {
    let fields = run("/usr/bin/pmset", ["-g"]).output
        .split(separator: "\n")
        .map { $0.split(whereSeparator: \.isWhitespace) }
        .first { $0.first == "SleepDisabled" }!
    return fields.last == "1"
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

func setSleepDisabled(_ disabled: Bool) {
    let value = disabled ? "1" : "0"
    if run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]).status == 0 { return }

    // No rule yet. Write it as root straight into /etc/sudoers.d (sudo skips names containing
    // a dot, so the .tmp file is inert), validate it, move it into place, then toggle.
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let toggleItem = NSMenuItem(title: "Stay Awake With Lid Closed", action: #selector(toggle), keyEquivalent: "")
    let removeRuleItem = NSMenuItem(title: "Remove sudo Rule…", action: #selector(removeRule), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        toggleItem.target = self
        removeRuleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(removeRuleItem)
        let aboutItem = NSMenuItem(title: "About LidAwake", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem(title: "Quit LidAwake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self

        let button = statusItem.button!
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        refresh()
        // Pick up changes made outside the app, e.g. pmset run in a terminal.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
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

import AppKit

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

// Turning sleep back on doesn't put an already-closed Mac to sleep: macOS only reacts to the lid
// closing, and idle sleep is blocked by anything holding a sleep assertion (caffeinate, say).
// An external display means clamshell use, so that case is left alone.
func sleepNowIfLidClosed() {
    guard lidIsClosed(), !(onlineDisplayStates() ?? []).contains(where: { !$0.builtIn }) else { return }
    _ = run("/usr/bin/pmset", ["sleepnow"])
}

// The worker's command: after restoring sleep, make sure a closed Mac actually sleeps.
func recoveryCommandThenSleep(_ awake: Bool) -> Bool {
    guard recoveryCommand(awake) else { return false }
    if !awake { sleepNowIfLidClosed() }
    return true
}

func ensureSleepPermission() -> Bool {
    // Writing the current value back changes nothing and proves the rule works. `sudo -n -l` can't
    // be used: for an admin with any other NOPASSWD rule it succeeds for every command.
    if trySetSleepDisabled(sleepDisabled()) { return true }
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

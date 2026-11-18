import AppKit
import IOKit.ps

extension AppDelegate {
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
            NSLog("WellAwake: phone alert failed: \(error)")
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

            While WellAwake is keeping your Mac awake, it alerts you when the Mac runs hot or its battery runs low.
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
                    try await sendPhoneAlert(title: "WellAwake test", message: "Phone alerts are working.", priority: 3, tag: "white_check_mark")
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
}

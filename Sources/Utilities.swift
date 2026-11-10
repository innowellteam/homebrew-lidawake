import AppKit
import IOKit.ps

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

// The internal battery's charge in percent.
func batteryPercent() -> Int {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    let battery = sources
        .map { IOPSGetPowerSourceDescription(info, $0).takeUnretainedValue() as! [String: Any] }
        .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }!
    return (battery[kIOPSCurrentCapacityKey] as! Int) * 100 / (battery[kIOPSMaxCapacityKey] as! Int)
}

// Minutes of battery left by macOS's estimate; nil while it's still working that out, or on power.
func batteryMinutesLeft() -> Int? {
    let seconds = IOPSGetTimeRemainingEstimate()
    return seconds > 0 ? Int(seconds / 60) : nil
}

// ntfy priority and message for each of macOS's own low battery warnings. powerd sets Early at 10%
// and Final at 2% (kSocThresholdEarly and kSocThresholdFinal in its BatteryTimeRemaining.m); IOKit's
// header still describes them as 20 and 10 minutes left, which is out of date.
func batteryWarning(_ level: IOPSLowBatteryWarningLevel) -> (priority: Int, message: String)? {
    switch level {
    case kIOPSLowBatteryWarningEarly: (4, "Plug it in soon.")
    case kIOPSLowBatteryWarningFinal: (5, "Plug it in now, or anything running on it will stop.")
    default: nil
    }
}

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


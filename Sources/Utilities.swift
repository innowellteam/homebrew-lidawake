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

// Runs `brew update`, then upgrades WellAwake if there's a new version. False if brew failed.
func upgradeThroughBrew(_ prefix: String) -> Bool {
    let brew = "\(prefix)/bin/brew"
    // Trusting our own tap lets `brew update` follow the GitHub repo if it's renamed. Otherwise brew refuses
    // that redirect for a tap you've trusted formulae from (installing WellAwake trusts it), and the tap
    // stops updating. Brew before 7 has no `trust`, and needs none.
    if let tap = brewTap(prefix, containing: "wellawake") {
        let trust = run("/usr/bin/env", ["HOMEBREW_NO_AUTO_UPDATE=1", brew, "trust", "--tap", tap])
        if trust.status != 0 { NSLog("WellAwake: brew trust --tap \(tap) failed: \(trust.output)") }
    }
    let update = run("/usr/bin/env", [brew, "update", "--quiet"])
    guard update.status == 0 else {
        NSLog("WellAwake: brew update failed: \(update.output)")
        return false
    }
    // Looked up after updating: when the GitHub repo is renamed, `brew update` renames its copy of the tap.
    // Named in full, because brew only loads a formula from a tap you haven't trusted when the command names it.
    guard let tap = brewTap(prefix, containing: "wellawake") else {
        NSLog("WellAwake: no brew tap has the wellawake formula")
        return false
    }
    let upgrade = run("/usr/bin/env", ["HOMEBREW_NO_AUTO_UPDATE=1", brew, "upgrade", "\(tap)/wellawake"])
    guard upgrade.status == 0 else {
        NSLog("WellAwake: brew upgrade \(tap)/wellawake failed: \(upgrade.output)")
        return false
    }
    return true
}

// The tap ("user/repo") whose Formula folder has this formula, e.g. "innowellteam/wellawake". Taps live
// in the Homebrew repository: the prefix itself on Apple Silicon, <prefix>/Homebrew on Intel.
func brewTap(_ prefix: String, containing formula: String) -> String? {
    let files = FileManager.default
    for taps in ["\(prefix)/Library/Taps", "\(prefix)/Homebrew/Library/Taps"] {
        for user in (try? files.contentsOfDirectory(atPath: taps)) ?? [] {
            for repo in (try? files.contentsOfDirectory(atPath: "\(taps)/\(user)")) ?? [] where repo.hasPrefix("homebrew-") {
                if files.fileExists(atPath: "\(taps)/\(user)/\(repo)/Formula/\(formula).rb") {
                    return "\(user)/\(repo.dropFirst("homebrew-".count))"
                }
            }
        }
    }
    return nil
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

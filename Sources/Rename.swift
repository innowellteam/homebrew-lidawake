import Foundation

// WellAwake was called LidAwake before 2.0.0. These are the names that version used.
let legacyBundleID = "org.innowell.lidawake"
let legacySudoersPath = "/etc/sudoers.d/lidawake"

// On WellAwake's first launch, brings over LidAwake's settings (the phone alert topic among them),
// its sleep recovery state and its session logs. LidAwake's sudo rule keeps working where it is, and
// the next rule WellAwake installs replaces it.
func adoptLidAwakeSettings() {
    let defaults = UserDefaults.standard
    let bundleID = Bundle.main.bundleIdentifier!
    if defaults.persistentDomain(forName: bundleID) == nil, let old = defaults.persistentDomain(forName: legacyBundleID) {
        defaults.setPersistentDomain(old, forName: bundleID)
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    for (old, new) in [(legacyBundleID, bundleID), ("LidAwake", "WellAwake")] {
        let from = support.appendingPathComponent(old), to = support.appendingPathComponent(new)
        if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
            try! FileManager.default.moveItem(at: from, to: to)
        }
    }
}

// LidAwake's last update installs a stand-in (see Bridge/) that installs WellAwake and starts it at
// login. Once WellAwake is running, this stops the stand-in and uninstalls it. The tap stays: WellAwake
// comes from it too. Runs on every launch from brew, and does nothing once LidAwake is gone.
func removeLidAwake(brewPrefix prefix: String) {
    guard FileManager.default.fileExists(atPath: "\(prefix)/Cellar/lidawake") else { return }
    for args in [["services", "stop", "lidawake"], ["uninstall", "lidawake"]] {
        let result = run("/usr/bin/env", ["HOMEBREW_NO_AUTO_UPDATE=1", "\(prefix)/bin/brew"] + args)
        guard result.status == 0 else {
            NSLog("WellAwake: brew \(args.joined(separator: " ")) failed: \(result.output)")
            // Stopping fails if the stand-in's service was never started. Uninstalling still clears it.
            if args[0] == "services" { continue }
            return
        }
    }
}

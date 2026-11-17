import AppKit

extension AppDelegate {
    @objc func toggleVirtualScreen() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: virtualScreenKey), forKey: virtualScreenKey)
        refresh()
    }

    // Runs on every refresh, so `defaults write org.innowell.wellawake VirtualScreen -bool true` (or false)
    // from a script takes effect within the 15-second check.
    func updateVirtualScreen(awake: Bool) {
        let enabled = UserDefaults.standard.bool(forKey: virtualScreenKey)
        virtualScreen.update(enabled: enabled, keepingAwake: awake)
        guard enabled, !virtualScreen.isConnected else { return }
        // The private API failed, most likely changed by a macOS update. Untick it rather than retry every refresh.
        UserDefaults.standard.set(false, forKey: virtualScreenKey)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "WellAwake couldn't add the virtual screen"
        alert.informativeText = "macOS refused to create it. It uses an unpublished part of macOS, which a macOS update may have changed."
        alert.runModal()
    }
}

import AppKit

extension AppDelegate {
    @objc func stayAwakeFor(_ sender: NSMenuItem) {
        setAwake(true, minutes: sender.tag)
    }

    func setAwake(_ awake: Bool, minutes: Int?) {
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
        scheduleSessionEnd(minutes: minutes)
        refresh()
    }

    func scheduleSessionEnd(minutes: Int?) {
        sessionTimer?.invalidate()
        sessionTimer = nil
        sessionLength = minutes
        awakeUntil = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        guard let deadline = awakeUntil else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { self.endSessionIfOver() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionTimer = timer
    }

    // Also called from the 15 second tick, in case the one-shot timer fires late.
    func endSessionIfOver() {
        guard sessionIsOver(deadline: awakeUntil, now: Date()) else { return }
        scheduleSessionEnd(minutes: nil)
        Task {
            // Alert first: once sleep is back on, a closed Mac goes to sleep and drops off the network.
            await notifyPhone(title: "LidAwake's timer finished", message: "Sleep is back on. If the lid is closed your Mac is going to sleep.", priority: 3, tag: "zzz")
            switch restoreSleepForHeat(recovery: { recovery?.set(false) == true }, emergency: { guard trySetSleepDisabled(false) else { return false }; sleepNowIfLidClosed(); return true }) {
            case .recovered:
                ownsSleepOverride = false
            case .emergency:
                break
            case .failed:
                await notifyPhone(title: "LidAwake couldn't turn sleep back on", message: "The timer finished but the sleep command failed. Your Mac is still awake.", priority: 5, tag: "warning")
            }
            refresh()
        }
    }
}

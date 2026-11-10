import CoreGraphics
import Foundation
import IOKit

struct DisplayState {
    let builtIn: Bool
    let asleep: Bool
}

func shouldSleepDisplays(lidClosed: Bool, displays: [DisplayState]) -> Bool {
    guard lidClosed, !displays.contains(where: { !$0.builtIn }) else { return false }
    return displays.contains { $0.builtIn && !$0.asleep }
}

func sleepDisplayIfNeeded(lidClosed: Bool, displays: [DisplayState], isKeepingAwake: () -> Bool, sleepDisplays: () -> Void) {
    guard shouldSleepDisplays(lidClosed: lidClosed, displays: displays), isKeepingAwake() else { return }
    sleepDisplays()
}

func lidIsClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool == true
}

func onlineDisplayStates() -> [DisplayState]? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
    return ids.prefix(Int(count)).map { DisplayState(builtIn: CGDisplayIsBuiltin($0) != 0, asleep: CGDisplayIsAsleep($0) != 0) }
}

final class DisplaySleepMonitor {
    private let timer: DispatchSourceTimer

    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.innowell.lidawake.display"))
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler {
            guard lidIsClosed(), let displays = onlineDisplayStates() else { return }
            sleepDisplayIfNeeded(lidClosed: true, displays: displays, isKeepingAwake: sleepDisabled) {
                let result = run("/usr/bin/pmset", ["displaysleepnow"])
                if result.status != 0 { NSLog("LidAwake: display sleep failed: \(result.output)") }
            }
        }
        timer.resume()
    }

    deinit { timer.cancel() }
}

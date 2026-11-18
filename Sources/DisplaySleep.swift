import CoreGraphics
import Foundation
import IOKit

// The made-up vendor number on WellAwake's virtual screens (VirtualScreen.swift), so they can be told
// apart from real monitors and other apps' virtual screens.
let wellAwakeDisplayVendor: UInt32 = 0x5741
// Their serial numbers: the menu's virtual screen, and the stand-in for a closed lid.
let virtualScreenSerial: UInt32 = 1
let lidScreenSerial: UInt32 = 2

struct DisplayState {
    let builtIn: Bool
    let asleep: Bool
    var wellAwake = false
    var id: CGDirectDisplayID = 0
}

// What WellAwake puts on screen.
struct ScreenPlan: Equatable {
    // The 1920x1080 virtual screen ticked in the menu.
    var virtualScreen: Bool
    // While the Mac is kept awake with the lid closed and no other monitor on: a virtual screen the
    // size of the built-in one, for the built-in screen's windows to move to. Not needed when the
    // menu's virtual screen is there.
    var lidScreen: Bool
    // While the Mac is kept awake with the lid closed and one of WellAwake's screens is there: switch
    // the built-in screen off. macOS then moves its windows onto WellAwake's screen, where they keep
    // drawing. macOS does this by itself only for a monitor that was already there when the lid closed.
    var builtInOff: Bool
    // While keeping the Mac awake with a virtual screen: idle display sleep would lock the Mac, and
    // windows stop drawing behind the lock screen.
    var holdDisplayAwake: Bool
}

func screenPlan(virtualScreenTicked: Bool, keepingAwake: Bool, lidClosed: Bool, otherMonitor: Bool) -> ScreenPlan {
    let lidScreen = keepingAwake && lidClosed && !virtualScreenTicked && !otherMonitor
    return ScreenPlan(virtualScreen: virtualScreenTicked, lidScreen: lidScreen,
                      builtInOff: keepingAwake && lidClosed && (virtualScreenTicked || lidScreen),
                      holdDisplayAwake: keepingAwake && (virtualScreenTicked || lidScreen))
}

// The fallback for when no virtual screen could be made: with the lid closed and only the built-in
// screen left, put it to sleep. That locks the Mac.
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
    return ids.prefix(Int(count)).map {
        DisplayState(builtIn: CGDisplayIsBuiltin($0) != 0, asleep: CGDisplayIsAsleep($0) != 0, wellAwake: CGDisplayVendorNumber($0) == wellAwakeDisplayVendor, id: $0)
    }
}

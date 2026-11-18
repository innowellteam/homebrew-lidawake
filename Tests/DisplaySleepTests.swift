import Foundation

func sleepDisabled() -> Bool { false }
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) { (0, "") }

@main
struct DisplaySleepTests {
    static func main() {
        let internalOn = DisplayState(builtIn: true, asleep: false)
        let internalOff = DisplayState(builtIn: true, asleep: true)
        let externalOn = DisplayState(builtIn: false, asleep: false)
        precondition(shouldSleepDisplays(lidClosed: true, displays: [internalOn]))
        precondition(!shouldSleepDisplays(lidClosed: false, displays: [internalOn]))
        precondition(!shouldSleepDisplays(lidClosed: true, displays: [internalOff]))
        precondition(!shouldSleepDisplays(lidClosed: true, displays: [internalOn, externalOn]))
        precondition(!shouldSleepDisplays(lidClosed: true, displays: [externalOn]))
        precondition(!shouldSleepDisplays(lidClosed: true, displays: []))
        var calls = 0
        let blank = { calls += 1 }
        sleepDisplayIfNeeded(lidClosed: true, displays: [internalOn], isKeepingAwake: { false }, sleepDisplays: blank)
        precondition(calls == 0)
        sleepDisplayIfNeeded(lidClosed: true, displays: [internalOn], isKeepingAwake: { true }, sleepDisplays: blank)
        precondition(calls == 1)
        sleepDisplayIfNeeded(lidClosed: true, displays: [internalOn, externalOn], isKeepingAwake: { true }, sleepDisplays: blank)
        sleepDisplayIfNeeded(lidClosed: false, displays: [internalOn], isKeepingAwake: { true }, sleepDisplays: blank)
        precondition(calls == 1)
        func plan(_ virtual: Bool, _ awake: Bool, _ closed: Bool, other: Bool = false) -> ScreenPlan {
            screenPlan(virtualScreenTicked: virtual, keepingAwake: awake, lidClosed: closed, otherMonitor: other)
        }
        // Lid closed while kept awake: a stand-in screen, the built-in screen off, held awake.
        precondition(plan(false, true, true) == ScreenPlan(virtualScreen: false, lidScreen: true, builtInOff: true, holdDisplayAwake: true))
        // The menu's screen takes the stand-in's place.
        precondition(plan(true, true, true) == ScreenPlan(virtualScreen: true, lidScreen: false, builtInOff: true, holdDisplayAwake: true))
        // A real monitor on: macOS moves the windows there itself, so no stand-in.
        precondition(plan(false, true, true, other: true) == ScreenPlan(virtualScreen: false, lidScreen: false, builtInOff: false, holdDisplayAwake: false))
        precondition(plan(true, true, true, other: true) == ScreenPlan(virtualScreen: true, lidScreen: false, builtInOff: true, holdDisplayAwake: true))
        // Not kept awake: nothing switched off, and display sleep as normal, lid open or closed.
        precondition(plan(false, false, true) == ScreenPlan(virtualScreen: false, lidScreen: false, builtInOff: false, holdDisplayAwake: false))
        precondition(plan(true, false, true) == ScreenPlan(virtualScreen: true, lidScreen: false, builtInOff: false, holdDisplayAwake: false))
        // Lid open: only the menu's screen, held awake while kept awake.
        precondition(plan(false, true, false) == ScreenPlan(virtualScreen: false, lidScreen: false, builtInOff: false, holdDisplayAwake: false))
        precondition(plan(true, true, false) == ScreenPlan(virtualScreen: true, lidScreen: false, builtInOff: false, holdDisplayAwake: true))
        print("Display sleep policy passed")
    }
}

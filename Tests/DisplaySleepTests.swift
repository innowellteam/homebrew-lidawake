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
        print("Display sleep policy passed")
    }
}

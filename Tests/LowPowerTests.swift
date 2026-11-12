@main
struct LowPowerTests {
    static func main() {
        let custom = """
        Battery Power:
         lowpowermode         1
         sleep                1
        AC Power:
         lowpowermode         0
         sleep                1
        UPS Power:
         lowpowermode         0
        """
        precondition(lowPowerSettings(custom) == ["b": true, "c": false])
        precondition(lowPowerSettings("") == [:])

        let off = ["b": false, "c": false]
        precondition(lowPowerPlan(wanted: true, settings: off, owned: []) == LowPowerPlan(turnOn: ["b", "c"], restore: []))
        // Already on for battery ("Only on Battery"): only AC is LidAwake's to change.
        precondition(lowPowerPlan(wanted: true, settings: ["b": true, "c": false], owned: []) == LowPowerPlan(turnOn: ["c"], restore: []))
        // Turned off again by the person while the lid is closed: left off.
        precondition(lowPowerPlan(wanted: true, settings: off, owned: ["b", "c"]) == LowPowerPlan(turnOn: [], restore: []))
        // Lid open, sleep back, option off or quitting: undo only LidAwake's own change.
        precondition(lowPowerPlan(wanted: false, settings: [:], owned: ["c"]) == LowPowerPlan(turnOn: [], restore: ["c"]))
        precondition(lowPowerPlan(wanted: false, settings: [:], owned: []) == LowPowerPlan(turnOn: [], restore: []))
        print("low power tests passed")
    }
}

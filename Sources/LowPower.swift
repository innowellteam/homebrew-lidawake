import Foundation

// Off by default. When ticked, LidAwake turns on Low Power Mode while it keeps a closed Mac awake,
// and puts the setting back when the lid opens, sleep returns, or the option is turned off.
let lowPowerWhenLidClosedKey = "LowPowerWhenLidClosed"
// The pmset sources ("b" battery, "c" AC) that LidAwake switched on. Saved, so after a crash it
// still undoes only its own change and never one the person made.
let lowPowerOwnedKey = "LowPowerModeOwnedSources"

// `pmset -g custom` lists each power source's settings under "Battery Power:" and "AC Power:".
func lowPowerSettings(_ output: String) -> [String: Bool] {
    var source: String?
    var settings: [String: Bool] = [:]
    for line in output.split(separator: "\n") {
        if !line.hasPrefix(" ") { source = line.hasPrefix("Battery Power:") ? "b" : line.hasPrefix("AC Power:") ? "c" : nil }
        let fields = line.split(whereSeparator: \.isWhitespace)
        if let source, fields.count == 2, fields[0] == "lowpowermode" { settings[source] = fields[1] == "1" }
    }
    return settings
}

struct LowPowerPlan: Equatable {
    var turnOn: [String]
    var restore: [String]
}

// Wanted: switch on each source that is off and not already ours. A source the person turns off
// again while the lid is closed stays off. Not wanted: switch off only what LidAwake switched on.
func lowPowerPlan(wanted: Bool, settings: [String: Bool], owned: Set<String>) -> LowPowerPlan {
    guard wanted else { return LowPowerPlan(turnOn: [], restore: owned.sorted()) }
    return LowPowerPlan(turnOn: settings.filter { !$0.value && !owned.contains($0.key) }.keys.sorted(), restore: [])
}

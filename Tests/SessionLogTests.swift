import Foundation

@main
struct SessionLogTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = SessionLog(directory: directory)
        var reads = 0
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func tick(_ enabled: Bool = true, _ awake: Bool = true, _ offset: TimeInterval = 0, _ closed: Bool = true, _ lowPower: Bool = false) {
            logger.update(enabled: enabled, awake: awake, now: now.addingTimeInterval(offset), lidClosed: closed,
                          thermalPressure: "Normal", lowPowerMode: lowPower) {
                reads += 1
                return ("Battery Power", 75, 12000, -1000)
            }
        }
        func files() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        }
        tick(false)
        tick(true, false)
        precondition(reads == 0 && !FileManager.default.fileExists(atPath: directory.path))
        tick()
        tick(true, true, 30)
        precondition(reads == 1)
        tick(true, true, 31, false)
        tick(true, true, 32, false, true)
        tick(true, true, 92, false, true)
        let first = try files()
        precondition(first.count == 1 && reads == 4)
        let lines = try String(contentsOf: first[0], encoding: .utf8).split(separator: "\n")
        precondition(lines.count == 4)
        let decoded = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        precondition(decoded["batteryPercent"] as? Int == 75 && decoded["batteryCurrentMilliamps"] as? Int == -1000)
        precondition(decoded["lowPowerMode"] as? Bool == false && decoded["lidClosed"] as? Bool == true)
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber).intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: first[0].path)[.posixPermissions] as! NSNumber).intValue
        precondition(directoryMode == 0o700 && fileMode == 0o600)
        logger.update(enabled: true, awake: true, now: now.addingTimeInterval(93), lidClosed: false,
                      thermalPressure: "Critical", lowPowerMode: true, event: "critical_heat_sleep_requested") {
            ("Battery Power", 74, 11900, -900)
        }
        logger.update(enabled: true, awake: true, now: now.addingTimeInterval(94), lidClosed: false,
                      thermalPressure: "Critical", lowPowerMode: true, event: "critical_heat_sleep_failed") {
            ("Battery Power", 74, 11900, -900)
        }
        logger.update(enabled: true, awake: true, now: now.addingTimeInterval(95), lidClosed: false,
                      thermalPressure: "Critical", lowPowerMode: true, event: "logging_disabled") {
            ("Battery Power", 74, 11900, -900)
        }
        let finalLines = try String(contentsOf: first[0], encoding: .utf8).split(separator: "\n")
        precondition(finalLines.count == 7)
        let eventLines = try finalLines.suffix(3).map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        precondition(eventLines.compactMap { $0["event"] as? String } == ["critical_heat_sleep_requested", "critical_heat_sleep_failed", "logging_disabled"])
        precondition(eventLines.allSatisfy { $0["batteryPercent"] as? Int == 74 })
        tick(false, true, 100)
        tick(true, true, 101)
        let second = try files()
        precondition(second.count == 2)
        tick(true, false, 102)
        tick(true, true, 103)
        let third = try files()
        precondition(third.count == 3)
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failing = SessionLog(directory: blocked.appendingPathComponent("logs"))
        var reportedError = false
        failing.onError = { _ in reportedError = true }
        failing.update(enabled: true, awake: true, now: now, lidClosed: true, thermalPressure: "Normal", lowPowerMode: false) {
            (nil, nil, nil, nil)
        }
        precondition(reportedError)
        print("session logging checks passed")
    }
}

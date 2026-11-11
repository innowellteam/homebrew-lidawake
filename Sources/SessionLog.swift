import Foundation
import IOKit
import IOKit.ps

let sessionLoggingKey = "SessionLogging"

struct SessionSample: Encodable {
    let timestamp: String
    let session: String
    let event: String
    let lidClosed: Bool
    let thermalPressure: String
    let lowPowerMode: Bool
    let powerSource: String?
    let batteryPercent: Int?
    let batteryVoltageMillivolts: Int?
    let batteryCurrentMilliamps: Int?
}

func batteryReadings() -> (source: String?, percent: Int?, voltage: Int?, current: Int?) {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    let battery = sources.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    let capacity = battery?[kIOPSCurrentCapacityKey] as? Int
    let maximum = battery?[kIOPSMaxCapacityKey] as? Int
    let percent = capacity.flatMap { value in maximum.flatMap { $0 > 0 ? value * 100 / $0 : nil } }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return (battery?[kIOPSPowerSourceStateKey] as? String, percent, nil, nil) }
    defer { IOObjectRelease(service) }
    func number(_ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }
    return (battery?[kIOPSPowerSourceStateKey] as? String, percent, number("Voltage"), number("Amperage"))
}

final class SessionLog {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LidAwake/Session Logs", isDirectory: true)
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    var onError: ((Error) -> Void)?
    private let directory: URL
    private var session: String?
    private var lastSample: Date?
    private var lastLidClosed: Bool?
    private var lastThermalPressure: String?
    private var lastLowPowerMode: Bool?

    init(directory: URL = SessionLog.directory) { self.directory = directory }

    func update(enabled: Bool, awake: Bool, now: Date = Date(), lidClosed: Bool, thermalPressure: String,
                lowPowerMode: Bool, event: String = "sample", readings: () -> (source: String?, percent: Int?, voltage: Int?, current: Int?)) {
        guard enabled && awake else {
            session = nil
            lastSample = nil
            lastLidClosed = nil
            lastThermalPressure = nil
            lastLowPowerMode = nil
            return
        }
        if session == nil { session = UUID().uuidString }
        guard event != "sample" || lastSample == nil || now.timeIntervalSince(lastSample!) >= 60 || lidClosed != lastLidClosed || thermalPressure != lastThermalPressure || lowPowerMode != lastLowPowerMode else { return }
        let battery = readings()
        let sample = SessionSample(timestamp: ISO8601DateFormatter().string(from: now), session: session!, event: event, lidClosed: lidClosed,
                                   thermalPressure: thermalPressure, lowPowerMode: lowPowerMode, powerSource: battery.source,
                                   batteryPercent: battery.percent, batteryVoltageMillivolts: battery.voltage, batteryCurrentMilliamps: battery.current)
        do {
            try Self.prepareDirectory(directory)
            let path = directory.appendingPathComponent("\(session!).jsonl")
            let data = try JSONEncoder().encode(sample) + Data("\n".utf8)
            if !FileManager.default.fileExists(atPath: path.path) {
                guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let file = try FileHandle(forWritingTo: path)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
            lastSample = now
            lastLidClosed = lidClosed
            lastThermalPressure = thermalPressure
            lastLowPowerMode = lowPowerMode
        } catch {
            NSLog("LidAwake: session log write failed: \(error)")
            onError?(error)
        }
    }
}

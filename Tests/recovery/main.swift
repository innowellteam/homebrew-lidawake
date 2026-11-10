import Foundation

let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_RECOVERY_DIRECTORY"]!)
let state = directory.appendingPathComponent("power")
let failRestore = directory.appendingPathComponent("fail-restore")
if CommandLine.arguments.dropFirst() == ["--heat-test"] {
    var emergencyCalls = 0
    guard restoreSleepForHeat(recovery: { true }, emergency: { emergencyCalls += 1; return true }) == .recovered,
          emergencyCalls == 0 else { exit(1) }
    guard restoreSleepForHeat(recovery: { false }, emergency: { emergencyCalls += 1; return true }) == .emergency,
          emergencyCalls == 1 else { exit(1) }
    guard restoreSleepForHeat(recovery: { false }, emergency: { emergencyCalls += 1; return false }) == .failed,
          emergencyCalls == 2 else { exit(1) }
    exit(0)
} else if CommandLine.arguments.dropFirst() == ["--sleep-recovery-worker"] {
    exit(runRecoveryWorker(directory: directory) { awake in
        if !awake && FileManager.default.fileExists(atPath: failRestore.path) { return false }
        if awake && FileManager.default.fileExists(atPath: directory.appendingPathComponent("fail-awake").path) { return false }
        do { try (awake ? "awake" : "sleep").write(to: state, atomically: true, encoding: .utf8); return true }
        catch { return false }
    })
} else if CommandLine.arguments.dropFirst() == ["--controller"] {
    let recovery = try SleepRecovery()
    guard recovery.set(true) else { exit(1) }
    print("controller ready"); fflush(stdout)
    while true { sleep(60) }
} else { exit(2) }

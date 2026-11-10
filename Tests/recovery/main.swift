import Foundation

let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_RECOVERY_DIRECTORY"]!)
let state = directory.appendingPathComponent("power")
let failRestore = directory.appendingPathComponent("fail-restore")
if CommandLine.arguments.dropFirst() == ["--sleep-recovery-worker"] {
    exit(runRecoveryWorker(directory: directory) { awake in
        if !awake && FileManager.default.fileExists(atPath: failRestore.path) { return false }
        do { try (awake ? "awake" : "sleep").write(to: state, atomically: true, encoding: .utf8); return true }
        catch { return false }
    })
} else if CommandLine.arguments.dropFirst() == ["--controller"] {
    let recovery = try SleepRecovery()
    guard recovery.set(true) else { exit(1) }
    print("controller ready"); fflush(stdout)
    while true { sleep(60) }
} else { exit(2) }

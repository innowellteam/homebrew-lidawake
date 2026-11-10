import Foundation
import Darwin

// The worker holds the only lock and is the only process that changes a setting it owns.
// A durable marker covers the interval from before disabling sleep until restoration succeeds.
final class SleepRecovery {
    private let input: FileHandle
    private let output: FileHandle
    private let process: Process

    init(onExit: @escaping () -> Void = {}) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--sleep-recovery-worker"]
        let commands = Pipe()
        let replies = Pipe()
        for handle in [commands.fileHandleForReading, commands.fileHandleForWriting, replies.fileHandleForReading, replies.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        process.standardInput = commands
        process.standardOutput = replies
        process.standardError = FileHandle.standardError
        input = commands.fileHandleForWriting
        output = replies.fileHandleForReading
        try process.run()
        commands.fileHandleForReading.closeFile()
        replies.fileHandleForWriting.closeFile()
        guard readLineFrom(output) == "ready" else { throw RecoveryError.unavailable }
        process.terminationHandler = { _ in onExit() }
    }

    func set(_ awake: Bool) -> Bool {
        guard process.isRunning else { return false }
        do {
            try input.write(contentsOf: Data((awake ? "awake\n" : "sleep\n").utf8))
            return readLineFrom(output) == "ok"
        } catch { return false }
    }
}

enum RecoveryError: Error { case unavailable }

private func readLineFrom(_ handle: FileHandle) -> String? {
    var bytes = Data()
    while let byte = try? handle.read(upToCount: 1), !byte.isEmpty {
        if byte[byte.startIndex] == 10 { return String(data: bytes, encoding: .utf8) }
        bytes.append(byte)
    }
    return nil
}

func recoveryCommand(_ awake: Bool) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    task.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", awake ? "1" : "0"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 } catch { return false }
}

func runRecoveryWorker(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/org.innowell.lidawake", isDirectory: true), command: (Bool) -> Bool = recoveryCommand) -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch { return 1 }
    let fd = open(directory.appendingPathComponent("recovery").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return 1 }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return 1 }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0 else { return 1 }
    var owns = info.st_size > 0
    func mark(_ active: Bool) -> Bool {
        guard ftruncate(fd, 0) == 0 else { return false }
        if active {
            let byte: UInt8 = 1
            guard pwrite(fd, [byte], 1, 0) == 1 else { return false }
        }
        return fsync(fd) == 0
    }
    func restore() -> Bool {
        guard owns else { return true }
        guard command(false), mark(false) else { return false }
        owns = false
        return true
    }
    guard restore() else { return 1 }
    print("ready"); fflush(stdout)
    while let request = readLineFrom(.standardInput) {
        let success: Bool
        switch request {
        case "awake":
            if owns { success = true }
            else if mark(true) {
                owns = true
                success = command(true)
                if !success { _ = restore() }
            } else { success = false }
        case "sleep":
            success = owns ? restore() : command(false)
        default: success = false
        }
        print(success ? "ok" : "error"); fflush(stdout)
    }
    return restore() ? 0 : 1
}

import Foundation

let sessionMinutes = [15, 30, 45, 60]

func sessionMenuTitle(minutes: Int) -> String {
    minutes == 60 ? "1 Hour" : "\(minutes) Minutes"
}

func sessionIsOver(deadline: Date?, now: Date) -> Bool {
    guard let deadline else { return false }
    return now >= deadline
}

// Rounded up, so the label never reads 0 while time remains.
func sessionTimeLeft(until deadline: Date, now: Date) -> String {
    let minutes = Int((deadline.timeIntervalSince(now) / 60).rounded(.up))
    return minutes <= 1 ? "Sleeps again in under a minute" : "Sleeps again in \(minutes) min"
}

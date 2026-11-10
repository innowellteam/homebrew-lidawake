import Foundation

@main
struct SessionTests {
    static func main() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let deadline = start.addingTimeInterval(30 * 60)
        precondition(!sessionIsOver(deadline: nil, now: start))
        precondition(!sessionIsOver(deadline: deadline, now: start))
        precondition(!sessionIsOver(deadline: deadline, now: deadline.addingTimeInterval(-1)))
        precondition(sessionIsOver(deadline: deadline, now: deadline))
        precondition(sessionIsOver(deadline: deadline, now: deadline.addingTimeInterval(3600)))
        precondition(sessionTimeLeft(until: deadline, now: start) == "Sleeps again in 30 min")
        precondition(sessionTimeLeft(until: deadline, now: start.addingTimeInterval(1)) == "Sleeps again in 30 min")
        precondition(sessionTimeLeft(until: deadline, now: start.addingTimeInterval(60)) == "Sleeps again in 29 min")
        precondition(sessionTimeLeft(until: deadline, now: deadline.addingTimeInterval(-61)) == "Sleeps again in 2 min")
        precondition(sessionTimeLeft(until: deadline, now: deadline.addingTimeInterval(-60)) == "Sleeps again in under a minute")
        precondition(sessionTimeLeft(until: deadline, now: deadline.addingTimeInterval(-1)) == "Sleeps again in under a minute")
        precondition(sessionMinutes.map(sessionMenuTitle) == ["15 Minutes", "30 Minutes", "45 Minutes", "1 Hour"])
        print("Session timer passed")
    }
}

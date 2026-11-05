import Foundation
import Testing

@testable import ClairWorkspace

@Suite struct ClairScheduleTests {
  var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return c }
  func at(_ s: String) -> Date {
    let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
  }
  func schedule(days: [Int] = [2, 3, 4, 5, 6], catchUp: Bool = false, lastRun: String) -> ClairSchedule {
    ClairSchedule(id: "a", days: days, hour: 9, minute: 0, project: "life", profile: "claude", key: nil,
                  prompt: "今何すべき", catchUp: catchUp, lastRun: at(lastRun))
  }

  @Test func firesOnTimeOnWeekdaysOnly() {
    // 2026-11-06 is a Friday, 11-07 Saturday, 11-09 Monday.
    let s = schedule(lastRun: "2026-11-05 10:00")
    #expect(s.decide(now: at("2026-11-06 08:59"), calendar: cal) == .wait)
    #expect(s.decide(now: at("2026-11-06 09:01"), calendar: cal) == .run(at("2026-11-06 09:00")))
    #expect(s.latestFire(atOrBefore: at("2026-11-09 08:00"), calendar: cal) == at("2026-11-06 09:00"))
    // Already handled: waits for the next one.
    #expect(schedule(lastRun: "2026-11-06 09:00").decide(now: at("2026-11-06 12:00"), calendar: cal) == .wait)
  }

  @Test func missedRunSkipsOrCatchesUpOnce() {
    let now = at("2026-11-06 11:00")
    #expect(schedule(lastRun: "2026-11-05 10:00").decide(now: now, calendar: cal) == .skip(at("2026-11-06 09:00")))
    #expect(schedule(catchUp: true, lastRun: "2026-11-04 10:00").decide(now: now, calendar: cal) == .run(at("2026-11-06 09:00")))
    // Created after today's time: nothing until tomorrow.
    #expect(schedule(lastRun: "2026-11-06 10:00").decide(now: now, calendar: cal) == .wait)
  }

  @Test func parsesDaysAndTime() {
    #expect(ClairSchedule.parseDays("weekdays") == [2, 3, 4, 5, 6])
    #expect(ClairSchedule.parseDays("") == [])
    #expect(ClairSchedule.parseDays("sat, sun") == [1, 7])
    #expect(ClairSchedule.parseDays("someday") == nil)
    #expect(ClairSchedule.parseTime("18:05")! == (18, 5))
    #expect(ClairSchedule.parseTime("24:00") == nil)
  }
}

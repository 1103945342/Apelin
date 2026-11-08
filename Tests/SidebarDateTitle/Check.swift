import Foundation

@main
struct SidebarDateTitleCheck {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 0, minute: 1))!
        let justBeforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 23, minute: 59))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
        let older = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!

        precondition(SidebarOrder.titleKind(for: today, now: today, calendar: calendar) == .today)
        precondition(SidebarOrder.titleKind(for: justBeforeMidnight, now: today, calendar: calendar) == .yesterday,
                     "the pre-midnight section must not remain Today after the clock crosses midnight")
        precondition(SidebarOrder.titleKind(for: yesterday, now: today, calendar: calendar) == .yesterday)
        precondition(SidebarOrder.titleKind(for: older, now: today, calendar: calendar) == .weekday)

        let chats = [
            ChatSummary(lastInteraction: justBeforeMidnight),
            ChatSummary(lastInteraction: today),
        ]
        let sections = SidebarOrder.sections(of: chats, calendar: calendar)
        precondition(sections.days.map(\.start) == [calendar.startOfDay(for: today), calendar.startOfDay(for: justBeforeMidnight)])
        precondition(sections.days.flatMap(\.chats).count == 2, "date presentation must not alter ordering or tree membership")

        var shifted = calendar
        shifted.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let shiftedNow = shifted.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 0, minute: 1))!
        precondition(SidebarOrder.titleKind(for: shiftedNow, now: shiftedNow, calendar: shifted) == .today)
        precondition(SidebarOrder.titleKind(for: today, now: shiftedNow, calendar: shifted) == .yesterday,
                     "title classification must follow the current time zone")

        print("ok: midnight, foreground, locale and time-zone date title rules")
    }
}

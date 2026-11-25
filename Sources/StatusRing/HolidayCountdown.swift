import Foundation

struct HolidayCountdown: Equatable, Identifiable {
    let id: Date
    let name: String
    let daysUntilStart: Int
    let dates: String
    let daysOff: Int

    struct Year: Equatable {
        let dates: String
        let holidays: [HolidayCountdown]
    }

    private struct Holiday {
        let name: String
        let start: Date
        let end: Date
        let dates: String
        let daysOff: Int

        func countdown(from today: Date) -> HolidayCountdown {
            let days = calendar.dateComponents([.day], from: today, to: start).day!
            return HolidayCountdown(id: start, name: name, daysUntilStart: max(0, days), dates: dates, daysOff: daysOff)
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    // State Council General Office notice for 2027, issued November 5, 2026.
    // https://chinajob.mohrss.gov.cn/h5/c/2026-11-09/635850.shtml
    private static let holidays = [
        holiday("元旦", month: 1, days: 1...3),
        holiday("春节", month: 2, days: 5...13),
        holiday("清明节", month: 4, days: 3...5),
        holiday("劳动节", month: 5, days: 1...5),
        holiday("端午节", month: 6, days: 9...9),
        holiday("中秋节", month: 9, days: 15...15),
        holiday("国庆节", month: 10, days: 1...7)
    ]

    static func current(at now: Date) -> Self? {
        let today = calendar.startOfDay(for: now)
        return holidays.first(where: { today <= $0.end })?.countdown(from: today)
    }

    static func year(at now: Date) -> Year {
        let today = calendar.startOfDay(for: now)
        let nextYear = calendar.date(byAdding: .year, value: 1, to: today)!
        let upcoming = holidays.filter { $0.end >= today && $0.start < nextYear }
        return Year(dates: dateTitle(today) + "–" + dateTitle(nextYear),
                    holidays: upcoming.map { $0.countdown(from: today) })
    }

    private static func dateTitle(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d.%02d.%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func holiday(_ name: String, month: Int, days: ClosedRange<Int>) -> Holiday {
        let first = days.lowerBound
        let last = days.upperBound
        let start = calendar.date(from: DateComponents(year: 2027, month: month, day: first))!
        let end = calendar.date(from: DateComponents(year: 2027, month: month, day: last))!
        let dates = first == last ? "\(month) 月 \(first) 日" : "\(month) 月 \(first)–\(last) 日"
        return Holiday(name: name, start: start, end: end, dates: dates, daysOff: days.count)
    }
}

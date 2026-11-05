import AppKit
import SwiftUI

struct WeekAgendaView: View {
    @ObservedObject var model: CalendarAgenda
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let blue = Color(nsColor: .systemBlue)

    var body: some View {
        let week = model.week
        let calendar = week.calendar
        let selected = model.selectedDate
        let events: [AgendaEvent] = if case .ready(let weekEvents) = model.state { weekEvents } else { [] }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(rangeTitle(week)).fontWeight(.semibold)
                Spacer(minLength: 4)
                weekArrow("chevron.left", label: "上周", offset: -1)
                Button("本周", action: model.selectToday)
                    .controlSize(.small)
                    .disabled(calendar.isDateInToday(selected))
                weekArrow("chevron.right", label: "下周", offset: 1)
            }
            HStack(spacing: 2) {
                ForEach(Array(week.days.enumerated()), id: \.element) { index, date in
                    let day = calendar.dateInterval(of: .day, for: date)!
                    dayButton(date, weekday: weekdays[index], calendar: calendar,
                              count: events.filter { $0.occurs(during: day) }.count)
                }
            }
            Divider()
            agenda(for: calendar.dateInterval(of: .day, for: selected)!, calendar: calendar, events: events)
        }
    }

    private func weekArrow(_ image: String, label: String, offset: Int) -> some View {
        Button { model.moveWeek(offset) } label: {
            Image(systemName: image)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func dayButton(_ date: Date, weekday: String, calendar: Calendar, count: Int) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: model.selectedDate)
        let today = calendar.isDateInToday(date)
        let dayNumber = calendar.component(.day, from: date)
        let accessibility = "\(dayTitle(date, calendar: calendar))，周\(weekday)"
            + (today ? "，今天" : "") + (count > 0 ? "，\(count) 项日程" : "")

        return Button { model.select(date) } label: {
            VStack(spacing: 2) {
                Text(weekday).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(dayNumber)").monospacedDigit()
                    .foregroundStyle(selected ? Color.white : (today ? blue : .primary))
                    .frame(width: 25, height: 25)
                    .background { if selected { Circle().fill(blue) } }
                    .overlay { if today && !selected { Circle().strokeBorder(blue, lineWidth: 1) } }
                Circle().fill(count > 0 ? blue : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func agenda(for day: DateInterval, calendar: Calendar, events: [AgendaEvent]) -> some View {
        let title = (calendar.isDateInToday(day.start) ? "今天 · " : "") + dayTitle(day.start, calendar: calendar)
        let dayEvents = events.filter { $0.occurs(during: day) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                if case .ready = model.state, !dayEvents.isEmpty {
                    Text("\(dayEvents.count) 项日程").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            switch model.state {
            case .needsAccess(let message):
                HStack(spacing: 8) {
                    Text(message).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("连接日历", action: model.requestAccess).controlSize(.small)
                }
            case .requesting:
                Text("等待系统日历授权…").foregroundStyle(.secondary)
            case .loading:
                Text("正在读取日程…").foregroundStyle(.secondary)
            case .unavailable(let message):
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .ready:
                if dayEvents.isEmpty {
                    Text("当天没有日程").foregroundStyle(.secondary)
                } else if dayEvents.count > 3 {
                    ScrollView { eventRows(dayEvents, day: day, calendar: calendar) }
                        .frame(height: 66)
                } else {
                    eventRows(dayEvents, day: day, calendar: calendar)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func eventRows(_ events: [AgendaEvent], day: DateInterval, calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(events) { event in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1).fill(blue).frame(width: 2, height: 13)
                        .accessibilityHidden(true)
                    Text(timeTitle(event, day: day, calendar: calendar))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .leading)
                    Text(event.title).lineLimit(1).help(event.title)
                    Spacer(minLength: 0)
                }
                .frame(height: 18)
            }
        }
    }

    private func timeTitle(_ event: AgendaEvent, day: DateInterval, calendar: Calendar) -> String {
        if event.allDay { return "全天" }
        let start = max(event.start, day.start)
        let end = min(event.end, day.end)
        func clock(_ date: Date) -> String {
            if date == day.end { return "24:00" }
            return String(format: "%02d:%02d", calendar.component(.hour, from: date),
                          calendar.component(.minute, from: date))
        }
        return start < end ? clock(start) + "–" + clock(end) : clock(start)
    }

    private func dayTitle(_ date: Date, calendar: Calendar) -> String {
        "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private func rangeTitle(_ week: AgendaWeek) -> String {
        let calendar = week.calendar
        let start = week.days[0]
        let end = week.days[6]
        let year = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        let prefix = year == calendar.component(.year, from: Date()) && year == endYear ? "" : "\(year)年"
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(prefix)\(calendar.component(.month, from: start))月 \(calendar.component(.day, from: start))–\(calendar.component(.day, from: end))日"
        }
        return prefix + dayTitle(start, calendar: calendar) + "–" + (year == endYear ? "" : "\(endYear)年")
            + dayTitle(end, calendar: calendar)
    }
}

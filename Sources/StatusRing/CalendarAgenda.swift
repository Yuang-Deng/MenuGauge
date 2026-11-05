import EventKit
import Foundation
import Combine

struct AgendaWeek {
    let calendar: Calendar
    let interval: DateInterval
    let days: [Date]

    init(containing date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.timeZone = timeZone
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)!
        self.calendar = calendar
        self.interval = interval
        days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: interval.start)! }
    }
}

struct AgendaEvent: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool

    func occurs(during day: DateInterval) -> Bool {
        start < day.end && (start >= day.start || end > day.start)
    }
}

private actor AgendaStore {
    private let store = EKEventStore()

    func requestAccess(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents(completion: completion)
        } else {
            store.requestAccess(to: .event, completion: completion)
        }
    }

    func events(in interval: DateInterval) -> [AgendaEvent] {
        guard !Task.isCancelled else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { event in
                AgendaEvent(title: event.title?.isEmpty == false ? event.title : "无标题",
                            start: event.startDate, end: event.endDate, allDay: event.isAllDay)
            }
            .sorted {
                if $0.allDay != $1.allDay { return $0.allDay }
                return $0.start < $1.start
            }
    }
}

@MainActor
final class CalendarAgenda: ObservableObject {
    enum State {
        case needsAccess(String), requesting, loading, ready([AgendaEvent]), unavailable(String)
    }

    @Published private(set) var selectedDate = Date()
    @Published private(set) var state: State = .loading

    private lazy var store = AgendaStore()
    private var isOpen = false
    private var requesting = false
    private var readTask: Task<Void, Never>?
    private var changes: AnyCancellable?

    var week: AgendaWeek { AgendaWeek(containing: selectedDate) }

    init() {
        changes = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func open() {
        isOpen = true
        selectedDate = Date()
        refresh()
    }

    func close() {
        isOpen = false
        readTask?.cancel()
        readTask = nil
        state = .loading
    }

    func select(_ day: Date) {
        selectedDate = day
    }

    func moveWeek(_ offset: Int) {
        guard let date = week.calendar.date(byAdding: .weekOfYear, value: offset, to: selectedDate) else { return }
        selectedDate = date
        refresh()
    }

    func selectToday() {
        let priorWeek = week.interval
        selectedDate = Date()
        if week.interval != priorWeek { refresh() }
    }

    private static var canRead: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) { return status == .fullAccess }
        return status == .authorized
    }

    private static var canRequest: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined { return true }
        if #available(macOS 14, *) { return status == .writeOnly }
        return false
    }

    func requestAccess() {
        guard !requesting, Self.canRequest else { return }
        requesting = true
        state = .requesting
        Task { [weak self, store] in
            await store.requestAccess { [weak self] _, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.requesting = false
                    if self.isOpen, error != nil, Self.canRequest {
                        self.state = .needsAccess("日历授权失败，请重试")
                    } else {
                        self.refresh()
                    }
                }
            }
        }
    }

    private func refresh() {
        guard isOpen, !requesting else { return }
        readTask?.cancel()
        guard Self.canRead else {
            if Self.canRequest {
                state = .needsAccess("连接后显示 Mac 日历的日程")
            } else if EKEventStore.authorizationStatus(for: .event) == .restricted {
                state = .unavailable("此 Mac 限制了日历访问")
            } else {
                state = .unavailable("请在「系统设置 → 隐私与安全性 → 日历」中允许 MenuGauge")
            }
            return
        }

        state = .loading
        let interval = week.interval
        readTask = Task { [weak self, store] in
            let events = await store.events(in: interval)
            guard let self, !Task.isCancelled else { return }
            if Self.canRead {
                self.state = .ready(events)
            } else {
                self.refresh()
            }
        }
    }
}

import Foundation

public struct CostChartPoint: Sendable, Identifiable {
    public let date: Date
    public let id: String
    public let claude: UsageMetrics
    public let codex: UsageMetrics
    public let isCurrentPeriod: Bool
    public let isCompletePeriod: Bool
    public var total: UsageMetrics {
        .combined([claude, codex])
    }
}

/// Daily observations in the current calendar month.
public struct DailyCostSeries: Sendable {
    public let points: [CostChartPoint]
    public let daysInMonth: Int
    public var completedDays: [CostChartPoint] {
        points.filter { $0.isCompletePeriod && !$0.total.partial && $0.total.cost != nil }
    }

    public var average: Double? {
        let values = completedDays.compactMap(\.total.cost)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public init(snapshot: UsageSnapshot?, now: Date = Date()) {
        guard let snapshot, snapshot.calendar.isDate(snapshot.capturedAt, equalTo: now, toGranularity: .month),
              let start = snapshot.calendar.dateInterval(of: .month, for: now)?.start
        else { points = []
            daysInMonth = 0
            return
        }
        let calendar = snapshot.calendar
        daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 0
        let completeBefore = calendar.startOfDay(for: min(now, snapshot.capturedAt))
        points = (0 ..< calendar.component(.day, from: now)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            func metric(_ id: String) -> UsageMetrics {
                // A cached snapshot cannot certify that later, unobserved days were empty.
                guard date <= snapshot.capturedAt else { return .unavailable }
                return snapshot.reports.first { $0.provider == id }?
                    .metrics(.today, now: date, calendar: calendar) ?? .unavailable
            }
            return CostChartPoint(
                date: date,
                id: ProviderReport.key(date, calendar: calendar),
                claude: metric("claude"),
                codex: metric("codex"),
                isCurrentPeriod: calendar.isDate(date, inSameDayAs: now),
                isCompletePeriod: date < completeBefore
            )
        }
    }
}

import Foundation

/// Monthly sums of recorded local usage.
public struct MonthlyCostSeries: Sendable {
    public let points: [CostChartPoint]
    public var completeMonths: [CostChartPoint] {
        points.filter { $0.isCompletePeriod && !$0.total.partial && $0.total.cost != nil }
    }

    public var average: Double? {
        let values = completeMonths.compactMap(\.total.cost)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public init(snapshot: UsageSnapshot?, now: Date = Date()) {
        guard let snapshot, let reports = snapshot.allReports else { points = []
            return
        }
        let calendar = snapshot.calendar
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let dates = reports.flatMap { $0.daily ?? [] }.compactMap { $0.date.flatMap(formatter.date(from:)) }
        guard let earliest = dates.min(), earliest <= now,
              let first = calendar.dateInterval(of: .month, for: earliest)?.start,
              let current = calendar.dateInterval(of: .month, for: now)?.start,
              let count = calendar.dateComponents([.month], from: first, to: current).month,
              count >= 0, count <= 1200
        else { points = []
            return
        }
        let completeBefore = calendar.dateInterval(of: .month, for: min(now, snapshot.capturedAt))!.start
        points = (0 ... count).compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: offset, to: first) else { return nil }
            let key = ProviderReport.key(month, calendar: calendar, monthOnly: true)
            func metric(_ provider: String) -> UsageMetrics {
                guard month <= snapshot.capturedAt,
                      let report = reports.first(where: { $0.provider == provider }), report.available,
                      report.reportingPeriod == "all" else { return .unavailable }
                let records = report.daily ?? []
                guard let firstKey = records.compactMap(\.date).min(),
                      let firstDay = formatter.date(from: firstKey) else { return .unavailable }
                var seen = Set<String>()
                let rows = records.filter {
                    guard let date = $0.date, date.hasPrefix(key + "-") else { return false }
                    return seen.insert(date).inserted
                }
                let missingPrefix = month < firstDay
                // Discovery coverage doesn't certify an entire record-free historical month.
                guard !rows.isEmpty else { return .unavailable }
                let totals = UsageMetrics.combined(rows.map { record in
                    let tokens = record.totalTokens.flatMap { $0 >= 0 ? $0 : nil }
                    var cost = record.totalCost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                    let models = record.modelBreakdowns ?? []
                    if !models.isEmpty, models.allSatisfy({ $0.cost == nil }), (tokens ?? 0) > 0 {
                        cost = nil
                    }
                    return UsageMetrics(
                        tokens: tokens,
                        cost: cost,
                        partial: record
                            .hasUnpricedModels || (record.incompleteRequestCount ?? 0) > 0 || tokens == nil ||
                            cost == nil
                    )
                })
                return UsageMetrics(
                    tokens: totals.tokens,
                    cost: totals.cost,
                    partial: totals.partial || report.partialHistory || missingPrefix
                )
            }
            return CostChartPoint(
                date: month,
                id: key,
                claude: metric("claude"),
                codex: metric("codex"),
                isCurrentPeriod: calendar.isDate(month, equalTo: now, toGranularity: .month),
                isCompletePeriod: month < completeBefore
            )
        }
    }
}

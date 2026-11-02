import Foundation
import LedgerCore
import Testing

extension LedgerCoreTests {
    static func dailyCostChecks() throws {
        let fixture = #"""
        [
          {"provider":"claude","source":"local","currencyCode":"USD","reportingPeriod":"month-to-date","historyCoverageIsEstablished":true,"totals":{"totalTokens":3,"totalCost":110},"daily":[{"date":"2026-10-01","totalTokens":1,"totalCost":10},{"date":"2026-10-02","totalTokens":1,"totalCost":20},{"date":"2026-10-03","totalTokens":1,"totalCost":80}]},
          {"provider":"codex","source":"local","currencyCode":"USD","reportingPeriod":"month-to-date","historyCoverageIsEstablished":true,"totals":{"totalTokens":3,"totalCost":100},"daily":[{"date":"2026-10-01","totalTokens":1,"totalCost":20},{"date":"2026-10-02","totalTokens":1,"totalCost":40},{"date":"2026-10-03","totalTokens":1,"totalCost":40}]}
        ]
        """#
        let now = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!
        let reports = try UsageSnapshot.decodeEngine(Data(fixture.utf8))
        let snapshot = UsageSnapshot(capturedAt: now, timeZoneID: "Asia/Tokyo", reports: reports)
        let series = DailyCostSeries(snapshot: snapshot, now: now)
        #expect(series.points.count == 3 && series.points.last!.total.cost == 120)
        #expect(series.average == 45 && series.completedDays.count == 2)
        #expect(series.points.last!.claude.cost == 80 && series.points.last!.codex.cost == 40)
        let partialJSON = fixture.replacingOccurrences(
            of: #""totalCost":40},{"date":"2026-10-03""#,
            with: #""totalCost":0,"modelBreakdowns":[{"modelName":"unpriced","totalTokens":1}]},{"date":"2026-10-03""#
        )
        let partialReports = try UsageSnapshot.decodeEngine(Data(partialJSON.utf8))
        let partial = DailyCostSeries(
            snapshot: UsageSnapshot(capturedAt: now, timeZoneID: "Asia/Tokyo", reports: partialReports),
            now: now
        )
        #expect(partial.points[1].codex.cost == nil && partial.points[1].total.cost == 20 && partial.points[1]
            .total.partial)
        #expect(partial.average == 30 && partial.completedDays.count == 1)
        let oneProvider = DailyCostSeries(
            snapshot: UsageSnapshot(capturedAt: now, timeZoneID: "Asia/Tokyo", reports: [reports[0]]),
            now: now
        )
        #expect(oneProvider.points[0].total.partial && oneProvider.average == nil)
        let yesterday = snapshot.calendar.date(byAdding: .day, value: -1, to: now)!
        let stale = DailyCostSeries(
            snapshot: UsageSnapshot(capturedAt: yesterday, timeZoneID: "Asia/Tokyo", reports: reports),
            now: now
        )
        #expect(stale.points.last!.total.cost == nil && stale.average == 30 && stale.completedDays.count == 1)
        #expect(series.daysInMonth == 31)
        let november = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
        #expect(DailyCostSeries(snapshot: snapshot, now: november).points.isEmpty)
        #expect(DailyCostSeries(snapshot: nil, now: now).average == nil)
    }
}

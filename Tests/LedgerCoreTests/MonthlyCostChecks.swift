import Foundation
import LedgerCore
import Testing

extension LedgerCoreTests {
    static func monthlyCostChecks() throws {
        let fixture = #"""
        [
          {"provider":"claude","source":"local","currencyCode":"USD","reportingPeriod":"all","historyCoverageIsEstablished":true,"totals":{"totalTokens":4,"totalCost":65},"daily":[{"date":"2026-07-31","totalTokens":1,"totalCost":10},{"date":"2026-08-01","totalTokens":1,"totalCost":20},{"date":"2026-08-31","totalTokens":1,"totalCost":30},{"date":"2026-09-01","totalTokens":1,"totalCost":5}]},
          {"provider":"codex","source":"local","currencyCode":"USD","reportingPeriod":"all","historyCoverageIsEstablished":true,"totals":{"totalTokens":4,"totalCost":650},"daily":[{"date":"2026-07-31","totalTokens":1,"totalCost":100},{"date":"2026-08-01","totalTokens":1,"totalCost":200},{"date":"2026-08-31","totalTokens":1,"totalCost":300},{"date":"2026-09-01","totalTokens":1,"totalCost":50}]}
        ]
        """#
        let now = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
        let reports = try UsageSnapshot.decodeEngine(Data(fixture.utf8))
        func series(_ reports: [ProviderReport], captured: Date = now, current: Date = now) -> MonthlyCostSeries {
            MonthlyCostSeries(
                snapshot: UsageSnapshot(
                    capturedAt: captured,
                    timeZoneID: "Asia/Tokyo",
                    reports: [],
                    allReports: reports
                ),
                now: current
            )
        }
        let months = series(reports)
        #expect(months.points.map(\.id) == ["2026-07", "2026-08", "2026-09"])
        #expect(months.points.compactMap(\.total.cost).reduce(0, +) == 715)
        #expect(months.points[0].total.partial && months.average == 550 && months.completeMonths.count == 1)
        #expect(months.points.last!.isCurrentPeriod && !months.points.last!.isCompletePeriod)
        #expect(months.points[1].claude.cost == 50 && months.points[1].codex.cost == 500)
        let partialJSON = fixture.replacingOccurrences(
            of: #"{"date":"2026-07-31","totalTokens":1,"totalCost":10},"#,
            with: ""
        )
        let partial = try series(UsageSnapshot.decodeEngine(Data(partialJSON.utf8)))
        #expect(partial.points[0].claude.cost == nil && partial.points[0].total.cost == 100 && partial.points[0]
            .total.partial)
        let unpricedJSON = fixture.replacingOccurrences(
            of: #""totalCost":300}"#,
            with: #""totalCost":0,"modelBreakdowns":[{"modelName":"unpriced","totalTokens":1}]}"#
        )
        let unpriced = try series(UsageSnapshot.decodeEngine(Data(unpricedJSON.utf8)))
        #expect(unpriced.points[1].total.partial && unpriced.average == nil && unpriced.points[1].total
            .cost == 250)
        let october = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        let stale = series(reports, current: october)
        #expect(stale.points.last!.total.cost == nil && stale.points[2].isCompletePeriod == false && stale
            .average == 550)
        #expect(MonthlyCostSeries(snapshot: nil, now: now).points.isEmpty)
        let duplicateJSON = fixture.replacingOccurrences(
            of: #"{"date":"2026-08-01","totalTokens":1,"totalCost":20}"#,
            with: #"{"date":"2026-08-01","totalTokens":1,"totalCost":20},{"date":"2026-08-01","totalTokens":1,"totalCost":999}"#
        )
        let duplicates = try series(UsageSnapshot.decodeEngine(Data(duplicateJSON.utf8)))
        #expect(duplicates.points[1].total.cost == 550)
    }
}

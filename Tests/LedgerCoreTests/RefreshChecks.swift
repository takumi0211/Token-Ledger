import Foundation
import LedgerCore
import Testing

extension LedgerCoreTests {
    static func refreshChecks() throws {
        let json = #"""
        [{"provider":"codex","source":"local","currencyCode":"USD","reportingPeriod":"all","historyCoverageIsEstablished":true,"totals":{"totalTokens":130,"totalCost":13},"daily":[{"date":"2026-09-30","totalTokens":100,"totalCost":10},{"date":"2026-10-01","totalTokens":10,"totalCost":1},{"date":"2026-10-02","totalTokens":20,"totalCost":2}]},
        {"provider":"claude","source":"local","currencyCode":"USD","reportingPeriod":"all","historyCoverageIsEstablished":true,"totals":{"totalTokens":260,"totalCost":26},"daily":[{"date":"2026-09-30","totalTokens":200,"totalCost":20},{"date":"2026-10-01","totalTokens":20,"totalCost":2},{"date":"2026-10-02","totalTokens":40,"totalCost":4}]}]
        """#
        let now = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let all = try UsageSnapshot.decodeEngine(Data(json.utf8))
        let month = all.map { $0.monthToDate(now: now, calendar: calendar) }
        let snapshot = UsageSnapshot(capturedAt: now, timeZoneID: "Asia/Tokyo", reports: month, allReports: all)
        #expect(snapshot.metrics(.month, now: now).cost == 9 && snapshot.metrics(.all, now: now).cost == 39)
        let changed = try UsageSnapshot.decodeEngine(Data(json.replacingOccurrences(
            of: #""date":"2026-10-02","totalTokens":20,"totalCost":2}"#,
            with: #""date":"2026-10-02","totalTokens":20,"totalCost":5}"#
        ).utf8))
        let latest = changed.map { $0.monthToDate(now: now, calendar: calendar) }
        let merged = try snapshot.updatingCurrentMonth(latest, now: now.addingTimeInterval(60))
        #expect(merged.metrics(.all, now: now).cost == 42 && merged.metrics(.month, now: now).cost == 12)
        let again = try merged.updatingCurrentMonth(latest, now: now.addingTimeInterval(120))
        #expect(again.metrics(.all, now: now).cost == 42 && again.historyReconciledAt == snapshot
            .historyReconciledAt)
        #expect(again.allReports?.first { $0.provider == "codex" }?.daily?.first?.date == "2026-09-30")
        let unpriced = json.replacingOccurrences(
            of: #""date":"2026-10-02","totalTokens":20,"totalCost":2}"#,
            with: #""date":"2026-10-02","totalTokens":20,"totalCost":0,"modelBreakdowns":[{"modelName":"unknown","totalTokens":20}]}"#
        )
        let unknown = try UsageSnapshot.decodeEngine(Data(unpriced.utf8)).map { $0.monthToDate(
            now: now,
            calendar: calendar
        ) }
        #expect(unknown[0].metrics(.month, now: now, calendar: calendar).partial)
        #expect(unknown[0].metrics(.today, now: now, calendar: calendar).cost == nil)
        let tomorrow = now.addingTimeInterval(86400)
        #expect(snapshot.canUpdateCurrentMonth(now: tomorrow, timeZoneID: "Asia/Tokyo"))
        #expect(snapshot.needsHistoryReconciliation(now: tomorrow))
        #expect(snapshot.metrics(.today, now: tomorrow).cost == nil)
        let nextDay = try snapshot.updatingCurrentMonth(latest, now: tomorrow)
        #expect(nextDay.metrics(.today, now: tomorrow).cost == 0)
        #expect(nextDay.metrics(.month, now: tomorrow).cost == 12 && nextDay.metrics(.all, now: tomorrow)
            .cost == 42)
        #expect(nextDay.historyReconciledAt == snapshot.historyReconciledAt)
        #expect(!snapshot.canUpdateCurrentMonth(
            now: calendar.date(byAdding: .month, value: 1, to: now)!,
            timeZoneID: "Asia/Tokyo"
        ))
        #expect(!snapshot.canUpdateCurrentMonth(now: now, timeZoneID: "UTC"))
        do { _ = try snapshot.updatingCurrentMonth([latest[0]], now: now)
            Issue.record("Missing provider accepted")
        } catch { #expect(error is LedgerError) }
        let recovered = try UsageSnapshot.decodeEngine(Data(json.replacingOccurrences(
            of: #""date":"2026-09-30","totalTokens":100,"totalCost":10}"#,
            with: #""date":"2026-09-30","totalTokens":100,"totalCost":17}"#
        ).utf8))
        let full = UsageSnapshot(
            capturedAt: tomorrow.addingTimeInterval(30),
            timeZoneID: "Asia/Tokyo",
            reports: recovered.map { $0.monthToDate(now: tomorrow, calendar: calendar) },
            allReports: recovered
        )
        let concurrentMonth = try nextDay.updatingCurrentMonth(latest, now: tomorrow.addingTimeInterval(60))
        let historyFirst = try full.acceptingRefresh(concurrentMonth)
        let monthFirst = try concurrentMonth.acceptingRefresh(full)
        for result in [historyFirst, monthFirst] {
            #expect(result.metrics(.all, now: tomorrow).cost == 49 && result.metrics(.month, now: tomorrow)
                .cost == 12)
            #expect(result.capturedAt == concurrentMonth.capturedAt && result.historyReconciledAt == full
                .historyReconciledAt)
            #expect(!result.needsHistoryReconciliation(now: tomorrow))
        }
        let degraded = try UsageSnapshot.decodeEngine(Data(json.replacingOccurrences(
            of: #""historyCoverageIsEstablished":true"#,
            with: #""historyCoverageIsEstablished":false"#
        ).utf8))
        let incomplete = UsageSnapshot(
            capturedAt: tomorrow,
            timeZoneID: "Asia/Tokyo",
            reports: degraded.map { $0.monthToDate(now: tomorrow, calendar: calendar) },
            allReports: degraded
        )
        #expect(!incomplete.canUpdateCurrentMonth(now: tomorrow, timeZoneID: "Asia/Tokyo"))
        #expect(!UsageSnapshot(
            capturedAt: tomorrow,
            timeZoneID: "Asia/Tokyo",
            reports: latest,
            allReports: [all[0]]
        )
        .canUpdateCurrentMonth(now: tomorrow, timeZoneID: "Asia/Tokyo"))
        let legacyPricing = UsageSnapshot(
            capturedAt: now,
            timeZoneID: "Asia/Tokyo",
            reports: month,
            allReports: all,
            historyPricingVersion: nil
        )
        #expect(legacyPricing.needsHistoryReconciliation(now: now))
        let migrating = try legacyPricing.updatingCurrentMonth(latest, now: now.addingTimeInterval(60))
        #expect(migrating.historyPricingVersion == nil && migrating.needsHistoryReconciliation(now: now))
        #expect(migrating.metrics(.month, now: now).cost == 12 && migrating.metrics(.all, now: now).partial)
        let repriced = try migrating.acceptingRefresh(full)
        #expect(repriced.historyPricingVersion == UsageSnapshot.currentHistoryPricingVersion)
        #expect(!repriced.needsHistoryReconciliation(now: tomorrow))
    }
}

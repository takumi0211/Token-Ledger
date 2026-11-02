import Foundation
@testable import LedgerCore
import Testing

struct LedgerCoreTests {
    @Test
    func accounting() throws {
        let fixture = #"""
        [
          {"provider":"codex","source":"local","currencyCode":"USD","reportingPeriod":"month-to-date","historyCoverageIsEstablished":true,"totals":{"totalTokens":1500,"totalCost":1.5},"daily":[{"date":"2026-10-17","totalTokens":500,"totalCost":0.5},{"date":"2026-10-18","inputTokens":900,"cacheReadTokens":850,"outputTokens":100,"totalTokens":1000,"totalCost":1.0}],"projects":[{"path":"/fictional/private/project"}]},
          {"provider":"claude","source":"local","currencyCode":"USD","reportingPeriod":"month-to-date","historyCoverageIsEstablished":true,"totals":{"totalTokens":3000,"totalCost":3},"daily":[{"date":"2026-10-18","inputTokens":10,"cacheReadTokens":2500,"cacheCreationTokens":190,"outputTokens":300,"totalTokens":3000,"totalCost":3}]}
        ]
        """#
        let reports = try UsageSnapshot.decodeEngine(Data(fixture.utf8))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-17T15:05:00Z"))
        let snapshot = UsageSnapshot(capturedAt: now, timeZoneID: "Asia/Tokyo", reports: reports)
        #expect(snapshot.metrics(.today, now: now).tokens == 4000)
        #expect(snapshot.metrics(.today, now: now).cost == 4)
        #expect(snapshot.metrics(.month, now: now).tokens == 4500 && snapshot.metrics(.month, now: now)
            .cost == 4.5)
        let allFixture = fixture.replacingOccurrences(of: "month-to-date", with: "all").replacingOccurrences(
            of: "2026-10-17",
            with: "2026-09-17"
        )
        let allReports = try UsageSnapshot.decodeEngine(Data(allFixture.utf8))
        let withAll = UsageSnapshot(capturedAt: now, timeZoneID: "Asia/Tokyo", reports: reports, allReports: allReports)
        #expect(try withAll.metrics(
            .all,
            now: #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        ).tokens == 4500 && withAll.metrics(.all, now: now).cost == 4.5)
        #expect(snapshot.metrics(.all, now: now).tokens == nil)
        #expect(allReports[0].metrics(.month, now: now, calendar: snapshot.calendar).tokens == nil)
        let cached = try #require(try String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        #expect(!cached.contains("/fictional/private") && !cached.contains("projects"))
        let nextMonth = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(snapshot.metrics(.month, now: nextMonth).cost == nil)
        let unknown = #"[{"provider":"codex","source":"local","currencyCode":"USD","reportingPeriod":"month-to-date","historyCoverageIsEstablished":false,"coverage":{"priced":0,"unpriced":1},"totals":{"totalTokens":100,"totalCost":0},"daily":[{"date":"2026-10-18","totalTokens":100,"totalCost":0,"modelBreakdowns":[{"modelName":"fixture-unknown-model","totalTokens":100}]}]}]"#
        let missing = try UsageSnapshot(
            capturedAt: now,
            timeZoneID: "Asia/Tokyo",
            reports: UsageSnapshot.decodeEngine(Data(unknown.utf8))
        )
        #expect(missing.metrics(.today, now: now).cost == nil && missing.metrics(.month, now: now).cost == nil)
        #expect(missing.metrics(.today, now: now).tokens == 100 && missing.metrics(.today, now: now).partial)
        let tomorrow = try #require(snapshot.calendar.date(byAdding: .day, value: 1, to: now))
        #expect(reports[0].metrics(.today, now: tomorrow, calendar: snapshot.calendar).cost == 0)
        #expect(missing.reports[0].metrics(.today, now: tomorrow, calendar: snapshot.calendar).cost == nil)
        let partial = UsageMetrics.combined([UsageMetrics(tokens: 100, cost: 2, partial: false), .unavailable])
        #expect(partial.cost == 2 && partial.partial && partial.money == "$2")
        do {
            _ = try UsageSnapshot
                .decodeEngine(Data("[\(fixture.dropFirst().dropLast()),\(fixture.dropFirst().dropLast())]"
                        .utf8))
            Issue.record("Duplicate provider accepted")
        } catch { #expect(error is LedgerError) }
        let overflow = UsageMetrics.combined([
            .init(tokens: Int64.max, cost: 1, partial: false),
            .init(tokens: 1, cost: 1, partial: false),
        ])
        #expect(overflow.tokens == nil && overflow.partial)
        #expect(UsageMetrics(tokens: 285_800_000, cost: 91.42, partial: false).money == "$91")
        for (cost, expected) in [(108.0, "$108"), (999.0, "$999"), (999.96, "$1K"), (2576.0, "$2.6K"),
                                 (9950.0, "$10K"), (28170.0, "$28K"), (999_499.0, "$999K"), (999_500.0, "$1M"),
                                 (999_960.0, "$1M"), (2_576_000.0, "$2.6M"), (999_960_000.0, "$1B")]
        {
            #expect(UsageMetrics(tokens: nil, cost: cost, partial: false).compactMoney == expected)
        }
        #expect(UsageMetrics.unavailable.compactMoney == "—")
        let modeFixture = #"{"modelName":"gpt-6.1-sol","totalTokens":300,"cost":5,"standardCostUSD":1,"priorityCostUSD":4,"standardTokens":100,"priorityTokens":200}"#
        let mixed = try JSONDecoder().decode(ModelUsage.self, from: Data(modeFixture.utf8))
        #expect(mixed.displayRows.map(\.modelName) == ["gpt-6.1-sol", "gpt-6.1-sol · Fast"])
        #expect(mixed.displayRows.compactMap(\.cost).reduce(0, +) == mixed.cost)
        #expect(mixed.displayRows.compactMap(\.totalTokens).reduce(0, +) == mixed.totalTokens)
        let restored = try JSONDecoder().decode(ModelUsage.self, from: JSONEncoder().encode(mixed))
        #expect(restored.displayRows.last?.cost == 4)
        var fastOnly = mixed
        fastOnly.standardCostUSD = nil
        fastOnly.standardTokens = nil
        fastOnly
            .priorityCostUSD = 5
        #expect(fastOnly.displayRows.count == 1 && fastOnly.displayRows[0].modelName.hasSuffix(" · Fast"))
        var mismatch = mixed
        mismatch.priorityCostUSD = 10
        #expect(mismatch.displayRows.count == 1 && mismatch.displayRows[0].modelName == mixed.modelName)
        let legacyModel = ModelUsage(modelName: "fixture-model", totalTokens: 10, cost: 1)
        #expect(legacyModel.displayRows.count == 1 && legacyModel.displayRows[0].modelName == "fixture-model")
    }

    @Test
    func archive() throws {
        try Self.archiveChecks()
    }

    @Test
    func claude() throws {
        try Self.claudeChecks()
    }

    @Test
    func dailyChart() throws {
        try Self.dailyCostChecks()
    }

    @Test
    func monthlyChart() throws {
        try Self.monthlyCostChecks()
    }

    @Test
    func quotas() throws {
        try Self.quotaChecks()
    }

    @Test
    func refreshMerge() throws {
        try Self.refreshChecks()
    }

    @Test
    func manualRefresh() async throws {
        try await Self.refreshProcessChecks()
    }
}

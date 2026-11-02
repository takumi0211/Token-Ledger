import Foundation

extension ProviderReport {
    /// Rebucket already-priced daily records. No new pricing or usage attribution is performed.
    public func monthToDate(now: Date, calendar: Calendar) -> ProviderReport {
        let month = Self.key(now, calendar: calendar, monthOnly: true)
        let rows = (daily ?? []).filter { ($0.date ?? "").hasPrefix(month + "-") }
        return regrouped(rows, reportingPeriod: "month-to-date")
    }

    func regrouped(_ rows: [UsageRecord], reportingPeriod: String) -> ProviderReport {
        func sum(_ key: KeyPath<UsageRecord, Int64?>) -> Int64? {
            var result: Int64 = 0
            for row in rows {
                guard let value = row[keyPath: key], value >= 0 else { return nil }
                let next = result.addingReportingOverflow(value)
                guard !next.overflow else { return nil }
                result = next.partialValue
            }
            return result
        }
        let costs = rows.compactMap(\.totalCost).filter { $0.isFinite && $0 >= 0 }
        let cost = costs.reduce(0, +)
        var priced = 0, unpriced = 0
        for row in rows {
            let models = row.modelBreakdowns ?? []
            if models.isEmpty {
                if let cost = row.totalCost, cost.isFinite, cost >= 0 {
                    priced += 1
                } else {
                    unpriced += 1
                }
            } else {
                priced += models.filter { $0.cost != nil }.count
                unpriced += models.filter { $0.cost == nil }.count
                if row.totalCost.map({ !$0.isFinite || $0 < 0 }) ?? true {
                    unpriced += 1
                }
            }
        }
        var total: UsageRecord?
        if available, historyCoverageIsEstablished == true || !rows.isEmpty {
            var record = UsageRecord(
                totalTokens: sum(\.totalTokens),
                totalCost: (rows.isEmpty || !costs.isEmpty) && cost.isFinite ? cost : nil
            )
            record.inputTokens = sum(\.inputTokens)
            record.cacheReadTokens = sum(\.cacheReadTokens)
            record.cacheCreationTokens = sum(\.cacheCreationTokens)
            record.outputTokens = sum(\.outputTokens)
            total = record
        }
        return ProviderReport(
            provider: provider,
            source: source,
            updatedAt: updatedAt,
            currencyCode: currencyCode,
            reportingPeriod: reportingPeriod,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            totals: total,
            coverage: Coverage(
                priced: priced,
                unpriced: unpriced,
                unmetered: coverage?.unmetered,
                estimated: coverage?.estimated
            ),
            provenance: provenance,
            daily: rows,
            error: error,
            incompleteRequestCount: incompleteRequestCount
        )
    }
}

public extension UsageSnapshot {
    func canUpdateCurrentMonth(now: Date, timeZoneID: String) -> Bool {
        guard self.timeZoneID == timeZoneID, historyFormatVersion == 4,
              calendar.isDate(capturedAt, equalTo: now, toGranularity: .month),
              let allReports, allReports.count == 2,
              Set(allReports.map(\.provider)) == Set(["claude", "codex"]) else { return false }
        return allReports.allSatisfy { $0.available && $0.reportingPeriod == "all" && !$0.partialHistory }
    }

    func needsHistoryReconciliation(now: Date) -> Bool {
        historyPricingVersion != Self.currentHistoryPricingVersion || !calendar.isDate(
            historyReconciledAt ?? capturedAt,
            inSameDayAs: now
        )
    }

    /// Keep the newest complete historical baseline and the newest monthly observation,
    /// regardless of which of the independent refreshes finishes first.
    func acceptingRefresh(_ incoming: UsageSnapshot) throws -> UsageSnapshot {
        guard canUpdateCurrentMonth(now: incoming.capturedAt, timeZoneID: incoming.timeZoneID),
              incoming.canUpdateCurrentMonth(now: capturedAt, timeZoneID: timeZoneID) else { return incoming }
        let baseline = (historyReconciledAt ?? capturedAt) > (incoming.historyReconciledAt ?? incoming.capturedAt) ?
            self : incoming
        let current = capturedAt > incoming.capturedAt ? self : incoming
        return try baseline.updatingCurrentMonth(current.reports, now: current.capturedAt)
    }

    func updatingCurrentMonth(_ reports: [ProviderReport], now: Date) throws -> UsageSnapshot {
        let month = ProviderReport.key(now, calendar: calendar, monthOnly: true)
        guard canUpdateCurrentMonth(now: now, timeZoneID: timeZoneID),
              Set(reports.map(\.provider)) == Set(["claude", "codex"]), reports.count == 2,
              reports.allSatisfy({ $0.available && $0.reportingPeriod == "month-to-date" && !$0.partialHistory }),
              reports.allSatisfy({ ($0.daily ?? []).allSatisfy { ($0.date ?? "").hasPrefix(month + "-") } }),
              let allReports else { throw LedgerError.invalidReport }
        let refreshed = try allReports.map { old -> ProviderReport in
            guard let current = reports.first(where: { $0.provider == old.provider })
            else { throw LedgerError.invalidReport }
            let past = (old.daily ?? []).filter { !($0.date ?? "").hasPrefix(month + "-") }
            return old.regrouped(past + (current.daily ?? []), reportingPeriod: "all")
        }
        return UsageSnapshot(
            capturedAt: now,
            timeZoneID: timeZoneID,
            reports: reports,
            allReports: refreshed,
            historyReconciledAt: historyReconciledAt ?? capturedAt,
            historyPricingVersion: historyPricingVersion
        )
    }
}

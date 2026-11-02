import Foundation

public enum LedgerPeriod: String, CaseIterable, Sendable { case today = "Today", month = "Month", all = "All" }
public struct ModelUsage: Codable, Sendable, Identifiable {
    public let modelName: String
    public let totalTokens: Int64?
    public let cost: Double?
    public var standardCostUSD: Double?
    public var priorityCostUSD: Double?
    public var standardTokens: Int64?
    public var priorityTokens: Int64?
    public var id: String {
        modelName
    }

    public init(modelName: String, totalTokens: Int64?, cost: Double?) {
        self.modelName = modelName
        self.totalTokens = totalTokens
        self.cost = cost
    }

    /// Display the upstream's already-priced mode subtotals without repricing usage.
    public var displayRows: [ModelUsage] {
        guard let fast = priorityCostUSD, fast.isFinite, fast >= 0,
              let cost, cost.isFinite,
              abs((standardCostUSD ?? 0) + fast - cost) < max(0.000001, abs(cost) * 1e-9) else { return [self] }
        var rows: [ModelUsage] = []
        if let standard = standardCostUSD, standard > 0 || (standardTokens ?? 0) > 0 {
            rows.append(ModelUsage(modelName: modelName, totalTokens: standardTokens, cost: standard))
        }
        rows.append(ModelUsage(modelName: modelName + " · Fast", totalTokens: priorityTokens, cost: fast))
        return rows
    }
}

public struct UsageRecord: Codable, Sendable {
    public var date: String?
    public var totalTokens: Int64?
    public var totalCost: Double?
    public var inputTokens: Int64?
    public var outputTokens: Int64?
    public var cacheReadTokens: Int64?
    public var cacheCreationTokens: Int64?
    public var modelBreakdowns: [ModelUsage]?
    public var incompleteRequestCount: Int?
    public var hasUnpricedModels: Bool {
        (modelBreakdowns ?? []).contains { ($0.totalTokens ?? 0) > 0 && $0.cost == nil }
    }

    public init(date: String? = nil, totalTokens: Int64? = nil, totalCost: Double? = nil) {
        self.date = date
        self.totalTokens = totalTokens
        self.totalCost = totalCost
    }
}

public struct Coverage: Codable, Sendable {
    public var priced: Int?
    public var unpriced: Int?
    public var unmetered: Int?
    public var estimated: Int?
}

public struct ProviderReport: Codable, Sendable, Identifiable {
    public let provider: String
    public let source: String?
    public let updatedAt: String?
    public let currencyCode: String?
    public let reportingPeriod: String?
    public let historyCoverageIsEstablished: Bool?
    public let totals: UsageRecord?
    public let coverage: Coverage?
    public let provenance: String?
    public let daily: [UsageRecord]?
    public let error: ReportError?
    public let incompleteRequestCount: Int?
    public struct ReportError: Codable, Sendable { public let code: String? }
    public var id: String {
        provider
    }

    public var title: String {
        provider == "claude" ? "Claude Code" : "Codex"
    }

    public var available: Bool {
        error == nil && source == "local" && currencyCode == "USD" && ["month-to-date", "all"]
            .contains(reportingPeriod ?? "") && totals != nil
    }

    public var partialHistory: Bool {
        historyCoverageIsEstablished != true || (coverage?.unmetered ?? 0) > 0 || (incompleteRequestCount ?? 0) > 0
    }

    public func metrics(_ period: LedgerPeriod, now: Date, calendar: Calendar) -> UsageMetrics {
        guard available, reportingPeriod == (period == .all ? "all" : "month-to-date") else { return .unavailable }
        let month = Self.key(now, calendar: calendar, monthOnly: true)
        let day = Self.key(now, calendar: calendar)
        let record: UsageRecord
        if period == .today {
            if let found = (daily ?? []).first(where: { $0.date == day }) {
                record = found
            } else if !partialHistory {
                record = UsageRecord(totalTokens: 0, totalCost: 0)
            } else {
                return .unavailable
            }
        } else if period == .all {
            guard let total = totals else { return .unavailable }
            record = total
        } else {
            // An old cached month must never masquerade as the current month.
            guard (daily ?? []).allSatisfy({ ($0.date ?? "").hasPrefix(month) }),
                  let total = totals else { return .unavailable }
            record = total
        }
        var cost = record.totalCost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let models = record.modelBreakdowns ?? []
        let allUnpriced = !models.isEmpty && models.allSatisfy { $0.cost == nil } && (record.totalTokens ?? 0) > 0
        if allUnpriced ||
            (period != .today && (coverage?.priced ?? 0) == 0 && (coverage?.unpriced ?? 0) > 0)
        {
            cost = nil
        }
        let tokens = record.totalTokens.flatMap { $0 >= 0 ? $0 : nil }
        let partial = partialHistory || record
            .hasUnpricedModels || (record.incompleteRequestCount ?? 0) > 0 ||
            (period != .today && (coverage?.unpriced ?? 0) > 0)
        return UsageMetrics(tokens: tokens, cost: cost, partial: partial || tokens == nil || cost == nil)
    }

    public static func key(_ date: Date, calendar: Calendar, monthOnly: Bool = false) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return monthOnly ? String(format: "%04d-%02d", c.year!, c.month!) : String(
            format: "%04d-%02d-%02d",
            c.year!,
            c.month!,
            c.day!
        )
    }
}

public struct UsageMetrics: Sendable {
    public let tokens: Int64?
    public let cost: Double?
    public let partial: Bool
    public init(tokens: Int64?, cost: Double?, partial: Bool) {
        self.tokens = tokens
        self.cost = cost
        self.partial = partial
    }

    public static let unavailable = UsageMetrics(tokens: nil, cost: nil, partial: true)
    public static func combined(_ values: [UsageMetrics]) -> UsageMetrics {
        let tokens = values.compactMap(\.tokens), costs = values.compactMap(\.cost)
        var tokenSum: Int64 = 0, overflow = false
        for value in tokens {
            let next = tokenSum.addingReportingOverflow(value)
            tokenSum = next
                .partialValue
            overflow = overflow || next.overflow
        }
        let costSum = costs.reduce(0, +)
        return UsageMetrics(
            tokens: tokens.isEmpty || overflow ? nil : tokenSum,
            cost: costs.isEmpty || !costSum.isFinite ? nil : costSum,
            partial: values.contains(where: \.partial) || tokens.count != values.count || costs.count != values
                .count || overflow || !costSum.isFinite
        )
    }

    public var money: String {
        cost.map { String(format: "$%.0f", $0) } ?? "—"
    }

    public var compactMoney: String {
        guard let cost else { return "—" }
        // Keep ordinary menu amounts within five characters, including $ and unit.
        for (scale, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] {
            if abs(cost) >= scale - (scale == 1e3 ? 0.5 : scale / 2000) {
                let scaled = cost / scale
                let value = String(format: abs(scaled) < 9.95 ? "%.1f" : "%.0f", scaled)
                return "$" + (value.hasSuffix(".0") ? String(value.dropLast(2)) : value) + suffix
            }
        }
        return money
    }
}

public struct UsageSnapshot: Codable, Sendable {
    public static let currentHistoryPricingVersion = 3
    public let capturedAt: Date
    public let timeZoneID: String
    public let reports: [ProviderReport]
    public let allReports: [ProviderReport]?
    public let historyFormatVersion: Int?
    public let historyReconciledAt: Date?
    public let historyPricingVersion: Int?
    public init(
        capturedAt: Date = Date(),
        timeZoneID: String = TimeZone.current.identifier,
        reports: [ProviderReport],
        allReports: [ProviderReport]? = nil,
        historyReconciledAt: Date? = nil,
        historyPricingVersion: Int? = currentHistoryPricingVersion
    ) {
        self.capturedAt = capturedAt
        self.timeZoneID = timeZoneID
        self.reports = reports
        self
            .allReports = allReports
        historyFormatVersion = 4
        self.historyReconciledAt = historyReconciledAt ?? capturedAt
        self.historyPricingVersion = historyPricingVersion
    }

    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return c
    }

    public func metrics(_ period: LedgerPeriod, now: Date = Date()) -> UsageMetrics {
        guard period == .all || calendar.isDate(capturedAt, equalTo: now, toGranularity: .month)
        else { return .unavailable }
        guard period != .today || calendar.isDate(capturedAt, inSameDayAs: now) else { return .unavailable }
        let selected = period == .all ? (allReports ?? []) : reports
        let value = UsageMetrics
            .combined(["claude", "codex"].map { id in selected.first(where: { $0.provider == id })?.metrics(
                period,
                now: now,
                calendar: calendar
            ) ?? .unavailable })
        return UsageMetrics(
            tokens: value.tokens,
            cost: value.cost,
            partial: value
                .partial || (period == .all && historyPricingVersion != Self.currentHistoryPricingVersion)
        )
    }

    public static func decodeEngine(_ data: Data) throws -> [ProviderReport] {
        let reports = try JSONDecoder().decode([ProviderReport].self, from: data)
            .filter { ["claude", "codex"].contains($0.provider) }
        guard Set(reports.map(\.provider)).count == reports.count,
              !reports.isEmpty else { throw LedgerError.invalidReport }
        return reports
    }
}

public enum LedgerError: Error { case missingEngine, invalidReport, timedOut, failed, archiveUnreadable }

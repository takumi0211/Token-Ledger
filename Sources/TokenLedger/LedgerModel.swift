import AppKit
import LedgerCore
import Observation
import OSLog
import SwiftUI

@MainActor @Observable final class LedgerModel {
    var snapshot: UsageSnapshot?
    var period: LedgerPeriod = .today {
        didSet { changed?() }
    }

    var refreshing = false
    var failed = false
    var quotaReadings: [QuotaReading] = []
    var quotaFailed = Set<String>()
    var quotaRefreshing = false
    @ObservationIgnored var changed: (() -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let engine: CodexBarEngine
    @ObservationIgnored private let cache: URL
    @ObservationIgnored private let quotaCache: URL
    @ObservationIgnored private let quotaEngine: QuotaEngine
    @ObservationIgnored private var quotaTimer: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var nextHistoryAttempt = Date.distantPast
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.takumi0211.TokenLedger", category: "Refresh")
    init() {
        engine = CodexBarEngine(executable: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CodexBarCLI"))
        quotaEngine = QuotaEngine(executable: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CodexBarCLI"))
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenLedger")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        cache = directory.appendingPathComponent("usage.json")
        quotaCache = directory.appendingPathComponent("limits.json")
        if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(
            UsageSnapshot.self,
            from: data
        ), cached.historyFormatVersion == 4 {
            snapshot = cached
        }
        if let data = try? Data(contentsOf: quotaCache), let cached = try? JSONDecoder().decode(
            [QuotaReading].self,
            from: data
        ) {
            quotaReadings = cached
        }
    }

    var total: UsageMetrics {
        snapshot?.metrics(period) ?? .unavailable
    }

    var reports: [ProviderReport] {
        guard let snapshot else { return [] }
        if period == .all {
            return snapshot.allReports ?? []
        }
        guard snapshot.calendar.isDate(snapshot.capturedAt, equalTo: Date(), toGranularity: .month) else { return [] }
        guard period != .today || snapshot.calendar.isDate(snapshot.capturedAt, inSameDayAs: Date()) else { return [] }
        return ["claude", "codex"].compactMap { id in snapshot.reports.first(where: { $0.provider == id }) }
    }

    var status: String {
        if refreshing {
            return "Refreshing…"
        }
        if failed {
            return snapshot == nil ? "Couldn't read history" : "Cached · refresh failed"
        }
        guard let snapshot else { return "Reading local history…" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return "Updated " + f.string(from: snapshot.capturedAt)
    }

    func start() {
        timer = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                await self?.refresh()
            }
        }
        quotaTimer = Task { [weak self] in
            await self?.refreshQuotas()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                await self?.refreshQuotas()
            }
        }
    }

    func refreshNow() {
        Task { await refresh(forceRefresh: true) }
        Task { await refreshQuotas() }
    }

    private func refreshQuotas() async {
        guard !quotaRefreshing else { return }
        quotaRefreshing = true
        defer { quotaRefreshing = false }
        let results = await quotaEngine.load()
        quotaFailed = Set(results.filter { $0.reading == nil }.map(\.provider))
        var latest = Dictionary(quotaReadings.map { ($0.provider, $0) }, uniquingKeysWith: { _, new in new })
        for result in results {
            if let reading = result.reading {
                latest[result.provider] = reading
            }
        }
        quotaReadings = ["claude", "codex"].compactMap { latest[$0] }
        if let data = try? JSONEncoder().encode(quotaReadings) {
            try? data.write(to: quotaCache, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quotaCache.path)
        }
    }

    func refresh(forceRefresh: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        changed?()
        defer { refreshing = false
            changed?()
        }
        do {
            let zone = TimeZone.current
            let value = try await engine.loadSnapshot(
                timeZoneID: zone.identifier,
                previous: snapshot,
                forceRefresh: forceRefresh
            )
            try publish(value)
            reconcileHistoryIfNeeded(timeZoneID: zone.identifier)
        } catch {
            failed = true
            logger.error("Current usage refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func publish(_ value: UsageSnapshot) throws {
        let latest = try snapshot?.acceptingRefresh(value) ?? value
        let data = try JSONEncoder().encode(latest)
        try data.write(to: cache, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
        snapshot = latest
        failed = (latest.reports + (latest.allReports ?? [])).contains { !$0.available }
        changed?()
    }

    private func reconcileHistoryIfNeeded(timeZoneID: String) {
        guard historyTask == nil, Date() >= nextHistoryAttempt,
              snapshot?.needsHistoryReconciliation(now: Date()) == true else { return }
        // All and Month use separate upstream stores. A slow archive catch-up must
        // not hold the visible refresh open or stop the one-minute current scan.
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer { historyTask = nil
                nextHistoryAttempt = Date().addingTimeInterval(1800)
            }
            do {
                let full = try await engine.loadSnapshot(timeZoneID: timeZoneID)
                guard snapshot?.timeZoneID == timeZoneID else { return }
                guard full.canUpdateCurrentMonth(now: full.capturedAt, timeZoneID: timeZoneID)
                else { throw LedgerError.invalidReport }
                try publish(full)
            } catch {
                // Preserve the last complete baseline and the fresh monthly rows.
                logger.error("Historical reconciliation deferred: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

import Darwin
import Foundation

public actor CodexBarEngine {
    private let executable: URL
    private let timeout: TimeInterval
    private let history: CodexHistoryProjection
    private let claudeHistory: ClaudeHistoryProjection
    private var fullyScanned = Set<Bool>()
    public func loadSnapshot(
        timeZoneID: String,
        previous: UsageSnapshot? = nil,
        forceRefresh: Bool = false
    ) async throws -> UsageSnapshot {
        // A user refresh must bypass the helper's scan debounce even when this
        // process has already established complete history coverage.
        if forceRefresh {
            fullyScanned.removeAll()
        }
        if let previous, previous.canUpdateCurrentMonth(now: Date(), timeZoneID: timeZoneID) {
            let month = try await load()
            return try previous.updatingCurrentMonth(month, now: Date())
        }
        let all = try await load(allTime: true)
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return UsageSnapshot(
            capturedAt: now,
            timeZoneID: timeZoneID,
            reports: all.map { $0.monthToDate(now: now, calendar: calendar) },
            allReports: all
        )
    }

    public init(
        executable: URL,
        timeout: TimeInterval = 600,
        historySource: URL? = nil,
        historyDestination: URL? = nil,
        archiveLibrary: URL? = nil,
        claudeHistorySource: URL? = nil
    ) {
        self.executable = executable
        self.timeout = timeout
        let home = FileManager.default.homeDirectoryForCurrentUser
        let source = historySource ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        history = CodexHistoryProjection(
            source: source,
            destination: historyDestination ?? home
                .appendingPathComponent(
                    "Library/Application Support/TokenLedger/CodexHistory-v2"
                ),
            library: archiveLibrary ?? executable.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Frameworks/libzstd.1.dylib")
        )
        claudeHistory = ClaudeHistoryProjection(
            source: claudeHistorySource ??
                URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home
                    .appendingPathComponent(".claude").path),
            destination: (historyDestination?.deletingLastPathComponent() ?? home
                .appendingPathComponent("Library/Application Support/TokenLedger"))
                .appendingPathComponent("ClaudeHistory-v1")
        )
    }

    public func load(allTime: Bool = false) async throws -> [ProviderReport] {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else { throw LedgerError.missingEngine }
        try claudeHistory.prepare()
        let manifest = history.destination.appendingPathComponent("projection-v1.json")
        let previousStamp = (try? fm.attributesOfItem(atPath: manifest.path)[.modificationDate]) as? Date
        let historyHome = try history.prepare()
        let nextStamp = (try? fm.attributesOfItem(atPath: manifest.path)[.modificationDate]) as? Date
        if previousStamp != nextStamp {
            fullyScanned.removeAll()
        }
        // The upstream CLI scans Codex in bounded slices. Do not publish a cold archive
        // scan's first slice as an all-time total; continue until its coverage is established.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let reports = try await read(
                allTime: allTime,
                historyHome: historyHome,
                claudeHome: claudeHistory.destination
            )
            if let codex = reports.first(where: { $0.provider == "codex" }), codex.error == nil,
               codex.historyCoverageIsEstablished == true
            {
                return reports
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw LedgerError.timedOut
    }

    private func read(allTime: Bool, historyHome: URL, claudeHome: URL) async throws -> [ProviderReport] {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("token-ledger-\(UUID().uuidString)")
        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.json"),
            errors = directory.appendingPathComponent("stderr.log")
        let config = directory.appendingPathComponent("config.json")
        // Isolate upstream's persistent ledger by period. A monthly scan must not
        // prune or reuse a half-populated all-history cache (or the user's CodexBar cache).
        let engineHome = history.destination.deletingLastPathComponent()
            .appendingPathComponent("EngineHome-v3-speed/\(allTime ? "All" : "Month")")
        try fm.createDirectory(
            at: engineHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for file in [output, errors] {
            fm.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        fm.createFile(
            atPath: config.path,
            contents: Data(#"{"version":1,"providers":[{"id":"claude","enabled":true},{"id":"codex","enabled":true}]}"#
                .utf8),
            attributes: [.posixPermissions: 0o600]
        )
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close()
            try? err.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "cost",
            "--provider",
            "both",
            "--period",
            allTime ? "all" : "month-to-date",
            "--format",
            "json",
            "--provider-native-only",
        ]
        if !fullyScanned.contains(allTime) {
            process.arguments?.append("--refresh")
        }
        // Isolate provider configuration: no API keys, browser cookies, or inference calls.
        var environment = [
            "HOME": engineHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TZ": TimeZone.current.identifier,
            "TMPDIR": fm.temporaryDirectory.path,
            "CODEXBAR_CONFIG": config.path,
        ]
        environment["CODEX_HOME"] = historyHome.path
        environment["CFFIXED_USER_HOME"] = engineHome.path
        environment["CLAUDE_CONFIG_DIR"] = claudeHome.path
        process.environment = environment
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw LedgerError.timedOut }
                let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 16 * 1024 * 1024 else { throw LedgerError.invalidReport }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw error
        }
        // isRunning is already false. A second synchronous wait can strand this
        // cooperative worker in Foundation's run loop after the child has exited.
        try out.close()
        try err.close()
        let data = try Data(contentsOf: output)
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw LedgerError.failed }
        // CodexBar may exit nonzero with a useful partial, provider-specific JSON report.
        let reports = try UsageSnapshot.decodeEngine(data)
        if reports.first(where: { $0.provider == "codex" })?
            .historyCoverageIsEstablished == true
        {
            fullyScanned.insert(allTime)
        }
        return reports
    }
}

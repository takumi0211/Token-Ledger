import Darwin
import Foundation

public struct QuotaReading: Codable, Sendable, Identifiable {
    public let provider: String
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date?
    public let capturedAt: Date
    public var id: String {
        provider
    }

    public func remainingPercent(now: Date = Date()) -> Double? {
        guard usedPercent.isFinite, (0 ... 100).contains(usedPercent),
              now.timeIntervalSince(capturedAt) >= -60, now.timeIntervalSince(capturedAt) <= 900,
              resetsAt.map({ $0 > now }) ?? true else { return nil }
        return 100 - usedPercent
    }

    public func resetCountdown(now: Date = Date()) -> String? {
        guard remainingPercent(now: now) != nil, let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds < 60 {
            return "<1m"
        }
        let minutes = Int(ceil(seconds / 60))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 {
            return "\(rest)m"
        }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    public static func decode(_ data: Data, provider: String, now: Date = Date()) throws -> QuotaReading {
        struct Window: Decodable { let usedPercent: Double
            let windowMinutes: Int?
            let resetsAt: String?
        }
        struct Usage: Decodable {
            let primary: Window?
            let secondary: Window?
            let tertiary: Window?
            let updatedAt: String?
        }
        struct Payload: Decodable { let provider: String
            let usage: Usage?
        }
        let payloads = try JSONDecoder().decode([Payload].self, from: data)
        guard let usage = payloads.first(where: { $0.provider == provider })?.usage,
              let minutes = ["claude": 300, "codex": 10080][provider] else { throw LedgerError.invalidReport }
        func date(_ string: String) -> Date? {
            let f = ISO8601DateFormatter()
            if let value = f.date(from: string) {
                return value
            }
            f.formatOptions.insert(.withFractionalSeconds)
            return f.date(from: string)
        }
        // Window order varies by account/plan. Select by duration, never by position.
        guard let window = [usage.primary, usage.secondary, usage.tertiary].compactMap({ $0 })
            .first(where: { $0.windowMinutes == minutes }),
            window.usedPercent.isFinite, (0 ... 100).contains(window.usedPercent),
            window.resetsAt == nil || date(window.resetsAt!) != nil else { throw LedgerError.invalidReport }
        let captured = usage.updatedAt.flatMap(date) ?? now
        let reading = QuotaReading(
            provider: provider,
            usedPercent: window.usedPercent,
            windowMinutes: minutes,
            resetsAt: window.resetsAt.flatMap(date),
            capturedAt: captured
        )
        guard reading.remainingPercent(now: now) != nil else { throw LedgerError.invalidReport }
        return reading
    }
}

public struct QuotaFetchResult: Sendable {
    public let provider: String
    public let reading: QuotaReading?
}

/// Explicit native sources only: Codex OAuth and Claude Code's /usage CLI probe.
/// Reads existing sign-ins without browser-cookie discovery or model inference.
public actor QuotaEngine {
    private let executable: URL
    public init(executable: URL) {
        self.executable = executable
    }

    public func load() async -> [QuotaFetchResult] {
        await withTaskGroup(of: QuotaFetchResult.self) { group in
            for provider in ["claude", "codex"] {
                group.addTask { await self.fetch(provider) }
            }
            var results: [QuotaFetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func fetch(_ provider: String) async -> QuotaFetchResult {
        do { return try await QuotaFetchResult(provider: provider, reading: read(provider)) }
        catch { return QuotaFetchResult(provider: provider, reading: nil) }
    }

    private func read(_ provider: String) async throws -> QuotaReading {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("ledger-quota-\(UUID().uuidString)")
        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: directory) }
        let output = directory.appendingPathComponent("usage.json"),
            error = directory.appendingPathComponent("error.log")
        let config = directory.appendingPathComponent("config.json")
        try Data(#"{"version":1,"providers":[{"id":"claude","enabled":true},{"id":"codex","enabled":true}]}"#.utf8)
            .write(to: config)
        for file in [output, error] {
            fm.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: error)
        defer { try? out.close()
            try? err.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "usage",
            "--provider",
            provider,
            "--source",
            provider == "codex" ? "oauth" : "cli",
            "--no-credits",
            "--format",
            "json",
        ]
        let home = fm.homeDirectoryForCurrentUser
        var environment = ["HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": "/bin/zsh",
                           "TMPDIR": fm.temporaryDirectory.path, "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
                           "PATH": home.appendingPathComponent(".local/bin")
                               .path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "CODEXBAR_CONFIG": config.path]
        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                environment[key] = value
            }
        }
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let binary = candidates
            .first(where: { fm.isExecutableFile(atPath: $0) })
        {
            environment["CLAUDE_CLI_PATH"] = binary
        }
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardOutput = out
        process.standardError = err
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(40)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw LedgerError.timedOut }
                let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 1024 * 1024 else { throw LedgerError.invalidReport }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw error
        }
        // The asynchronous polling above has already observed termination.
        try out.close()
        try err.close()
        let data = try Data(contentsOf: output)
        guard process.terminationStatus == 0, data.count <= 1024 * 1024 else { throw LedgerError.failed }
        return try QuotaReading.decode(data, provider: provider)
    }
}

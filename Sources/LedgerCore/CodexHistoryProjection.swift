import ArchiveReader
import Foundation

/// Format adapter only. CodexBar still owns token attribution, fork deduplication and prices.
/// One blank line replaces each discarded conversation row, preserving physical fork indices.
public struct CodexHistoryProjection: Sendable {
    private static let needles = [
        "\"session_meta\"",
        "\"turn_context\"",
        "\"token_usage_record\"",
        "\"inter_agent_communication_metadata\"",
        "\"token_count\"",
        "\"task_started\"",
        "\"task_complete\"",
        "\"thread_settings_applied\"",
        "\"usage\"",
    ].map { Data($0.utf8) }
    public let source: URL
    public let destination: URL
    public let library: URL
    private struct Stamp: Codable, Equatable { let size: Int64
        let modified: Double
    }

    public init(source: URL, destination: URL, library: URL) {
        self.source = source.resolvingSymlinksInPath()
        self.destination = destination.resolvingSymlinksInPath()
        self
            .library = library.resolvingSymlinksInPath()
    }

    public func prepare() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(
            at: self.destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = destination.resolvingSymlinksInPath()
        let manifestURL = destination.appendingPathComponent("projection-v1.json")
        let previous = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(
            [String: Stamp].self,
            from: $0
        ) } ?? [:]
        var manifest = previous
        var expected = Set<String>()
        for root in ["sessions", "archived_sessions"] {
            let base = source.appendingPathComponent(root)
            let output = destination.appendingPathComponent(root)
            try fm.createDirectory(
                at: output,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let files = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in files {
                try Task.checkCancellation()
                let compressed = file.lastPathComponent.hasSuffix(".jsonl.zst")
                guard compressed || file.pathExtension == "jsonl" else { continue }
                // A live plain rollout wins over a compressed copy of the same logical file.
                if compressed, fm.fileExists(atPath: file.deletingPathExtension().path) {
                    continue
                }
                let relative = String(Self.logicalPath(file).dropFirst(base.path.count + 1))
                let key = root + "/" + (compressed ? String(relative.dropLast(4)) : relative)
                expected.insert(key)
                let target = destination.appendingPathComponent(key)
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if !compressed {
                    let link = try? fm.destinationOfSymbolicLink(atPath: target.path)
                    let original = try fm.attributesOfItem(atPath: file.path)
                    let current = try? fm.attributesOfItem(atPath: target.path)
                    let sameFile = link == nil && (current?[.systemFileNumber] as? NSNumber) ==
                        (original[.systemFileNumber] as? NSNumber)
                        && (current?[.systemNumber] as? NSNumber) == (original[.systemNumber] as? NSNumber)
                    if !sameFile {
                        if current != nil || link != nil {
                            try fm.removeItem(at: target)
                        }
                        // CodexBar rejects symlinks outside its scan roots. A read-only consumer
                        // can share the original inode without copying growing live rollouts.
                        try fm.linkItem(at: file, to: target)
                    }
                    continue
                }
                let attrs = try fm.attributesOfItem(atPath: file.path)
                let stamp = Stamp(
                    size: (attrs[.size] as? NSNumber)?.int64Value ?? -1,
                    modified: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                )
                manifest[key] = stamp
                if previous[key] == stamp, fm.fileExists(atPath: target.path),
                   (try? fm.destinationOfSymbolicLink(atPath: target.path)) == nil
                {
                    continue
                }
                try project(file, to: target)
            }
        }
        // Keep observed usage after source cleanup. Remove an old location only after
        // its same-named rollout has been successfully prepared at a new location.
        let activeNames = Set(expected.map { URL(fileURLWithPath: $0).lastPathComponent })
        for root in ["sessions", "archived_sessions"] {
            let output = destination.appendingPathComponent(root)
            if let existing = fm.enumerator(at: output, includingPropertiesForKeys: nil) {
                for case let file as URL in existing where file.pathExtension == "jsonl" {
                    let key = String(Self.logicalPath(file).dropFirst(destination.path.count + 1))
                    if !expected.contains(key), activeNames.contains(file.lastPathComponent) {
                        try fm.removeItem(at: file)
                        manifest.removeValue(forKey: key)
                    }
                }
            }
        }
        if manifest != previous || !fm.fileExists(atPath: manifestURL.path) {
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        return destination
    }

    private static func logicalPath(_ url: URL) -> String {
        // FileManager can enumerate /private/var while Foundation represents its parent as /var.
        // Resolve the parent only, so cleanup never follows an adapter-owned symlink.
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    private func project(_ input: URL, to target: URL) throws {
        guard let reader = ledger_archive_open(input.path, library.path) else { throw LedgerError.archiveUnreadable }
        defer { ledger_archive_close(reader) }
        let fm = FileManager.default,
            temporary = target.deletingLastPathComponent().appendingPathComponent(".projection-\(UUID().uuidString)")
        fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var buffer = Data(), pointer: UnsafePointer<UInt8>?
        while true {
            try Task.checkCancellation()
            let count = ledger_archive_next(reader, &pointer)
            guard count >= 0 else { throw LedgerError.archiveUnreadable }
            if count == 0 {
                break
            }
            let projected = try autoreleasepool { try Self.usageLine(Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer!),
                count: count,
                deallocator: .none
            )) }
            buffer.append(projected ?? Data([10]))
            if buffer
                .count >= 256 * 1024
            {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()
        // rename atomically replaces an old symlink or projection without following it.
        guard rename(temporary.path, target.path) == 0 else { throw LedgerError.archiveUnreadable }
    }

    public static func usageLine(_ data: Data) throws -> Data? {
        // Cheap byte prefilter avoids parsing large conversation/tool rows.
        guard needles.contains(where: { data.range(of: $0) != nil }) else { return nil }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LedgerError.archiveUnreadable }
        let type = object["type"] as? String
        var payload = object["payload"] as? [String: Any] ?? [:]
        let keys: Set<String>
        switch type {
        case "session_meta":
            keys = [
                "id",
                "session_id",
                "sessionId",
                "timestamp",
                "cwd",
                "source",
                "originator",
                "model",
                "model_provider",
                "cli_version",
                "forked_from_id",
                "forkedFromId",
                "parent_session_id",
                "parentSessionId",
                "history_base",
                "historyBase",
                "subagent_history_start_ordinal",
                "creator_account_id",
            ]
        case "turn_context":
            keys = [
                "model",
                "model_name",
                "info",
                "cwd",
                "current_working_directory",
                "currentWorkingDirectory",
                "turn_id",
                "turnId",
                "effort",
            ]
        case "event_msg":
            guard ["token_count", "task_started", "task_complete", "thread_settings_applied"]
                .contains(payload["type"] as? String ?? "") else { return nil }
            keys = [
                "type",
                "info",
                "model",
                "turn_id",
                "turnId",
                "thread_settings",
                "duration_ms",
                "started_at",
                "time_to_first_token_ms",
                "error",
            ]
        case "token_usage_record":
            keys = [
                "thread_id",
                "session_id",
                "response_id",
                "turn_id",
                "turnId",
                "model",
                "usage",
                "thread_token_usage",
                "turn_token_usage",
                "service_tier",
            ]
        case "inter_agent_communication_metadata": keys = ["trigger_turn"]
        case nil:
            let wrappers = ["data", "result", "response"]
            guard object["usage"] is [String: Any] || wrappers
                .contains(where: { (object[$0] as? [String: Any])?["usage"] is [String: Any] }) else { return nil }
            for key in wrappers {
                if let value = object[key] as? [String: Any] {
                    object[key] = value.filter { [
                        "model",
                        "model_name",
                        "usage",
                    ].contains($0.key) }
                }
            }
            object = object
                .filter {
                    (["timestamp", "model", "model_name", "usage", "id", "response_id", "ordinal"] + wrappers)
                        .contains($0.key)
                }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
        default: return nil
        }
        payload = payload.filter { keys.contains($0.key) }
        object = object
            .filter { ["type", "timestamp", "model", "id", "session_id", "sessionId", "ordinal"].contains($0.key) }
        object["payload"] = payload
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
    }
}

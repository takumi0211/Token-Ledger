import ArchiveReader
import Foundation

/// Retains content-free Claude usage rows after the original transcripts are removed.
public struct ClaudeHistoryProjection: Sendable {
    public let source: URL
    public let destination: URL
    private struct Stamp: Codable, Equatable { let size: Int64
        let modified: Double
    }

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    public func prepare() throws {
        let fm = FileManager.default, root = source.appendingPathComponent("projects")
        let projects = destination.appendingPathComponent("projects")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifestURL = destination.appendingPathComponent("manifest-v1.json")
        var manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(
            [String: Stamp].self,
            from: $0
        ) } ?? [:]
        let previous = manifest
        if let files = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let file as URL in files where file.pathExtension == "jsonl" {
                try Task.checkCancellation()
                let logicalFile = file.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(file.lastPathComponent)
                let logicalRoot = root.resolvingSymlinksInPath()
                let relative = String(logicalFile.path.dropFirst(logicalRoot.path.count + 1))
                let target = projects.appendingPathComponent(relative)
                let attrs = try fm.attributesOfItem(atPath: file.path)
                let stamp = Stamp(
                    size: (attrs[.size] as? NSNumber)?.int64Value ?? -1,
                    modified: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                )
                if manifest[relative] == stamp, fm.fileExists(atPath: target.path) {
                    continue
                }
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try project(file, to: target)
                manifest[relative] = stamp
            }
        }
        if previous != manifest || !fm.fileExists(atPath: manifestURL.path) {
            try Self.write(
                JSONEncoder().encode(manifest),
                to: manifestURL
            )
        }
    }

    private func project(_ input: URL, to target: URL) throws {
        guard let reader = ledger_plain_open(input.path) else { throw LedgerError.archiveUnreadable }
        defer { ledger_archive_close(reader) }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".usage-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var pointer: UnsafePointer<UInt8>?, buffer = Data()
        while true {
            try Task.checkCancellation()
            let count = ledger_archive_next(reader, &pointer)
            guard count >= 0 else { throw LedgerError.archiveUnreadable }
            if count == 0 {
                break
            }
            let row = try autoreleasepool { () throws -> Data? in
                let data = Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer!),
                    count: count,
                    deallocator: .none
                )
                do { return try Self.usageLine(data) }
                catch {
                    if data.last != 10 {
                        return nil
                    }
                    throw error
                }
            }
            if let row {
                buffer.append(row)
            }
            if buffer
                .count > 256 * 1024
            {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()
        guard rename(temporary.path, target.path) == 0 else { throw LedgerError.archiveUnreadable }
    }

    public static func usageLine(_ data: Data) throws -> Data? {
        guard data.range(of: Data("\"usage\"".utf8)) != nil else { return nil }
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              decoded["type"] as? String == "assistant",
              var message = decoded["message"] as? [String: Any], message["usage"] is [String: Any] else { return nil }
        var row = decoded.filter { [
            "type",
            "timestamp",
            "requestId",
            "sessionId",
            "session_id",
            "isSidechain",
            "uuid",
            "provider",
            "apiProvider",
        ].contains($0.key) }
        message = message.filter { ["id", "model", "usage", "stop_reason"].contains($0.key) }
        row["message"] = message
        return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

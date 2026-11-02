import Foundation
import Testing

func brewPrefix() throws -> URL {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["brew", "--prefix", "zstd"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadNoSuchFile) }
    return URL(fileURLWithPath: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

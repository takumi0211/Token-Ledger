import AppKit
import SwiftUI

enum Palette {
    static let ink = Color(red: 0.92, green: 0.91, blue: 0.87)
    static let muted = Color(red: 0.55, green: 0.55, blue: 0.52)
    static let accent = Color(red: 0.79, green: 0.76, blue: 0.65)
}

@MainActor enum ProviderAssets {
    private static let images: [String: NSImage] = Dictionary(uniqueKeysWithValues: ["claude", "codex"].map { id in
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(id).png")
        return (id, NSImage(contentsOf: url) ?? NSImage(size: NSSize(width: 27, height: 27)))
    })

    static func logo(_ id: String) -> NSImage {
        images[id] ?? NSImage(size: NSSize(width: 27, height: 27))
    }
}

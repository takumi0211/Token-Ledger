import AppKit
import QuartzCore
import SwiftUI

/// Compositor-driven rotation stays smooth without re-rendering the ledger each frame.
struct RefreshGlyph: NSViewRepresentable {
    let isRefreshing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context _: Context) -> RefreshIconView {
        RefreshIconView()
    }

    func updateNSView(_ view: RefreshIconView, context _: Context) {
        let layer = view.glyph
        if isRefreshing, !reduceMotion {
            guard layer.animation(forKey: "refresh") == nil else { return }
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = -Double.pi * 2
            rotation.duration = 0.85
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(rotation, forKey: "refresh")
        } else {
            layer.removeAnimation(forKey: "refresh")
        }
    }
}

final class RefreshIconView: NSView {
    let glyph = CALayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyph.contents = Self.image()
        glyph.contentsScale = 2
        glyph.contentsGravity = .resizeAspect
        layer?.addSublayer(glyph)
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.bounds = CGRect(origin: .zero, size: bounds.size)
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    private static func image() -> CGImage? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        else { return nil }
        bitmap.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.draw(in: NSRect(x: 1, y: 1, width: 14, height: 14))
        NSColor(red: 0.79, green: 0.76, blue: 0.65, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill(using: .sourceIn)
        return bitmap.cgImage
    }
}

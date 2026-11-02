import AppKit

@MainActor enum TokenGlyph {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            NSColor.black.setStroke()
            let brackets = NSBezierPath()
            brackets.lineWidth = 1.6
            brackets.lineCapStyle = .round
            brackets.lineJoinStyle = .round
            brackets.move(to: NSPoint(x: 4.2, y: 3.4))
            brackets.line(to: NSPoint(x: 1.3, y: 7))
            brackets.line(to: NSPoint(x: 4.2, y: 10.6))
            brackets.move(to: NSPoint(x: 9.8, y: 3.4))
            brackets.line(to: NSPoint(x: 12.7, y: 7))
            brackets.line(to: NSPoint(x: 9.8, y: 10.6))
            brackets.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.9, y: 5.9, width: 2.2, height: 2.2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Token usage"
        return image
    }()
}

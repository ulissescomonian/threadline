import AppKit

/// A macOS template glyph: two distinct conversation cards joined by one
/// continuous thread. Its geometry is intentionally asymmetric so it cannot
/// read as an infinity mark or as a radio/antenna status icon.
@MainActor
enum ThreadlineMenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            context.shouldAntialias = true
            NSColor.black.setStroke()

            // The thread sits behind both cards and terminates cleanly at their
            // edges. A shallow S curve survives both 1x and 2x rasterization.
            let thread = NSBezierPath()
            thread.lineWidth = 1.3
            thread.lineCapStyle = .round
            thread.move(to: NSPoint(x: 7.7, y: 10.2))
            thread.curve(
                to: NSPoint(x: 10.3, y: 7.8),
                controlPoint1: NSPoint(x: 8.8, y: 9.9),
                controlPoint2: NSPoint(x: 9.2, y: 8.1)
            )
            thread.stroke()

            drawConversationCard(
                in: NSRect(x: 1.25, y: 9.25, width: 7, height: 5.5),
                messageLineY: 12
            )
            drawConversationCard(
                in: NSRect(x: 9.75, y: 3.25, width: 7, height: 5.5),
                messageLineY: 6
            )

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Threadline"
        return image
    }()

    private static func drawConversationCard(in rect: NSRect, messageLineY: CGFloat) {
        let card = NSBezierPath(roundedRect: rect, xRadius: 1.8, yRadius: 1.8)
        card.lineWidth = 1.35
        card.lineCapStyle = .round
        card.lineJoinStyle = .round
        card.stroke()

        let message = NSBezierPath()
        message.lineWidth = 1.15
        message.lineCapStyle = .round
        message.move(to: NSPoint(x: rect.minX + 2, y: messageLineY))
        message.line(to: NSPoint(x: rect.maxX - 2, y: messageLineY))
        message.stroke()
    }
}

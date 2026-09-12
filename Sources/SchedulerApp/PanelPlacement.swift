import AppKit

enum PanelPlacement {
    static func frame(size: NSSize, anchor: NSPoint?, screens: [NSRect], fallback: NSRect) -> NSRect {
        let anchor = anchor.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        let screen = anchor.flatMap { point in screens.first { $0.contains(NSPoint(x: point.x, y: point.y - 1)) } }
        let visible = screen ?? fallback
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        let origin: NSPoint
        if let anchor, screen != nil { origin = NSPoint(x: anchor.x, y: anchor.y - height) }
        else { origin = NSPoint(x: visible.midX - width / 2, y: visible.minY + (visible.height - height) * 0.6) }
        return NSRect(x: min(max(origin.x, visible.minX), visible.maxX - width),
                      y: min(max(origin.y, visible.minY), visible.maxY - height), width: width, height: height)
    }
}

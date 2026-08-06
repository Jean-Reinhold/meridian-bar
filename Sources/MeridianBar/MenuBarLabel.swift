import AppKit

/// Renders the collapsed label as a non-template NSImage so per-segment
/// color survives the menu bar (okf/02 §1, okf/03 risk R1). The drawing
/// handler runs at display time, so dynamic NSColors adapt to light/dark.
enum MenuBarLabel {
    static let fontSize: CGFloat = 12
    static let barHeight: CGFloat = 22

    static func render(segments: [ProfileSegment], offline: Bool) -> NSImage {
        let text = attributedText(segments: segments, offline: offline)
        let size = text.size()
        let image = NSImage(
            size: NSSize(width: ceil(size.width), height: barHeight),
            flipped: false
        ) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    static func attributedText(segments: [ProfileSegment], offline: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let boldFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)

        if offline || segments.isEmpty {
            return NSAttributedString(
                string: offline ? "meridian ⏻" : "meridian …",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }

        let out = NSMutableAttributedString()
        for (i, seg) in segments.enumerated() {
            if i > 0 {
                out.append(NSAttributedString(string: " · ", attributes: [
                    .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: seg.isActive ? boldFont : font,
                .foregroundColor: color(for: seg.status),
            ]
            if seg.isActive { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            let number = seg.percent.map(String.init) ?? "–"
            out.append(NSAttributedString(string: "\(seg.alias) \(number)", attributes: attrs))
        }
        return out
    }

    static func color(for status: UsageStatus) -> NSColor {
        switch status {
        case .ok: .labelColor
        case .warn: .systemYellow
        case .critical, .blocked: .systemRed
        }
    }
}

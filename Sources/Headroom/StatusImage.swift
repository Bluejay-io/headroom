import AppKit

enum StatusImage {
    static func make(states: [Provider: ProviderState]) -> NSImage {
        let logo: CGFloat = 14, barWidth: CGFloat = 22, gap: CGFloat = 4, spacing: CGFloat = 9
        let unit = logo + gap + barWidth
        let width = unit * CGFloat(Provider.allCases.count) + spacing * CGFloat(Provider.allCases.count - 1)
        let size = NSSize(width: width, height: 18)

        return NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for (index, provider) in Provider.allCases.enumerated() {
                let x = CGFloat(index) * (unit + spacing)
                let state = states[provider] ?? ProviderState()
                let dim = state.windows.isEmpty
                let logoRect = CGRect(x: x, y: (size.height - logo) / 2, width: logo, height: logo)
                context.addPath(Logo.fitted(Logo.path(for: provider), in: logoRect, flipY: true))
                context.setFillColor(NSColor.labelColor.withAlphaComponent(dim ? 0.35 : 1).cgColor)
                context.fillPath(using: .evenOdd)

                let barX = x + logo + gap
                let bars = state.barWindows
                if bars.isEmpty {
                    drawBar(context, x: barX, y: 7.5, fraction: 0, color: .clear)
                    continue
                }
                if bars.count == 1 {
                    drawBar(context, x: barX, y: 7.5, fraction: bars[0].leftPercent / 100, color: color(for: bars[0], primary: true))
                } else {
                    drawBar(context, x: barX, y: 10.5, fraction: bars[0].leftPercent / 100, color: color(for: bars[0], primary: true))
                    drawBar(context, x: barX, y: 4.5, fraction: bars[1].leftPercent / 100, color: color(for: bars[1], primary: false))
                }
            }
            return true
        }

        func drawBar(_ context: CGContext, x: CGFloat, y: CGFloat, fraction: Double, color: NSColor) {
            let track = CGRect(x: x, y: y, width: barWidth, height: 3)
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.22).cgColor)
            context.addPath(CGPath(roundedRect: track, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
            let fill = CGRect(x: x, y: y, width: max(0, barWidth * fraction), height: 3)
            guard fill.width > 0 else { return }
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: fill, cornerWidth: min(1.5, fill.width / 2), cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
    }

    private static func color(for window: LimitWindow, primary: Bool) -> NSColor {
        switch window.status() {
        case .low: return .systemRed
        case .behind: return primary ? .systemOrange : NSColor.labelColor.withAlphaComponent(0.85)
        case .fine: return NSColor.labelColor.withAlphaComponent(0.85)
        }
    }
}

import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    static func write(to directory: URL) async {
        let store = UsageStore()
        await store.refresh()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let status = StatusImage.make(states: store.states)
                let scale: CGFloat = 4
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(status.size.width * scale), pixelsHigh: Int(status.size.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = status.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                status.draw(in: NSRect(origin: .zero, size: status.size))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menubar-\(name).png"))
            }
            let panel = PanelView(store: store)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: panel)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("panel-\(name).png"))
            }
        }
    }
}

import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                await Snapshot.write(to: directory)
                exit(0)
            }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.setAccessibilityLabel("Headroom")

        let host = NSHostingController(rootView: PanelView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        store.$states
            .receive(on: RunLoop.main)
            .sink { [weak self] states in self?.render(states) }
            .store(in: &cancellables)
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render(self?.store.states ?? [:]) }
            .store(in: &cancellables)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.render(self?.store.states ?? [:]) }
            .store(in: &cancellables)

        store.start()
    }

    private func render(_ states: [Provider: ProviderState]) {
        statusItem.button?.image = StatusImage.make(states: states)
        let tip = Provider.allCases.map { provider -> String in
            let windows = states[provider]?.windows ?? []
            let parts = windows.map { "\($0.label) \(Int($0.leftPercent))%" }
            return "\(provider.name): " + (parts.isEmpty ? "–" : parts.joined(separator: ", "))
        }
        statusItem.button?.toolTip = tip.joined(separator: "\n")
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

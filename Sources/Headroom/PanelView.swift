import SwiftUI

struct PanelView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Provider.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider().padding(.vertical, 12) }
                ProviderSection(provider: provider, state: store.states[provider] ?? ProviderState())
            }
            Divider().padding(.top, 12).padding(.bottom, 8)
            Footer(store: store)
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct ProviderSection: View {
    let provider: Provider
    let state: ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LogoShape(provider: provider)
                    .fill(provider.brandColor, style: FillStyle(eoFill: true))
                    .frame(width: 15, height: 15)
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = state.plan {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if let error = state.error {
                ErrorCard(message: error, lastSeen: state.updatedAt)
            } else if let retryAt = state.retryAt, state.windows.isEmpty {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    ErrorCard(message: retryAt > context.date
                        ? "Signed in. Claude's usage service is rate limiting right now, so your numbers will show \(Format.reset(retryAt, now: context.date)). Refresh tries again sooner."
                        : "Signed in. Checking Claude now…", lastSeen: nil)
                }
            }
            if state.loading && state.windows.isEmpty {
                ForEach(0..<2, id: \.self) { _ in LimitRow.placeholder }
            } else {
                ForEach(state.windows) { window in
                    LimitRow(window: window).opacity(state.error == nil ? 1 : 0.5)
                }
            }
        }
    }
}

private struct ErrorCard: View {
    let message: String
    let lastSeen: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message).font(.system(size: 12))
            if let lastSeen {
                Text("Showing data from \(Format.ago(lastSeen).replacingOccurrences(of: "Updated ", with: ""))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.quaternary))
    }
}

private struct LimitRow: View {
    let window: LimitWindow
    @State private var hovering = false

    static var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 90, height: 10)
            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 6)
        }
        .redacted(reason: .placeholder)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let status = window.status(now: context.date)
            let pace = window.paceLeftPercent(now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(window.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(window.leftPercent.rounded()))% left")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(status == .low ? Color.red : Color.primary)
                }
                Bar(left: window.leftPercent, pace: pace, color: color(status))
                HStack {
                    Text(hovering ? "Resets \(Format.exact(window.resetsAt))" : "Resets \(Format.reset(window.resetsAt, now: context.date))")
                    Spacer()
                    if let pace {
                        Text(hovering ? "Even pace: \(Int(pace.rounded()))% left" : (status == .fine ? "on pace" : "faster than pace"))
                            .foregroundStyle(status == .fine ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func color(_ status: LimitStatus) -> Color {
        switch status {
        case .low: return .red
        case .behind: return .orange
        case .fine: return .accentColor
        }
    }
}

private struct Bar: View {
    let left: Double
    let pace: Double?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * left / 100)
                if let pace {
                    Rectangle().fill(.primary)
                        .frame(width: 1.5, height: 12)
                        .offset(x: geo.size.width * pace / 100 - 0.75)
                }
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.4), value: left)
    }
}

private struct Footer: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(spacing: 12) {
                Text(Format.ago(store.lastUpdated, now: context.date))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await store.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.refreshing ? 360 : 0))
                        .animation(store.refreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.refreshing)
                }
                .help("Refresh")
                Menu {
                    Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                    Toggle("Notify when a limit is low", isOn: $store.notificationsEnabled)
                    Picker("Low means under", selection: $store.alertThreshold) {
                        ForEach([10.0, 20.0, 30.0], id: \.self) { Text("\(Int($0))% left").tag($0) }
                    }
                    Divider()
                    Button("Show Welcome…") { NotificationCenter.default.post(name: .showOnboarding, object: nil) }
                    Button("Quit Headroom") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

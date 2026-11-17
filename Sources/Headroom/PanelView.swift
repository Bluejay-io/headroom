import SwiftUI

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Provider.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider().padding(.vertical, 12) }
                ProviderSection(provider: provider, state: store.states[provider] ?? ProviderState(), store: store)
            }
            if let version = updater.available {
                UpdateBanner(version: version, updater: updater).padding(.top, 14)
            }
            Divider().padding(.top, 12).padding(.bottom, 8)
            Footer(store: store, updater: updater)
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct ProviderSection: View {
    let provider: Provider
    let state: ProviderState
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LogoShape(provider: provider)
                    .fill(provider.brandColor, style: FillStyle(eoFill: true))
                    .frame(width: 15, height: 15)
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                if state.resetCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "ticket").font(.system(size: 10))
                        Text("\(state.resetCount)").font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                    .help("\(state.resetCount) reset\(state.resetCount == 1 ? "" : "s") you can use")
                }
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
            if !state.resets.isEmpty || state.resetNote != nil {
                ResetsList(provider: provider, state: state, store: store)
            }
        }
    }
}

private struct ResetsList: View {
    let provider: Provider
    let state: ProviderState
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.resets) { option in
                if store.confirming == option.id {
                    ConfirmCard(provider: provider, option: option, store: store)
                } else {
                    row(option)
                }
            }
            if let note = state.resetNote {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if context.date.timeIntervalSince(note.at) < 600 {
                        Label(note.text, systemImage: note.good ? "checkmark.circle.fill" : "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(note.good ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func row(_ option: ResetOption) -> some View {
        let low = state.windows.contains { $0.status() == .low }
        return HStack(spacing: 6) {
            Image(systemName: "ticket").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(option.title).font(.system(size: 12))
            Text(summary(option)).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 4)
            if state.claiming == option.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Use…") { store.confirming = option.id }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(low ? .accentColor : nil)
                    .disabled(state.claiming != nil)
            }
        }
        .help(option.detail)
    }

    private func summary(_ option: ResetOption) -> String {
        var parts = ["\(option.count) left"]
        if let expires = option.expiresAt {
            parts.append("until " + expires.formatted(.dateTime.day().month(.abbreviated)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ConfirmCard: View {
    let provider: Provider
    let option: ResetOption
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use one \(provider.name) \(option.title)?")
                .font(.system(size: 12, weight: .semibold))
            Text("\(option.detail) You'll have \(option.count - 1) left. This can't be undone.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { store.confirming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Use reset") { Task { await store.useReset(provider, option) } }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

private struct UpdateBanner: View {
    let version: String
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text(updater.installing ? "Updating to \(version)… Headroom will reopen." : "Headroom \(version) is available.")
                .font(.system(size: 12))
            Spacer()
            if updater.installing {
                ProgressView().controlSize(.small)
            } else {
                Button("Update") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
    @ObservedObject var updater: Updater

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
                    Button("Check for Updates") { Task { await updater.check() } }
                    Text("Headroom \(updater.current)" + (updater.available == nil && updater.checkedAt != nil ? " (up to date)" : ""))
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

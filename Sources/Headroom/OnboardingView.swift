import AppKit
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, connect, permissions, ready
}

struct OnboardingView: View {
    @ObservedObject var store: UsageStore
    let finish: () -> Void
    @AppStorage("onboardingStep") private var stepRaw = 0

    private var step: OnboardingStep { OnboardingStep(rawValue: stepRaw) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch step {
                case .welcome: WelcomePage()
                case .connect: ConnectPage(store: store)
                case .permissions: PermissionsPage(store: store, advance: advance)
                case .ready: ReadyPage(store: store)
                }
            }
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24))))
            .id(step)
            Spacer(minLength: 0)
            controls
            dots.padding(.top, 18)
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 560, height: 460)
        .background(.background)
        .animation(.spring(duration: 0.45), value: stepRaw)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button("Back") { stepRaw -= 1 }
                    .controlSize(.large)
            }
            Button(primaryTitle) {
                if step == .ready { finish() } else { advance() }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .connect: return "Continue"
        case .permissions: return "Continue"
        case .ready: return "Open Headroom"
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item == step ? Color.primary : Color.primary.opacity(0.15))
                    .frame(width: item == step ? 16 : 6, height: 6)
            }
        }
    }

    private func advance() {
        stepRaw = min(stepRaw + 1, OnboardingStep.ready.rawValue)
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(width: 420)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct Row<Icon: View, Trailing: View>: View {
    @ViewBuilder let icon: Icon
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct Done: View {
    let label: String
    var body: some View {
        Label(label, systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.green)
            .transition(.scale.combined(with: .opacity))
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            PageHeader(title: "Welcome to Headroom",
                       subtitle: "Your Claude and Codex limits, always in the menu bar. Headroom reads the logins you already have and never changes them.")
        }
    }
}

private struct ConnectPage: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(title: "Connect your tools",
                       subtitle: "Headroom uses the Claude Code and Codex logins already on this Mac. Nothing to type here.")
            Card {
                row(.claude, missing: "Run claude in Terminal and log in")
                Divider()
                row(.codex, missing: "Run codex login in Terminal")
            }
            Text("You only need one of them. Headroom keeps checking in the background.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .task { await store.refresh() }
    }

    private func row(_ provider: Provider, missing: String) -> some View {
        let state = store.states[provider] ?? ProviderState()
        let connected = store.isConnected(provider)
        return Row(icon: {
            LogoShape(provider: provider).fill(provider.brandColor, style: FillStyle(eoFill: true))
        }, title: provider == .claude ? "Claude Code" : "Codex", detail: connected
            ? (state.windows.isEmpty ? "Signed in · your numbers will show in a few minutes" : "Signed in" + (state.plan.map { " · \($0) plan" } ?? ""))
            : (state.loading || store.refreshing ? "Checking…" : (state.error ?? missing)),
        trailing: {
            if connected {
                Done(label: "Connected")
            } else if state.loading || store.refreshing {
                ProgressView().controlSize(.small)
            } else {
                Button("Check again") { Task { await store.refresh(force: true) } }
            }
        })
        .animation(.spring(duration: 0.35), value: connected)
    }
}

private struct PermissionsPage: View {
    @ObservedObject var store: UsageStore
    let advance: () -> Void
    @AppStorage("didSetUpLaunchAtLogin") private var didSetUpLaunchAtLogin = false
    @State private var advanced = false

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(title: "Stay in the loop",
                       subtitle: "Headroom can warn you before a limit runs out and start with your Mac, so it's always there.")
            Card {
                Row(icon: { Image(systemName: "bell.badge").font(.system(size: 16)).foregroundStyle(.secondary) },
                    title: "Notifications",
                    detail: "When a limit drops under \(Int(store.alertThreshold))% and when it resets",
                    trailing: { notificationControl })
                Divider()
                Row(icon: { Image(systemName: "power").font(.system(size: 16)).foregroundStyle(.secondary) },
                    title: "Launch at login",
                    detail: "Start Headroom when you log in",
                    trailing: {
                        Toggle("", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    })
            }
        }
        .animation(.spring(duration: 0.35), value: store.notificationStatus)
        .task {
            if !didSetUpLaunchAtLogin {
                didSetUpLaunchAtLogin = true
                store.launchAtLogin = true
            }
            await store.refreshNotificationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshNotificationStatus() }
        }
    }

    @ViewBuilder private var notificationControl: some View {
        switch store.notificationStatus {
        case .authorized, .provisional:
            Done(label: "Allowed")
        case .denied:
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.bluejay.headroom")!)
            }
        default:
            Button("Allow") {
                Task {
                    await store.requestNotifications()
                    if store.notificationStatus == .authorized, !advanced {
                        advanced = true
                        try? await Task.sleep(for: .milliseconds(700))
                        advance()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct ReadyPage: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi").foregroundStyle(.secondary)
                Image(nsImage: StatusImage.make(states: store.states))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .frame(width: 420, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            PageHeader(title: "Headroom lives in your menu bar",
                       subtitle: "Look for the Claude and Codex logos near the clock. The top bar is your shortest window, the bottom one your weekly. Click it any time for the details.")
        }
    }
}

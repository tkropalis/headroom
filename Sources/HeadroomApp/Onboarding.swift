import AppKit
import HeadroomCore
import SwiftUI

/// First run, inside the popover: what Headroom does, Full Disk Access, then the first scan.
struct OnboardingScreen: View {
    @Environment(AppModel.self) private var model
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(step) of 3").font(.callout).foregroundStyle(.secondary)
            switch step {
            case 1: WelcomeStep()
            case 2: AccessStep()
            default: FirstScanStep()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

private struct WelcomeStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Headroom").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Point(symbol: "internaldrive", text: "Measures the folders on this Mac's disk and keeps one number in the menu bar.")
                Point(symbol: "checkmark", text: "Cleans only what you confirm, and says what each item costs before you do.")
                Point(symbol: "pause.circle", text: "Never touches what you are using: open apps and running dev servers are skipped.")
            }
            HStack {
                Spacer()
                Button("Continue") { model.screen = .onboarding(2) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct Point: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AccessStep: View {
    @Environment(AppModel.self) private var model
    @State private var granted = false
    @State private var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Full Disk Access").font(.title2.weight(.semibold))
            Text("With it, Headroom can measure every folder. Without it, Mail, Safari and some app data are skipped, so part of the disk goes uncounted.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Circle().fill(granted ? Color.green : waiting ? Color.accentColor : Color.orange).frame(width: 10, height: 10)
                Text(granted ? "Granted. Every folder can be measured." : waiting ? "Waiting for you to turn it on…" : "Off")
                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
            Text("In Privacy Settings, turn on Headroom under Full Disk Access. This screen notices when you do.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                if granted {
                    Button("Continue") { model.screen = .onboarding(3) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue Without It") { model.screen = .onboarding(3) }
                        .buttonStyle(.glass)
                    Button("Open Privacy Settings…") {
                        waiting = true
                        model.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { granted = model.hasFullDiskAccess }
        // Access can be granted at any moment in System Settings; check every second.
        .task {
            while !Task.isCancelled && !granted {
                try? await Task.sleep(for: .seconds(1))
                granted = model.hasFullDiskAccess
            }
        }
    }
}

private struct FirstScanStep: View {
    @Environment(AppModel.self) private var model
    @State private var login = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready for the first scan").font(.title2.weight(.semibold))
            Text("The first scan takes about a minute. Free space shows at once; the rest fills in as folders are measured.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open Headroom at login", isOn: $login)
                .toggleStyle(.switch)
                .padding(10)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
            Text("Scans only measure. Nothing is cleaned without you.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Start First Scan") {
                    if login != model.launchAtLogin { model.launchAtLogin = login }
                    model.finishOnboarding()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

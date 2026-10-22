import AppKit
import HeadroomCore
import SwiftUI

/// `Headroom --preview <main|review|review-identical|review-forgotten|result|growth|onboarding1…3|settings|history|spacemap|offload>` opens one screen in an ordinary window,
/// so it can be inspected or captured without clicking through the menu bar. Development only.
@MainActor
enum DevPreview {
    static var requested: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var windows: [NSWindow] = []

    static func show(_ screen: String, model: AppModel) {
        let root: AnyView
        switch screen {
        case "settings":
            root = AnyView(SettingsView().environment(model))
        case "history":
            // Sample data so the chart can be checked before the app has three days of readings.
            if model.freeSamples.count < 24 {
                let now = Date()
                model.freeSamples = (0..<(30 * 24)).map { hour in
                    let bytes = 31e9 - Double(hour) * 0.75e9 / 24 + (hour > 700 ? 10e9 : 0)
                    return FreeSample(date: now.addingTimeInterval(-Double(30 * 24 - hour) * 3600), available: Int64(bytes))
                }
            }
            root = AnyView(HistorySettings().environment(model).frame(width: 620, height: 600))
        case "spacemap":
            root = AnyView(SpaceMapView(model: model.spaceMap).environment(model).frame(width: 1000, height: 640))
        case "offload":
            let item = OffloadItem(path: Paths.home + "/.android/avd/Pixel_7.avd", name: "Pixel_7", bytes: 3_100_000_000, quit: [])
            root = AnyView(OffloadSheet(item: item) { _ in }.frame(width: 460))
        default:
            prepare(screen, model: model)
            root = AnyView(PopoverView().environment(model).background(.regularMaterial))
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "Headroom preview: \(screen)"
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        windows.append(window)
        try? String(window.windowNumber).write(toFile: NSTemporaryDirectory() + "headroom-preview-window",
                                              atomically: true, encoding: .utf8)
    }

    private static func prepare(_ screen: String, model: AppModel) {
        model.refreshProcesses()
        switch screen {
        case "review":
            model.openReview(.ready)
        case "review-yourcall":
            model.openReview(.yourCall)
        case "review-identical":
            model.openReview(.identical)
        case "review-forgotten":
            model.openReview(.forgotten)
        case "onboarding1", "onboarding2", "onboarding3":
            model.screen = .onboarding(Int(String(screen.last!))!)
        case "result":
            model.outcomes = [
                CleanupOutcome(id: "npm-cache", name: "npm download cache", state: .done, freed: 73_000_000, message: nil),
                CleanupOutcome(id: "spotify-cache", name: "Spotify cache", state: .done, freed: 412_000_000, message: nil),
                CleanupOutcome(id: "claude-vm", name: "Claude VM image", state: .done, freed: 0,
                               message: "Moved to the Bin. Empty the Bin to free the space.", inBin: true),
                CleanupOutcome(id: "x", name: "Developer tool caches", state: .failed, freed: 0,
                               message: "Couldn't remove ~/Library/Caches/dotslash."),
            ]
            model.screen = .result
        case "growth":
            let alert = GrowthAlert(path: Paths.userFolders + "/X/com.google.Chrome.code_sign_clone",
                                    previous: 0, current: 9_100_000_000,
                                    since: Date().addingTimeInterval(-26 * 3600), sharesSpace: true)
            model.growthAlerts = [alert]
            model.screen = .growth(alert)
        case "main-alert":
            model.growthAlerts = [GrowthAlert(path: Paths.userFolders + "/X/com.google.Chrome.code_sign_clone",
                                              previous: 0, current: 9_100_000_000,
                                              since: Date().addingTimeInterval(-26 * 3600), sharesSpace: true)]
            model.expandedGroup = .rebuilds
        default:
            break
        }
    }
}

import AppKit
import HeadroomCore
import SwiftUI

/// `Headroom --preview <main|review|result|growth|settings>` opens one screen in an ordinary window,
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

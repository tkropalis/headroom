import AppKit
import HeadroomCore
import SwiftUI

/// `Headroom --preview <main|review|review-identical|review-forgotten|result|growth|onboarding1…3|settings|history|spacemap|spacemap:<path>|claude|offload>` opens one screen in an ordinary window,
/// so it can be inspected or captured without clicking through the menu bar. Development only.
@MainActor
enum DevPreview {
    static var requested: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var windows: [NSWindow] = []

    static func show(_ screen: String, model: AppModel, openWindow: OpenWindowAction) {
        if screen == "spacemap" || screen.hasPrefix("spacemap:") {
            showSpaceMap(screen, model: model, openWindow: openWindow)
            return
        }
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
        case "claude":
            root = AnyView(ClaudeSettings().environment(model).frame(width: 560, height: 680))
        case "graphics":
            let names: [Graphic.Name] = [.ollie, .allClean, .access, .scan]
            let row = { (scheme: ColorScheme) in
                AnyView(HStack(spacing: 24) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        VStack(spacing: 10) {
                            Graphic(name: name, size: 64)
                            Graphic(name: name, size: 22)
                        }
                    }
                }
                .padding(24)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.96))
                .environment(\.colorScheme, scheme))
            }
            root = AnyView(VStack(spacing: 0) { row(.light); row(.dark) })
        case "offload":
            let item = OffloadItem(path: Paths.home + "/.android/avd/Pixel_7.avd", name: "Pixel_7", bytes: 3_100_000_000, quit: [])
            root = AnyView(OffloadSheet(item: item) { _ in }.frame(width: 460))
        default:
            prepare(screen, model: model)
            root = AnyView(PopoverView().environment(model).background(.regularMaterial))
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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

    /// The real Space Map window, so the sidebar and toolbar look as they do in use.
    /// `spacemap:<path>` opens the folder's parent with the folder selected, e.g. spacemap:~/Library/Caches/foo;
    /// `spacemap:kinds` opens the Kinds view; `spacemap:plan` adds a sample plan that is never saved.
    private static func showSpaceMap(_ screen: String, model: AppModel, openWindow: OpenWindowAction) {
        openWindow(id: "spacemap")
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if screen == "spacemap:kinds" {
                model.spaceMap.setLens(.kinds)
            } else if screen == "spacemap:plan" {
                // A sample plan from real folders, kept in memory only.
                let map = model.spaceMap
                map.savesPlan = false
                map.plan = CleanupPlan()
                map.go(.folder(Paths.home))
                let paths = ["~/.android", "~/Library/Android", "~/Library/Application Support/minecraft",
                             "~/Library/Caches/com.spotify.client"].map(Paths.expand)
                let rows = paths.compactMap { path -> SpaceNode? in
                    guard let snapshot = map.snapshot, FileManager.default.fileExists(atPath: path) else { return nil }
                    let bytes = SpaceTree.total(under: path, in: snapshot)
                    return SpaceNode(path: path, name: (path as NSString).lastPathComponent, allocated: bytes, unshared: bytes,
                                     isDirectory: true, kind: SpaceTree.kind(of: path, isDirectory: true))
                }
                map.addToPlan(rows)
                try? await Task.sleep(for: .milliseconds(300))
                map.selection = [Paths.expand("~/.android")]
            } else if screen.hasPrefix("spacemap:") {
                model.spaceMap.reveal(Paths.expand(String(screen.dropFirst("spacemap:".count))))
            }
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("spacemap") == true || $0.title == "Space Map" })
            else { return }
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
            try? String(window.windowNumber).write(toFile: NSTemporaryDirectory() + "headroom-preview-window",
                                                  atomically: true, encoding: .utf8)
        }
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
        case "helper":
            model.screen = .helper
        case let name where name.hasPrefix("ask:"):
            model.screen = .ask(Paths.expand(String(name.dropFirst(4))))
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

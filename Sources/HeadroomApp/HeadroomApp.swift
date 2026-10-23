import AppKit
import HeadroomCore
import SwiftUI

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Space Map", id: "spacemap") {
            SpaceMapWindow()
                .environment(model)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        // Only opens when asked for, never at launch or from a restored session.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// Review, cleaning and result, shown in the Space Map window instead of the popover.
struct FlowSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.screen {
            case .review: ReviewScreen()
            case .cleaning: CleaningScreen()
            case .result: ResultScreen()
            default: EmptyView()
            }
        }
        .padding(.vertical, 14)
        .frame(width: 400)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, even when run outside the app bundle.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The drive symbol and free space shown in the menu bar.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: DriveIcon.image(level: model.level))
            if model.menuDisplay != .iconOnly {
                Text(model.menuTitle).monospacedDigit()
            }
        }
        .accessibilityLabel("Headroom, \(model.disk.map { ByteFormat.string($0.available) } ?? "unknown") free")
        .task {
            if let screen = DevPreview.requested { DevPreview.show(screen, model: model, openWindow: openWindow) }
        }
    }
}

enum DriveIcon {
    /// Template image while healthy; an orange or red dot is drawn on top when space is low.
    @MainActor static func image(level: HeadroomLevel) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let symbol = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Disk")!
            .withSymbolConfiguration(config)!
        guard level != .ok else {
            symbol.isTemplate = true
            return symbol
        }
        let dotColor: NSColor = level == .critical ? .systemRed : .systemOrange
        let size = NSSize(width: symbol.size.width + 3, height: max(symbol.size.height, 15))
        let image = NSImage(size: size, flipped: false) { rect in
            // labelColor resolves against the menu bar's own appearance when drawn.
            let tinted = symbol.copy() as! NSImage
            tinted.lockFocus()
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: 0, y: (rect.height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            let dot = NSRect(x: rect.width - 7, y: rect.height - 7, width: 7, height: 7)
            dotColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

import Foundation

public enum CleanupLevel: String, Codable, Sendable, CaseIterable {
    /// Caches and build output; nothing is lost.
    case safe
    /// Nothing is lost, but the next build or launch is slower.
    case rebuilds
    /// Removing these loses something; they go to the Bin.
    case yourCall

    public var title: String {
        switch self {
        case .safe: "Safe"
        case .rebuilds: "Rebuilds on use"
        case .yourCall: "Your call"
        }
    }
}

/// An app that must be quit before its cache is cleaned.
public struct AppRef: Codable, Sendable, Hashable {
    public var name: String
    public var bundleID: String
    /// Apps you work in (editors, browsers). Their items start unticked.
    public var disruptive: Bool

    public init(_ name: String, _ bundleID: String, disruptive: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        self.disruptive = disruptive
    }
}

/// What a catalogue entry points at, resolved to concrete paths during a scan.
public enum Target: Sendable {
    /// Paths that are deleted whole when they exist.
    case paths([String])
    /// Entries directly inside a folder not modified for this many days.
    case oldChildren(String, days: Int)
    /// Files with an extension anywhere inside a folder, older than this many days.
    case oldFiles(String, ext: String, days: Int)
    /// The contents of a root-owned folder; needs the admin password.
    case adminContents(String)
    /// Docker's unused images and build cache, via the docker command.
    case docker
}

public enum Disposal: String, Codable, Sendable {
    case delete, trash
}

public struct CatalogEntry: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var level: CleanupLevel
    public var target: Target
    public var disposal: Disposal
    public var cost: String
    public var quit: [AppRef]
    /// Substrings of running command lines that make cleaning unsafe, with the reason shown.
    public var blockingProcesses: [(match: String, reason: String)]

    public init(_ id: String, _ name: String, _ level: CleanupLevel, _ target: Target,
                disposal: Disposal = .delete, cost: String, quit: [AppRef] = [],
                blockedBy: [(String, String)] = []) {
        self.id = id
        self.name = name
        self.level = level
        self.target = target
        self.disposal = disposal
        self.cost = cost
        self.quit = quit
        self.blockingProcesses = blockedBy.map { (match: $0.0, reason: $0.1) }
    }
}

public enum Apps {
    public static let spotify = AppRef("Spotify", "com.spotify.client")
    public static let stremio = AppRef("Stremio", "com.westbridge.stremio5-mac")
    public static let vscode = AppRef("VS Code", "com.microsoft.VSCode", disruptive: true)
    public static let firefox = AppRef("Firefox", "org.mozilla.firefox", disruptive: true)
    public static let chrome = AppRef("Google Chrome", "com.google.Chrome", disruptive: true)
    public static let tablePlus = AppRef("TablePlus", "com.tinyapp.TablePlus")
    public static let xcode = AppRef("Xcode", "com.apple.dt.Xcode", disruptive: true)
    public static let claude = AppRef("Claude", "com.anthropic.claudefordesktop", disruptive: true)
    public static let steam = AppRef("Steam", "com.valvesoftware.steam")
    public static let simulator = AppRef("Simulator", "com.apple.iphonesimulator")
}

/// The folders Headroom knows how to clean.
public enum Catalog {
    public static let builtIn: [CatalogEntry] = [
        // Safe: caches and build output.
        CatalogEntry("chrome-clones", "Chrome temporary copies", .safe,
                     .paths(["$FOLDERS/X/com.google.Chrome.code_sign_clone"]),
                     cost: "Nothing lost. Copies Chrome should have removed after updates.",
                     quit: [Apps.chrome]),
        CatalogEntry("npm-cache", "npm download cache", .safe,
                     .paths(["~/.npm/_cacache", "~/.npm/_npx"]),
                     cost: "Nothing lost. npm downloads packages again when needed."),
        CatalogEntry("yarn-cache", "Yarn cache", .safe,
                     .paths(["~/Library/Caches/Yarn"]),
                     cost: "Nothing lost. Yarn downloads packages again when needed."),
        CatalogEntry("spotify-cache", "Spotify cache", .safe,
                     .paths(["~/Library/Caches/com.spotify.client"]),
                     cost: "Nothing lost. Streamed songs load again; downloads stay.",
                     quit: [Apps.spotify]),
        CatalogEntry("stremio-cache", "Stremio streaming cache", .safe,
                     .paths(["~/Library/Application Support/stremio-server/stremio-cache"]),
                     cost: "Nothing lost. Buffered video from past streams.",
                     quit: [Apps.stremio]),
        CatalogEntry("vscode-cache", "VS Code caches and logs", .safe,
                     .paths(["~/Library/Application Support/Code/CachedExtensionVSIXs",
                             "~/Library/Application Support/Code/CachedData",
                             "~/Library/Application Support/Code/Cache",
                             "~/Library/Application Support/Code/logs"]),
                     cost: "Nothing lost. Settings and extensions stay.",
                     quit: [Apps.vscode]),
        CatalogEntry("firefox-cache", "Firefox cache", .safe,
                     .paths(["~/Library/Caches/Firefox", "~/Library/Caches/Mozilla"]),
                     cost: "Nothing lost. Logins, bookmarks and history stay.",
                     quit: [Apps.firefox]),
        CatalogEntry("tableplus-cache", "TablePlus cache", .safe,
                     .paths(["~/Library/Caches/com.tinyapp.TablePlus"]),
                     cost: "Nothing lost. Rebuilt when TablePlus opens.",
                     quit: [Apps.tablePlus]),
        CatalogEntry("metro-cache", "Metro bundler cache", .safe,
                     .paths(["$TMP/metro-cache"]),
                     cost: "Nothing lost. Rebuilt on the next Expo or React Native start.",
                     blockedBy: [("expo start", "An Expo dev server is running."),
                                 ("react-native start", "A Metro server is running.")]),
        CatalogEntry("dev-tool-caches", "Developer tool caches", .safe,
                     .paths(["~/Library/Caches/dotslash", "~/Library/Caches/pip",
                             "~/Library/Caches/typescript", "~/.cache/puppeteer"]),
                     cost: "Nothing lost. Each tool downloads or rebuilds what it needs."),
        CatalogEntry("homebrew-cache", "Homebrew downloads", .safe,
                     .paths(["~/Library/Caches/Homebrew"]),
                     cost: "Nothing lost. Installed packages stay."),
        CatalogEntry("xcode-derived", "Xcode build data", .safe,
                     .paths(["~/Library/Developer/Xcode/DerivedData"]),
                     cost: "Nothing lost. The next Xcode build takes longer.",
                     quit: [Apps.xcode]),

        // Rebuilds on use.
        CatalogEntry("gradle", "Gradle caches", .rebuilds,
                     .paths(["~/.gradle/caches", "~/.gradle/wrapper/dists"]),
                     cost: "The next Android build downloads what it needs.",
                     blockedBy: [("GradleDaemon", "A Gradle build is running.")]),
        CatalogEntry("docker", "Unused Docker images", .rebuilds, .docker,
                     cost: "Base images download again. Volumes and running containers stay."),
        CatalogEntry("simulator-caches", "iOS Simulator caches", .rebuilds,
                     .adminContents("/Library/Developer/CoreSimulator/Caches"),
                     cost: "Needs your password. The first simulator boot is slower.",
                     quit: [Apps.simulator]),
        CatalogEntry("cocoapods-cache", "CocoaPods cache", .rebuilds,
                     .paths(["~/Library/Caches/CocoaPods"]),
                     cost: "The next pod install downloads again."),
        CatalogEntry("vscode-workspaces", "Old VS Code workspace data", .rebuilds,
                     .oldChildren("~/Library/Application Support/Code/User/workspaceStorage", days: 60),
                     cost: "Folders not opened in 60 days lose their open tabs.",
                     quit: [Apps.vscode]),

        // Your call: these go to the Bin.
        CatalogEntry("claude-vm", "Claude VM image", .yourCall,
                     .paths(["~/Library/Application Support/Claude/vm_bundles"]),
                     disposal: .trash,
                     cost: "Downloads again the next time Claude needs it.",
                     quit: [Apps.claude]),
        CatalogEntry("claude-history", "Claude Code history over 60 days", .yourCall,
                     .oldFiles("~/.claude/projects", ext: "jsonl", days: 60),
                     disposal: .trash,
                     cost: "Old sessions can no longer be resumed."),
        CatalogEntry("minecraft", "Minecraft", .yourCall,
                     .paths(["~/Library/Application Support/minecraft"]),
                     disposal: .trash,
                     cost: "Worlds and saves go with it. Back them up first."),
        CatalogEntry("steam", "Steam games", .yourCall,
                     .paths(["~/Library/Application Support/Steam"]),
                     disposal: .trash,
                     cost: "Installed games go; they can be downloaded again.",
                     quit: [Apps.steam]),
        CatalogEntry("paradox", "Paradox games data", .yourCall,
                     .paths(["~/Library/Application Support/Paradox Interactive"]),
                     disposal: .trash,
                     cost: "Saves go with it. Back them up first."),
        CatalogEntry("mamp", "MAMP", .yourCall,
                     .paths(["/Applications/MAMP", "/Applications/MAMP PRO.app"]),
                     disposal: .trash,
                     cost: "Export its MySQL databases first."),
        CatalogEntry("huggingface", "Hugging Face models", .yourCall,
                     .paths(["~/.cache/huggingface"]),
                     disposal: .trash,
                     cost: "Models download again if a project needs them."),
    ]

    public static func entry(_ id: String) -> CatalogEntry? {
        builtIn.first { $0.id == id }
    }
}

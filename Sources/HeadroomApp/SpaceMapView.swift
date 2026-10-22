import AppKit
import HeadroomCore
import Observation
import SwiftUI

enum SpaceSidebarItem: Hashable {
    case all
    case category(String)
    case offloaded
}

/// State for the Space Map window: what is listed, where you have drilled to, and what is selected.
@MainActor @Observable
final class SpaceMapModel {
    var snapshot: FolderSnapshot? = Store.snapshots().last
    var disk: DiskStatus? = DiskStatus.current()
    var sidebar: SpaceSidebarItem = .all {
        didSet { guard sidebar != oldValue else { return }; stack = []; forwardStack = []; reload() }
    }
    /// Folders drilled into, below the sidebar selection's top level.
    var stack: [String] = []
    var forwardStack: [String] = []
    var nodes: [SpaceNode] = []
    var measuring = false
    var selection: String?
    var search = ""
    /// Rows still being measured; they show "Measuring…" until their size arrives.
    var pending: Set<String> = []
    var measuredAt: Date?

    // Hooks the app sets.
    @ObservationIgnored var candidateFor: (String) -> Candidate? = { _ in nil }
    @ObservationIgnored var blockerFor: (String) -> String? = { _ in nil }
    @ObservationIgnored var offloadBlocker: (String) -> String? = { _ in nil }
    @ObservationIgnored var onClean: (Candidate) -> Void = { _ in }
    @ObservationIgnored var onOffload: (SpaceNode) -> Void = { _ in }
    @ObservationIgnored var onTrash: (SpaceNode) -> Void = { _ in }
    @ObservationIgnored var offloadedView: () -> AnyView = {
        AnyView(ContentUnavailableView("Nothing offloaded", systemImage: "externaldrive",
                                       description: Text("Things you offload to a drive or an archive appear here.")))
    }
    @ObservationIgnored var hasFullDiskAccess: () -> Bool = { true }
    @ObservationIgnored var openFullDiskAccess: () -> Void = {}

    @ObservationIgnored private var cache: [String: [SpaceNode]] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    static let unmeasuredPath = "headroom:unmeasured"

    init() {
        measuredAt = snapshot?.date
        reload()
    }

    // MARK: Derived

    var categories: [SpaceCategory] {
        guard let snapshot, let disk else { return [] }
        return SpaceTree.categories(snapshot: snapshot, disk: disk)
    }

    var unmeasured: Int64 {
        guard let snapshot, let disk else { return 0 }
        return SpaceTree.unmeasured(snapshot: snapshot, disk: disk)
    }

    var currentPath: String? { stack.last }

    var visibleNodes: [SpaceNode] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nodes }
        return nodes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var selectedNode: SpaceNode? { nodes.first { $0.path == selection } }

    var largest: Int64 { max(1, visibleNodes.map(\.allocated).max() ?? 1) }

    var rootTitle: String {
        switch sidebar {
        case .all: "Macintosh HD"
        case .category(let name): name
        case .offloaded: "Offloaded"
        }
    }

    // MARK: Navigation

    func open(_ node: SpaceNode) {
        guard node.isDirectory, node.path != Self.unmeasuredPath else { return }
        forwardStack = []
        stack.append(node.path)
        reload()
    }

    func back() {
        guard let last = stack.popLast() else { return }
        forwardStack.append(last)
        reload()
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        stack.append(next)
        reload()
    }

    /// Jumps to a breadcrumb: 0 is the sidebar selection's top level.
    func goTo(depth: Int) {
        guard depth < stack.count else { return }
        forwardStack = []
        stack = Array(stack.prefix(depth))
        reload()
    }

    var canGoBack: Bool { !stack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: Loading

    func reload() {
        loadTask?.cancel()
        selection = nil
        search = ""
        guard let path = currentPath else { loadTopLevel(); return }

        if let cached = cache[path] {
            nodes = cached
            pending = []
        } else {
            // Show the names at once; sizes fill in when measuring finishes.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            nodes = names.map { name in
                let child = path + "/" + name
                let known = snapshot?.sizes[child] ?? 0
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: child, isDirectory: &isDir)
                return SpaceNode(path: child, name: name, allocated: known, unshared: known, isDirectory: isDir.boolValue)
            }.sorted { $0.allocated > $1.allocated }
            pending = Set(nodes.map(\.path))
        }

        measuring = true
        loadTask = Task { [weak self] in
            let measured = await SpaceTree.children(of: path)
            guard let self, !Task.isCancelled, self.currentPath == path else { return }
            self.cache[path] = measured
            self.nodes = measured
            self.pending = []
            self.measuring = false
            self.measuredAt = Date()
        }
    }

    private func loadTopLevel() {
        pending = []
        measuring = false
        guard let snapshot else { nodes = []; return }
        switch sidebar {
        case .offloaded:
            nodes = []
        case .all:
            var rows = SpaceTree.topLevel(snapshot: snapshot, category: nil)
            if unmeasured > 0 {
                rows.insert(SpaceNode(path: Self.unmeasuredPath, name: "Not measured", allocated: unmeasured,
                                      unshared: unmeasured, isDirectory: false), at: 0)
            }
            nodes = rows
        case .category(let name):
            nodes = SpaceTree.topLevel(snapshot: snapshot, category: name)
        }
    }

    /// Forgets measurements, for example after something was cleaned or offloaded.
    func refresh() {
        cache = [:]
        snapshot = Store.snapshots().last
        disk = DiskStatus.current()
        reload()
    }

    /// Takes a row away at once, after it was moved to the Bin or offloaded.
    func removeNode(_ path: String) {
        nodes.removeAll { $0.path == path }
        for key in cache.keys { cache[key]?.removeAll { $0.path == path } }
        if selection == path { selection = nil }
    }

    func icon(for node: SpaceNode) -> NSImage {
        if let cached = icons[node.path] { return cached }
        let image = node.path == Self.unmeasuredPath
            ? NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil) ?? NSImage()
            : NSWorkspace.shared.icon(forFile: node.path)
        icons[node.path] = image
        return image
    }

    func sizeText(_ node: SpaceNode) -> String {
        if pending.contains(node.path) { return "Measuring…" }
        let text = ByteFormat.string(node.allocated)
        return node.sharesSpace ? "up to " + text : text
    }
}

// MARK: - Window

struct SpaceMapView: View {
    @Bindable var model: SpaceMapModel
    @State private var showInspector = true
    @FocusState private var searchFocused: Bool

    init(model: SpaceMapModel) { self.model = model }

    var body: some View {
        NavigationSplitView {
            SpaceSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                if model.sidebar == .offloaded {
                    model.offloadedView()
                } else {
                    SpaceTable(model: model)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SpaceStatusBar(model: model) }
            .inspector(isPresented: $showInspector) {
                SpaceInspector(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 260, max: 320)
            }
        }
        .navigationTitle(model.rootTitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.back() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back")
                Button { model.forward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Forward")
            }
            ToolbarItem(placement: .principal) { SpacePathBar(model: model) }
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help(showInspector ? "Hide details" : "Show details")
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search this folder")
        .searchFocused($searchFocused)
        .background {
            // ⌘F puts the cursor in the search field, as in Finder.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .frame(minWidth: 760, idealWidth: 1000, minHeight: 460, idealHeight: 640)
    }
}

struct SpaceSidebar: View {
    @Bindable var model: SpaceMapModel

    var body: some View {
        let selection = Binding<SpaceSidebarItem?>(get: { model.sidebar }, set: { if let value = $0 { model.sidebar = value } })
        List(selection: selection) {
            SidebarRow(title: "Macintosh HD", symbol: "internaldrive", bytes: model.disk?.used)
                .tag(SpaceSidebarItem.all)
            Section("Categories") {
                ForEach(model.categories) { category in
                    SidebarRow(title: category.name == SpaceTree.otherCategory ? "Other" : category.name, symbol: Self.symbol(for: category.name), bytes: category.bytes)
                        .tag(SpaceSidebarItem.category(category.name))
                }
            }
            Section {
                SidebarRow(title: "Offloaded", symbol: "externaldrive", bytes: nil)
                    .tag(SpaceSidebarItem.offloaded)
            }
        }
        .listStyle(.sidebar)
    }

    static func symbol(for category: String) -> String {
        switch category {
        case "Developer": "hammer"
        case "Docker": "shippingbox"
        case "Claude": "bubble.left"
        case "Caches": "archivebox"
        case "Apps": "app"
        case "Projects": "folder"
        default: "gearshape"
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let bytes: Int64?

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let bytes {
                Text(ByteFormat.string(bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

/// Breadcrumbs for the current folder; each one is a button that goes back to it.
struct SpacePathBar: View {
    @Bindable var model: SpaceMapModel

    var body: some View {
        let crumbs = [model.rootTitle] + model.stack.map { ($0 as NSString).lastPathComponent }
        // Long paths keep the root and the last three folders.
        let shown: [(Int, String)] = crumbs.count > 4
            ? [(0, crumbs[0])] + crumbs.enumerated().suffix(3).map { ($0.offset, $0.element) }
            : crumbs.enumerated().map { ($0.offset, $0.element) }
        HStack(spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { position, crumb in
                if position > 0 {
                    Image(systemName: crumb.0 - shown[position - 1].0 > 1 ? "ellipsis" : "chevron.compact.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Button(crumb.1) { model.goTo(depth: crumb.0) }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .fontWeight(crumb.0 == crumbs.count - 1 ? .semibold : .regular)
                    .foregroundStyle(crumb.0 == crumbs.count - 1 ? Color.primary : .secondary)
                    .disabled(crumb.0 == crumbs.count - 1)
            }
        }
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }
}

struct SpaceTable: View {
    @Bindable var model: SpaceMapModel

    var body: some View {
        let largest = model.largest
        Table(model.visibleNodes, selection: $model.selection) {
            TableColumn("Name") { node in
                HStack(spacing: 6) {
                    Image(nsImage: model.icon(for: node))
                        .resizable().frame(width: 16, height: 16)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(node.path == SpaceMapModel.unmeasuredPath ? .secondary : .primary)
                }
            }
            TableColumn("Kind") { node in
                if let kind = node.kind { KindLabel(kind: kind) }
            }
            .width(min: 80, ideal: 100, max: 130)
            TableColumn("Last opened") { node in
                Text(node.lastOpened.map(RelativeDate.shortDate) ?? "–")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110, max: 130)
            TableColumn("Size") { node in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.sizeText(node))
                        .monospacedDigit()
                        .foregroundStyle(model.pending.contains(node.path) ? .secondary : .primary)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, 90 * Double(node.allocated) / Double(largest)), height: 3)
                        .frame(width: 90, alignment: .leading)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 110, ideal: 120, max: 150)
        }
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { paths in
            // Double-click or Return opens a folder.
            if let path = paths.first, let node = model.nodes.first(where: { $0.path == path }) { model.open(node) }
        }
        .overlay {
            if model.visibleNodes.isEmpty && !model.measuring {
                if model.search.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                } else {
                    ContentUnavailableView.search(text: model.search)
                }
            }
        }
    }
}

struct KindLabel: View {
    let kind: SpaceKind

    var body: some View {
        Text(kind.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: .capsule)
    }
}

struct SpaceStatusBar: View {
    let model: SpaceMapModel

    var body: some View {
        HStack(spacing: 8) {
            if model.measuring {
                ProgressView().controlSize(.small)
                Text("Measuring…")
            } else if let line {
                Text(line)
            }
            Spacer()
            if let disk = model.disk {
                Text("\(ByteFormat.string(disk.available)) free")
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var line: String? {
        guard let disk = model.disk else { return nil }
        let when = model.measuredAt.map { "Measured " + RelativeDate.string($0) } ?? "Not measured yet"
        let accounted = max(0, disk.used - model.unmeasured)
        return "\(when) · \(ByteFormat.string(accounted)) of \(ByteFormat.string(disk.used)) used accounted for"
    }
}

// MARK: - Inspector

struct SpaceInspector: View {
    let model: SpaceMapModel
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node = model.selectedNode {
                    if node.path == SpaceMapModel.unmeasuredPath {
                        unmeasured(node)
                    } else {
                        details(node)
                    }
                } else {
                    Text("Select an item to see what Headroom knows about it.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func details(_ node: SpaceNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.name).font(.headline).lineLimit(3)
            Text(Paths.display(node.path))
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text(model.sizeText(node)).font(.title2.weight(.semibold)).monospacedDigit()
            if node.sharesSpace {
                Text("Deleting this gives back about \(ByteFormat.string(node.reclaimable)); the rest is shared with copies elsewhere.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let date = node.lastOpened {
                Text("Last opened \(RelativeDate.shortDate(date))").font(.callout).foregroundStyle(.secondary)
            }
        }

        let candidate = model.candidateFor(node.path)
        VStack(alignment: .leading, spacing: 4) {
            Text("What Headroom knows").font(.subheadline.weight(.semibold))
            if let candidate {
                Text(candidate.name)
                Text(candidate.cost).foregroundStyle(.secondary)
            } else {
                Text(Self.knowledge(node.kind)).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))

        actions(node, candidate: candidate)
    }

    @ViewBuilder private func actions(_ node: SpaceNode, candidate: Candidate?) -> some View {
        let blocker = model.blockerFor(node.path)
        let offloadReason = blocker ?? model.offloadBlocker(node.path)
        let trashReason: String? = !PathSafety.isDeletable(node.path)
            ? "Headroom never moves this folder to the Bin."
            : blocker

        VStack(alignment: .leading, spacing: 8) {
            if let candidate {
                if let blocker {
                    Reason(text: blocker)
                } else {
                    Button("Clean…") { model.onClean(candidate) }
                        .buttonStyle(.glassProminent)
                }
            }

            if let offloadReason {
                Reason(text: offloadReason)
            } else if candidate == nil {
                Button("Offload…") { model.onOffload(node) }.buttonStyle(.glassProminent)
            } else {
                Button("Offload…") { model.onOffload(node) }.buttonStyle(.glass)
            }

            if let trashReason {
                if trashReason != blocker && trashReason != offloadReason { Reason(text: trashReason) }
            } else {
                Button("Move to Bin") { confirmTrash = true }
                    .buttonStyle(.glass)
                    .confirmationDialog("Move \(node.name) to the Bin?", isPresented: $confirmTrash) {
                        Button("Move to Bin") { model.onTrash(node) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Empty the Bin to free \(ByteFormat.string(node.reclaimable)). Until then you can put it back.")
                    }
            }

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            }
            .buttonStyle(.glass)
        }
    }

    @ViewBuilder private func unmeasured(_ node: SpaceNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not measured").font(.headline)
            Text(ByteFormat.string(node.allocated)).font(.title2.weight(.semibold)).monospacedDigit()
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Space in use that no folder in the last measurement accounts for:")
            Label("About \(ByteFormat.string(DiskStatus.otherVolumesBytes())) is macOS itself: its system, startup and recovery volumes, which no app can clean.",
                  systemImage: "apple.logo")
            Label("System data Headroom can't read, such as macOS's own caches and logs.", systemImage: "gearshape")
            Label("Purgeable space, such as Time Machine snapshots, which macOS frees on its own when the disk runs low.",
                  systemImage: "clock.arrow.circlepath")
            Label("Folders skipped without Full Disk Access.", systemImage: "lock")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if !model.hasFullDiskAccess() {
            Button("Open Privacy Settings…") { model.openFullDiskAccess() }
                .buttonStyle(.glassProminent)
        }
    }

    static func knowledge(_ kind: SpaceKind?) -> String {
        switch kind {
        case .cache: "A cache Headroom knows. Its contents come back when needed."
        case .buildOutput: "Build output. Rebuilt on the next build."
        case .dependencies: "Installed packages. The package manager installs them again when needed."
        case .project: "A code project. Its dependencies and build output can go when you aren't working on it."
        case .appData: "Data an app keeps. Quit the app before moving it."
        case .app: "An application."
        case .emulator: "An Android emulator, with its apps, data and snapshots."
        case .simulator: "An iOS simulator and the test apps installed in it."
        case .forgotten: "Not opened for 6 months."
        case nil: "Headroom doesn't know what this is. Look inside before removing it."
        }
    }
}

private struct Reason: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

import AppKit
import HeadroomCore
import SwiftUI

/// What the Space Map needs from the app to ask Claude about a row.
struct ClaudeHooks {
    var ready: () -> Bool = { false }
    var answer: (String) -> Explanation? = { _ in nil }
    var asking: (String) -> Bool = { _ in false }
    var error: (String) -> String? = { _ in nil }
    var ask: (SpaceNode, _ refresh: Bool) -> Void = { _, _ in }
    var setOnList: (String, Bool) -> Void = { _, _ in }
    /// Haiku's first guess, written without being asked.
    var guess: (String) -> String? = { _ in nil }
    var requestGuess: (SpaceNode) -> Void = { _ in }
}

/// The inspector's Claude section, for rows Headroom has no cleanup rule for.
struct ClaudeAnswerView: View {
    let node: SpaceNode
    let hooks: ClaudeHooks
    /// Off where another note from Ollie already says what the folder is.
    var showGuess = true

    var body: some View {
        if let answer = hooks.answer(node.path) {
            AnswerBox(answer: answer, node: node, hooks: hooks)
        } else if Explainer.privacyBlocker(node.path) != nil {
            EmptyView()
        } else if !hooks.ready() {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Helper.name) can explain folders Headroom doesn't know.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Set Up \(Helper.name)…") }
                    .buttonStyle(.glass)
            }
            .font(.callout)
        } else if hooks.asking(node.path) {
            Asking()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if showGuess, let guess = hooks.guess(node.path) {
                    Label(guess, systemImage: "text.bubble")
                        .fixedSize(horizontal: false, vertical: true)
                        .help("\(Helper.name)'s first guess")
                }
                if let error = hooks.error(node.path) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(hooks.guess(node.path) == nil ? "Ask \(Helper.name) What This Is" : "Ask \(Helper.name) for Details") {
                    hooks.ask(node, false)
                }
                .buttonStyle(.glass)
                Text("Sends its path, its size, and the names and sizes of what's inside to Anthropic. Never file contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            // A first guess comes on its own once the selection settles.
            .task(id: node.path) {
                guard showGuess else { return }
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { hooks.requestGuess(node) }
            }
        }
    }
}

private struct Asking: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Asking \(Helper.name)…")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct AnswerBox: View {
    let answer: Explanation
    let node: SpaceNode
    let hooks: ClaudeHooks

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("What \(Helper.name) says").font(.subheadline.weight(.semibold))
                Spacer()
                VerdictBadge(verdict: answer.verdict)
            }
            Text(answer.name).fontWeight(.medium)
            Text(answer.what)
            if answer.appInstalled == false, !answer.owner.isEmpty {
                Text("\(answer.owner) isn't installed on this Mac.")
            }
            Text(answer.cost).foregroundStyle(.secondary)
            if !answer.howToRemove.isEmpty {
                Label(answer.howToRemove, systemImage: "lightbulb")
                    .foregroundStyle(.secondary)
            }
            if answer.confidence == .low {
                Label("\(Helper.name) isn't sure. Leave it unless you know what it is.", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }

            Divider().padding(.vertical, 2)

            if hooks.asking(node.path) {
                Asking()
            } else {
                if let error = hooks.error(node.path) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if answer.confirmed {
                    Label("On the cleanup list. It appears in the next scan.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if answer.canConfirm {
                    Button("Add to Cleanup List") { hooks.setOnList(answer.path, true) }
                        .buttonStyle(.glass)
                        .help("It appears in the next scan under \(answer.verdict.title), and goes to the Bin when cleaned.")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Asked \(RelativeDate.string(answer.askedAt)). Check before removing anything.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Ask Again") { hooks.ask(node, true) }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
    }
}

struct VerdictBadge: View {
    let verdict: Explanation.Verdict

    var body: some View {
        if let level = verdict.level {
            LevelBadge(level: level)
        } else {
            Text(verdict.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(.secondary)
                .background(Color.primary.opacity(0.08), in: .capsule)
        }
    }
}

// MARK: - Settings

struct ClaudeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var saveFailed = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Turn on \(Helper.name)", isOn: $model.claudeEnabled)
                Toggle("Let \(Helper.name) write short notes on its own", isOn: $model.claudeAutoNotes)
                    .disabled(!model.claudeEnabled)
            } footer: {
                Text("\(Helper.name) explains folders Headroom doesn't know. You ask for a full answer about a folder; short notes, like the summary at the top of the menu, are written on their own.")
            }

            Section {
                if model.claudeKeyStored {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved in your Keychain").foregroundStyle(.secondary)
                            Button("Remove") { model.removeClaudeKey() }
                        }
                    }
                } else {
                    SecureField("API key", text: $key, prompt: Text("sk-ant-…"))
                    HStack {
                        if saveFailed { Text("Couldn't save the key to the Keychain.").foregroundStyle(.red) }
                        Spacer()
                        Button("Save to Keychain") {
                            saveFailed = !model.saveClaudeKey(key)
                            if !saveFailed { key = "" }
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } footer: {
                Text("Create a key at console.anthropic.com. It stays in your Keychain and is sent only to Anthropic, which bills that account for each question.")
            }

            Section {
                Label("The path, with your home folder shown as ~", systemImage: "folder")
                Label("Its size and dates, and the names and sizes of the 25 largest items inside", systemImage: "list.bullet")
                Label("For notes: totals by category and cleanup group, the names of known caches, and the folders that grew", systemImage: "chart.bar")
                Label("Never file contents, and nothing from Documents, Desktop, Downloads, Pictures, Movies, Music, iCloud Drive, Mail or Messages",
                      systemImage: "lock")
            } header: {
                Text("What is sent")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A full answer costs about 3 US cents; a note costs a fraction of a cent. Answers are saved on this Mac, so nothing is asked twice.")
                    Text("\(Helper.name) runs on Claude by Anthropic: \(ClaudeClient.model) for answers, which can search the web, and \(QuickNotes.model) for notes.")
                        .font(.caption)
                }
            }

            if !model.explanations.isEmpty {
                Section {
                    ForEach(model.explanations) { item in
                        AnswerRow(item: item)
                    }
                } header: {
                    Text("Answers")
                } footer: {
                    Text("Switch an answer on to put its folder on the cleanup list. Listed folders appear in scans and go to the Bin when cleaned, so they can be put back.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.claudeKeyStored = ClaudeKey.isStored }
    }
}

private struct AnswerRow: View {
    @Environment(AppModel.self) private var model
    let item: Explanation

    var body: some View {
        if item.canConfirm {
            Toggle(isOn: Binding(get: { item.confirmed }, set: { model.setOnList(item.path, $0) })) { content }
                .help(item.confirmed ? "On the cleanup list" : "Not on the cleanup list")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                Text("\(Paths.display(item.path)) · \(ByteFormat.string(item.bytes))")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VerdictBadge(verdict: item.verdict)
            Button { model.forgetExplanation(item.path) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Forget this answer")
                .accessibilityLabel("Forget the answer about \(item.name)")
        }
    }
}

// MARK: - Popover

/// Ollie's note at the top of the menu.
struct HelperNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Graphic(name: .ollie, size: 22)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Helper.name)'s note: \(text)")
        .help("\(Helper.name)'s note, written by Claude Haiku")
    }
}

/// Folders Headroom doesn't know, each with a first guess, and a way to pick any other folder.
struct HelperScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let folders = model.unknownFolders
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Ask \(Helper.name)")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Graphic(name: .ollie, size: 44)
                    Text(!model.claudeReady ? "\(Helper.name) explains folders Headroom doesn't know, using Claude."
                         : folders.isEmpty ? "Every large folder has a cleanup rule." : "Pick a large folder Headroom has no rule for, and \(Helper.name) will say what it is.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.claudeReady {
                    SettingsLink { Text("Set Up \(Helper.name)…") }.buttonStyle(.glassProminent)
                } else {
                    VStack(spacing: 2) {
                        ForEach(folders) { node in
                            FolderRow(node: node)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Choose a Folder…") { model.chooseFolderToAsk() }.buttonStyle(.glass)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .task { model.requestGuesses(folders) }
    }
}

private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let node: SpaceNode
    @State private var hovering = false

    var body: some View {
        Button { model.screen = .ask(node.path) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    Text(subtitle)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text(ByteFormat.string(node.allocated)).font(.callout).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        if let answer = model.explanation(for: node.path) { return "\(answer.name) · \(answer.verdict.title)" }
        if let guess = model.guesses[node.path] { return guess }
        return model.notesOn ? "Guessing…" : Paths.display((node.path as NSString).deletingLastPathComponent)
    }
}

/// Ollie's answer about one folder, asked as soon as the screen opens.
struct AskScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let path: String
    @State private var bytes: Int64?

    var body: some View {
        let node = SpaceNode(path: path, name: (path as NSString).lastPathComponent, allocated: bytes ?? 0,
                             unshared: bytes ?? 0, isDirectory: true)
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: node.name, backTo: .helper)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Paths.display(path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(bytes.map(ByteFormat.string) ?? "Measuring…").font(.title3.weight(.semibold)).monospacedDigit()
                }
                if let reason = Explainer.privacyBlocker(path) {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                } else {
                    ClaudeAnswerView(node: node, hooks: model.claudeHooks)
                }
                HStack {
                    Spacer()
                    Button("Show in Space Map") {
                        model.spaceMap.reveal(path)
                        openWindow(id: "spacemap")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 16)
        }
        .task(id: path) {
            if let known = Store.snapshots().last?.sizes[path] {
                bytes = known
            } else {
                bytes = await Task.detached { Sizer.measure(path, unshared: false).allocated }.value
            }
            if model.explanation(for: path) == nil, Explainer.privacyBlocker(path) == nil {
                model.explain(SpaceNode(path: path, name: node.name, allocated: bytes ?? 0, unshared: bytes ?? 0, isDirectory: true))
            }
        }
    }
}

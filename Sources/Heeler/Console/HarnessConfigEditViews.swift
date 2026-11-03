import SwiftUI

/// The lines of a change, exactly as they go away and come.
struct HarnessConfigChangeLines: View {
    let path: String
    let lines: [HarnessConfigShownLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: path)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("harness-edit.path")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { @Sendable _, line in
                    MainActorContent { row(line) }
                }
            }
        }
    }

    private func row(_ line: HarnessConfigShownLine) -> some View {
        let isAdded = line.kind == .added
        return (Text(verbatim: isAdded ? "+ " : "- ").foregroundStyle(isAdded ? Color.green : Color.red)
            + Text(verbatim: line.text)
            + (line.endsWithoutNewline ? Text(" (no newline)").foregroundStyle(.secondary) : Text(verbatim: "")))
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(
                "\(isAdded ? "Added" : "Removed"): \(line.text)\(line.endsWithoutNewline ? ", no newline" : "")")
    }
}

/// A folder of Heeler's own that an edit places, and each file in it.
struct HarnessConfigFolderLines: View {
    let path: String
    let filePaths: [String]
    /// Already there as the edit would write them, so not added.
    var inPlace: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: path)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("harness-edit.folder")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(filePaths, id: \.self) { @Sendable file in
                    MainActorContent { row(file) }
                }
            }
        }
    }

    private func row(_ file: String) -> some View {
        let added = !inPlace.contains(file)
        return (Text(verbatim: added ? "+ " : "  ").foregroundStyle(Color.green)
            + Text(verbatim: (file as NSString).lastPathComponent)
            .foregroundStyle(added ? Color.primary : Color.secondary))
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(added ? "Added: \(file)" : "Already there: \(file)")
    }
}

/// An offer's place: the change for the user's word, and its undo afterwards.
struct HarnessConfigEditOffer: View {
    let flow: HarnessConfigEditFlow
    let offer: String
    let actionTitle: String
    let afterApplying: String

    var body: some View {
        switch flow.phase {
        case .idle:
            if let applied = flow.applied {
                Section("Applied") {
                    HarnessConfigChangeLines(path: applied.path, lines: applied.shownLines)
                    if let folder = applied.folder {
                        HarnessConfigFolderLines(path: folder.path, filePaths: folder.filePaths)
                    }
                    Text(afterApplying).font(.footnote).foregroundStyle(.secondary)
                    Button("Undo") { Task { await flow.undo() } }
                        .accessibilityIdentifier("harness-edit.undo")
                }
            } else {
                Section {
                    Button(actionTitle) { Task { await flow.review() } }
                        .accessibilityIdentifier("harness-edit.review")
                } footer: {
                    Text(offer)
                }
            }
        case .locating, .reading, .writing:
            Section {
                ProgressView().frame(maxWidth: .infinity)
            }
        case .review(let change):
            Section {
                HarnessConfigChangeLines(path: change.path, lines: change.shownLines)
                if let folder = change.folder {
                    HarnessConfigFolderLines(
                        path: folder.path, filePaths: folder.filePaths, inPlace: change.folderFilesInPlace)
                }
                Button("Apply This Change") { Task { await flow.accept() } }
                    .accessibilityIdentifier("harness-edit.apply")
                Button("Cancel", role: .cancel) { flow.cancel() }
            } header: {
                if !change.writesFolderFiles {
                    Text(change.createsFile ? "Creates This File" : "Changes This File")
                } else {
                    Text(change.createsFile ? "Creates These Files" : "Changes These Files")
                }
            } footer: {
                if let limitation = flow.limitation {
                    Text(limitation)
                }
            }
        case .alreadyApplied(let path):
            Section {
                Text(verbatim: path).font(.footnote.monospaced()).foregroundStyle(.secondary)
                Text("This file already has the setting. \(afterApplying)")
            }
        case .refused(let path, let reason, let manualInstruction):
            Section {
                Text(verbatim: path).font(.footnote.monospaced()).foregroundStyle(.secondary)
                Text(reason)
                if let manualInstruction {
                    Text(manualInstruction).font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section {
                Text(message)
                    .accessibilityIdentifier("harness-edit.failure")
                if flow.canForget {
                    Button("Stop Listing This Edit", role: .destructive) { flow.forget() }
                }
                Button("OK") { flow.cancel() }
            }
        }
    }
}

/// What Agent detail explains on an Unknown core Agent (ADR 0034), and the one
/// edit it offers on a Grok Build Agent (ADR 0033).
struct HerdrCoreStatusExplanationSheet: View {
    let explanation: HerdrCoreStatusExplanation
    @State private var flow: HarnessConfigEditFlow?
    private let hostID: Host.ID
    @Environment(\.dismiss) private var dismiss

    init(console: ConsoleStore, hostID: Host.ID, explanation: HerdrCoreStatusExplanation) {
        self.explanation = explanation
        self.hostID = hostID
        _flow = State(initialValue: console.grokBuildEditFlow(for: explanation, on: hostID))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(explanation.text)
                        .accessibilityIdentifier("agent-status-explanation.text")
                }
                if let flow {
                    HarnessConfigEditOffer(
                        flow: flow,
                        offer: "Grok Build's automatic check left its status off. One change to its configuration turns it on, and you see the change first.",
                        actionTitle: "Turn On Grok Build's Status",
                        afterApplying: "Start Grok Build again to see its status.")
                }
            }
            .task { await flow?.locate() }
            .navigationTitle("Status Unknown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Opaque: over a terminal's dark ground the default glass turns the change's
        // colored lines and every footnote hard to read.
        .presentationBackground(ConsoleStatusSheetPresentationModifier.formBackground)
    }
}

/// Chat's offer on an OpenCode Agent it can't bind (ADR 0033): the one edit that
/// loads Heeler's plugin, shown exactly and applied only on the user's word.
struct OpenCodePluginEditSheet: View {
    @State private var flow: HarnessConfigEditFlow
    @Environment(\.dismiss) private var dismiss

    init(flow: HarnessConfigEditFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        NavigationStack {
            List {
                HarnessConfigEditOffer(
                    flow: flow,
                    offer: [
                        "OpenCode says which conversation it shows through Heeler's plugin. Loading the plugin takes one change to OpenCode's configuration and a folder beside it. You see both first, and you can undo them.",
                        flow.limitation,
                    ].compactMap { $0 }.joined(separator: " "),
                    actionTitle: "Review the Change",
                    afterApplying: "Start OpenCode again to load the plugin. \(flow.limitation ?? "Chat then follows its conversation.")")
            }
            .task { await flow.locate() }
            .navigationTitle("Follow OpenCode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Opaque, as the status explanation's sheet is, for the same reason.
        .presentationBackground(ConsoleStatusSheetPresentationModifier.formBackground)
    }
}

/// Shows the explanation from the status line of an Agent that has one.
struct AgentStatusExplanationPresenter: ViewModifier {
    let console: ConsoleStore
    let agentID: ConsoleAgent.ID
    @State private var isPresented = false

    private var explanation: HerdrCoreStatusExplanation? {
        console.coreStatusExplanations[agentID]
    }

    private var show: (@MainActor @Sendable () -> Void)? {
        guard explanation != nil else { return nil }
        let presented = $isPresented
        return { presented.wrappedValue = true }
    }

    @ViewBuilder
    private var sheet: some View {
        if let explanation {
            HerdrCoreStatusExplanationSheet(
                console: console, hostID: agentID.hostID, explanation: explanation)
        }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.showAgentStatusExplanation, show)
            .sheet(isPresented: $isPresented) { sheet }
            // The Agent reported: there is nothing left to explain here, and the
            // Host's detail still lists any edit.
            .onChange(of: explanation == nil) { _, isGone in
                if isGone { isPresented = false }
            }
    }
}

extension EnvironmentValues {
    @Entry var showAgentStatusExplanation: (@MainActor @Sendable () -> Void)? = nil
}

/// The harness edits this device applied on a Host, each with its Undo. Host
/// detail lists them, so one stays undoable once its Agent reports or is gone.
struct HarnessConfigEditsSection: View {
    let console: ConsoleStore
    let hostID: Host.ID

    var body: some View {
        let edits = console.harnessEdits.edits(on: hostID)
        if !edits.isEmpty {
            Section {
                ForEach(edits) { @Sendable edit in
                    MainActorContent {
                        HarnessConfigEditRow(
                            edit: edit,
                            flow: console.harnessEditFlow(for: edit, on: hostID))
                    }
                }
            } header: {
                Text("Harness Edits")
            } footer: {
                Text("Heeler made these changes. Removing the Host Helper undoes OpenCode's and leaves any other in place.")
            }
        }
    }
}

private struct HarnessConfigEditRow: View {
    let edit: HarnessConfigAppliedEdit
    @State private var flow: HarnessConfigEditFlow

    init(edit: HarnessConfigAppliedEdit, flow: HarnessConfigEditFlow) {
        self.edit = edit
        _flow = State(initialValue: flow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: edit.harness)
            HarnessConfigChangeLines(path: edit.path, lines: edit.shownLines)
            if let folder = edit.folder {
                HarnessConfigFolderLines(path: folder.path, filePaths: folder.filePaths)
            }
            switch flow.phase {
            case .writing:
                ProgressView()
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .accessibilityIdentifier("hosts.detail.harnessEdit.failure")
                HStack {
                    if flow.canForget {
                        Button("Stop Listing", role: .destructive) { flow.forget() }
                    }
                    Spacer()
                    Button("OK") { flow.cancel() }
                }
                .buttonStyle(.borderless)
            default:
                Button("Undo") { Task { await flow.undo() } }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("hosts.detail.harnessEdit.undo")
            }
        }
        .accessibilityIdentifier("hosts.detail.harnessEdit.\(edit.editID)")
    }
}

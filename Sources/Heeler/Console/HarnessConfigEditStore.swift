import Foundation
import Observation

/// The harness edits this device applied, per Host, for undoing them. It goes with
/// the Host and outlives its core and its Host Helper, since the edit is in the
/// harness's own file (ADR 0033).
@MainActor
@Observable
final class HarnessConfigEditStore {
    private static let defaultsKey = "harness-config.applied-edits"

    @ObservationIgnored private let defaults: UserDefaults?
    private var entries: [Host.ID: [HarnessConfigAppliedEdit]]

    /// With no `defaults` it lasts as long as the object, for demo mode and tests.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        entries =
            defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Host.ID: [HarnessConfigAppliedEdit]].self, from: $0) } ?? [:]
    }

    func edits(on hostID: Host.ID) -> [HarnessConfigAppliedEdit] {
        entries[hostID] ?? []
    }

    /// One edit of one file. A Host can hold the same edit of several files, since
    /// its Agents can read different ones.
    func edit(_ editID: String, path: String, on hostID: Host.ID) -> HarnessConfigAppliedEdit? {
        entries[hostID]?.first { $0.editID == editID && $0.path == path }
    }

    func edit(id: HarnessConfigAppliedEdit.ID, on hostID: Host.ID) -> HarnessConfigAppliedEdit? {
        entries[hostID]?.first { $0.id == id }
    }

    /// The folders this Host's edits name, but for `edit`, which is leaving.
    func foldersInUse(on hostID: Host.ID, besides edit: HarnessConfigAppliedEdit.ID? = nil) -> Set<String> {
        Set(edits(on: hostID).filter { $0.id != edit }.compactMap(\.folder?.path))
    }

    /// An edit applied again to a file it left replaces what was known of it.
    func note(_ edit: HarnessConfigAppliedEdit, on hostID: Host.ID) {
        var edits = entries[hostID] ?? []
        edits.removeAll { $0.editID == edit.editID && $0.path == edit.path }
        edits.append(edit)
        entries[hostID] = edits
        save()
    }

    func forget(_ edit: HarnessConfigAppliedEdit, on hostID: Host.ID) {
        guard var edits = entries[hostID] else { return }
        edits.removeAll { $0.id == edit.id }
        entries[hostID] = edits.isEmpty ? nil : edits
        save()
    }

    /// What goes with the Host Helper: the OpenCode edit, whose plugin the Helper's
    /// sources bring, and no other (ADR 0033). One the file no longer lets Heeler undo
    /// stays listed with its own Undo, and comes back as words for the user, since a
    /// configuration file is no reason to keep a Helper the user wants gone. A lost
    /// connection throws, and stops the removal as any step's does.
    func undoEditsGoingWithTheHelper(on hostID: Host.ID, over services: any HostServices) async throws -> String? {
        var refusal: String?
        for edit in edits(on: hostID) where edit.editID == OpenCodePluginEdit.id {
            do {
                try await HarnessConfigEditor(
                    files: services, foldersInUse: foldersInUse(on: hostID, besides: edit.id)
                ).undo(edit)
                forget(edit, on: hostID)
            } catch let error as HarnessConfigEditError {
                let outcome =
                    error == .folderChangedDuringUndo
                    ? "The Host Helper is gone. " : "The Host Helper is gone, but its OpenCode edit stays in \(edit.path). "
                refusal = outcome + (error.errorDescription ?? "")
            }
        }
        return refusal
    }

    func retainHosts(_ hostIDs: Set<Host.ID>) {
        let retained = entries.filter { hostIDs.contains($0.key) }
        guard retained != entries else { return }
        entries = retained
        save()
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// One edit's walk from reading the file to the user's answer, for the place that
/// offers it or lists it. Nothing is written before `accept()` or `undo()`.
@MainActor
@Observable
final class HarnessConfigEditFlow: Identifiable {
    enum Phase: Equatable {
        /// Working out which file this offer is about, so it claims no edit yet.
        case locating
        case idle
        case reading
        case review(HarnessConfigPendingChange)
        case alreadyApplied(path: String)
        case refused(path: String, reason: String, manualInstruction: String?)
        case writing
        case failed(String)
    }

    /// What this flow answers for.
    private enum Subject {
        /// The one record a listing shows.
        case record(HarnessConfigAppliedEdit.ID)
        /// The file its Agent reads, once that is known. An edit of another file
        /// says nothing about this one.
        case offer(editID: String, path: String?)
    }

    private(set) var phase: Phase
    /// True when the last failure was the file changing under an undo, and so
    /// forgetting the edit is what is left to offer.
    private(set) var canForget = false
    /// What the edit this offer found still won't bring, once it knows its edit.
    private(set) var limitation: String?

    private let hostID: Host.ID
    private var subject: Subject
    /// A write whose answer never came. It may be on the Host, and with no record
    /// Heeler would read its own edit as one the file already had.
    private var unconfirmedWrite: HarnessConfigPendingChange?
    private let store: HarnessConfigEditStore
    private let makeEdit: @MainActor @Sendable () async throws -> HarnessConfigEdit
    private let services: @MainActor @Sendable () async throws -> any HostServices

    /// An offer, which says nothing until `locate()` or `review()` knows its file.
    init(
        hostID: Host.ID, editID: String, store: HarnessConfigEditStore,
        services: @escaping @MainActor @Sendable () async throws -> any HostServices,
        makeEdit: @escaping @MainActor @Sendable () async throws -> HarnessConfigEdit
    ) {
        self.hostID = hostID
        subject = .offer(editID: editID, path: nil)
        phase = .locating
        self.store = store
        self.services = services
        self.makeEdit = makeEdit
    }

    /// A listed edit, which can only be undone or forgotten.
    init(
        hostID: Host.ID, listing edit: HarnessConfigAppliedEdit, store: HarnessConfigEditStore,
        services: @escaping @MainActor @Sendable () async throws -> any HostServices
    ) {
        self.hostID = hostID
        subject = .record(edit.id)
        phase = .idle
        self.store = store
        self.services = services
        makeEdit = { throw TransportError.cancelled }
    }

    var applied: HarnessConfigAppliedEdit? {
        switch subject {
        case .record(let id): store.edit(id: id, on: hostID)
        case .offer(let editID, let path): path.flatMap { store.edit(editID, path: $0, on: hostID) }
        }
    }

    /// Finds the file this offer is about, for what to show first. One it can't find
    /// stays an offer: `review()` looks again, and says why if it still can't.
    func locate() async {
        guard phase == .locating else { return }
        remember(try? await makeEdit())
        // The user can't have acted during this, since nothing is offered yet.
        phase = .idle
    }

    /// Reads the file and shows the change. Writes nothing.
    func review() async {
        phase = .reading
        canForget = false
        await settleUnconfirmedWrite()
        do {
            let edit = try await makeEdit()
            remember(edit)
            // The file holds Heeler's own edit, so its Undo is what is left to offer.
            guard applied == nil else {
                phase = .idle
                return
            }
            switch try await HarnessConfigEditor(files: try await services()).propose(edit) {
            case .change(let change): phase = .review(change)
            case .alreadyApplied(let path): phase = .alreadyApplied(path: path)
            case .refused(let path, let reason, let manualInstruction):
                phase = .refused(path: path, reason: reason, manualInstruction: manualInstruction)
            }
        } catch {
            phase = .failed(HarnessConfigEditMessage.text(for: error))
        }
    }

    /// The user's word. Writes what was shown, or refuses.
    func accept() async {
        guard case .review(let change) = phase else { return }
        phase = .writing
        do {
            let files = try await services()
            do {
                let applied = try await HarnessConfigEditor(
                    files: files, foldersInUse: store.foldersInUse(on: hostID)
                ).apply(change)
                store.note(applied, on: hostID)
                phase = .idle
            } catch let lost as TransportError {
                unconfirmedWrite = change
                await settleUnconfirmedWrite()
                phase = applied == nil ? .failed(HarnessConfigEditMessage.text(for: lost)) : .idle
            }
        } catch {
            phase = .failed(HarnessConfigEditMessage.text(for: error))
        }
    }

    /// Reads the file for the write nobody confirmed.
    private func settleUnconfirmedWrite() async {
        guard let change = unconfirmedWrite else { return }
        do {
            let written = try await HarnessConfigEditor(
                files: try await services(), foldersInUse: store.foldersInUse(on: hostID)
            ).record(ofWritten: change)
            unconfirmedWrite = nil
            if let written { store.note(written, on: hostID) }
        } catch {
            // Still unknown, so the next review asks again.
        }
    }

    func cancel() {
        phase = .idle
        canForget = false
    }

    func undo() async {
        guard let applied else { return }
        phase = .writing
        do {
            try await HarnessConfigEditor(
                files: try await services(), foldersInUse: store.foldersInUse(on: hostID, besides: applied.id)
            ).undo(applied)
            store.forget(applied, on: hostID)
            phase = .idle
        } catch {
            canForget = error as? HarnessConfigEditError == .changedSinceWritten
            phase = .failed(HarnessConfigEditMessage.text(for: error))
        }
    }

    /// Stops listing an edit that can no longer be undone from here. The file stays.
    func forget() {
        guard let applied else { return }
        store.forget(applied, on: hostID)
        cancel()
    }

    private func remember(_ edit: HarnessConfigEdit?) {
        guard let edit, case .offer(let editID, _) = subject else { return }
        subject = .offer(editID: editID, path: edit.path)
        limitation = edit.limitation
    }
}

/// What the user reads when an edit could not go ahead.
enum HarnessConfigEditMessage {
    static func text(for error: any Error) -> String {
        switch error {
        case let error as HarnessConfigEditError:
            error.errorDescription ?? "Nothing was written."
        case let error as TransportError:
            error.presentation.message
        default:
            "Heeler couldn't reach the file, so nothing was written."
        }
    }
}

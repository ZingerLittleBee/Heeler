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

    /// The newest of one edit, for the place that offered it.
    func latest(_ editID: String, on hostID: Host.ID) -> HarnessConfigAppliedEdit? {
        entries[hostID]?.last { $0.editID == editID }
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

/// One offer's walk from reading the file to the user's answer, for the place that
/// offers it. Nothing is written before `accept()` or `undo()`.
@MainActor
@Observable
final class HarnessConfigEditFlow {
    enum Phase: Equatable {
        case idle
        case reading
        case review(HarnessConfigPendingChange)
        case alreadyApplied(path: String)
        case refused(path: String, reason: String)
        case writing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// True when the last failure was the file changing under an undo, and so
    /// forgetting the edit is what is left to offer.
    private(set) var canForget = false

    private let hostID: Host.ID
    private let editID: String
    private let store: HarnessConfigEditStore
    private let makeEdit: @MainActor @Sendable () async throws -> HarnessConfigEdit
    private let services: @MainActor @Sendable () async throws -> any HostServices

    init(
        hostID: Host.ID, editID: String, store: HarnessConfigEditStore,
        services: @escaping @MainActor @Sendable () async throws -> any HostServices,
        makeEdit: @escaping @MainActor @Sendable () async throws -> HarnessConfigEdit
    ) {
        self.hostID = hostID
        self.editID = editID
        self.store = store
        self.services = services
        self.makeEdit = makeEdit
    }

    var applied: HarnessConfigAppliedEdit? { store.latest(editID, on: hostID) }

    /// Reads the file and shows the change. Writes nothing.
    func review() async {
        phase = .reading
        canForget = false
        do {
            let edit = try await makeEdit()
            switch try await HarnessConfigEditor(files: try await services()).propose(edit) {
            case .change(let change): phase = .review(change)
            case .alreadyApplied(let path): phase = .alreadyApplied(path: path)
            case .refused(let path, let reason): phase = .refused(path: path, reason: reason)
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
            let applied = try await HarnessConfigEditor(files: try await services()).apply(change)
            store.note(applied, on: hostID)
            phase = .idle
        } catch {
            phase = .failed(HarnessConfigEditMessage.text(for: error))
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
            try await HarnessConfigEditor(files: try await services()).undo(applied)
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

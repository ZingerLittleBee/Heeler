import Foundation
import Observation

/// Owns one remote UTF-8 file edit. The snapshot stays beside the draft so a
/// save can prove the remote file has not changed without requiring a server
/// lock or a long-lived SFTP handle.
@MainActor
@Observable
final class RemoteFileEditorStore {
    static let readLimit = 2 * 1024 * 1024

    enum State: Equatable {
        case loading
        case binary(notice: String)
        case tooLarge(sizeBytes: UInt64, limit: Int)
        case failed(message: String)
        case editing(text: String, baseline: RemoteFileSnapshot)
        case conflict(Conflict)
    }

    struct Conflict: Equatable {
        let text: String
        let baseline: RemoteFileSnapshot
        let remote: RemoteFileEntry
    }

    enum ConflictResolution: Sendable {
        case overwrite
        case reload
    }

    let path: String
    private(set) var state: State = .loading
    private(set) var isSaving = false
    private(set) var saveErrorMessage: String?

    @ObservationIgnored private let access: RemoteFileAccess
    @ObservationIgnored private var baselineText = ""
    @ObservationIgnored private var loadOperationID: UInt64 = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var hasStartedInitialLoad = false
    @ObservationIgnored private var writeOperationID: UInt64 = 0

    init(path: String, access: RemoteFileAccess) {
        self.path = path
        self.access = access
    }

    deinit {
        loadTask?.cancel()
    }

    var text: String {
        get {
            switch state {
            case .editing(let text, _): text
            case .conflict(let conflict): conflict.text
            case .loading, .binary, .tooLarge, .failed: ""
            }
        }
        set {
            switch state {
            case .editing(_, let baseline):
                state = .editing(text: newValue, baseline: baseline)
            case .conflict(let conflict):
                state = .conflict(
                    Conflict(text: newValue, baseline: conflict.baseline, remote: conflict.remote))
            case .loading, .binary, .tooLarge, .failed:
                break
            }
        }
    }

    var isDirty: Bool {
        switch state {
        case .editing, .conflict:
            text != baselineText
        case .loading, .binary, .tooLarge, .failed:
            false
        }
    }

    /// Starts the first read once. The task belongs to the store instead of
    /// SwiftUI's transient `.task`, so a navigation redraw cannot cancel and
    /// restart a dirty editor as a destructive reload.
    func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard !hasStartedInitialLoad else { return }
        hasStartedInitialLoad = true
        await reload()
    }

    func retryLoad() async {
        await reload()
    }

    private func reload() async {
        if let loadTask {
            await loadTask.value
            return
        }

        loadOperationID &+= 1
        let operationID = loadOperationID
        let stateBeforeLoad = state
        state = .loading
        saveErrorMessage = nil
        let access = access
        let readPath = path
        let task = Task { [weak self, access] in
            do {
                let snapshot = try await access.readFile(readPath, Self.readLimit)
                try Task.checkCancellation()
                guard let self, self.loadOperationID == operationID else { return }
                defer { self.loadTask = nil }
                guard snapshot.data.count <= Self.readLimit else {
                    state = .tooLarge(
                        sizeBytes: max(snapshot.sizeBytes, UInt64(snapshot.data.count)),
                        limit: Self.readLimit)
                    return
                }
                guard !Self.containsNUL(in: snapshot.data) else {
                    state = .binary(notice: Self.binaryNotice)
                    return
                }
                guard let decoded = String(data: snapshot.data, encoding: .utf8) else {
                    state = .binary(notice: Self.binaryNotice)
                    return
                }
                baselineText = decoded
                state = .editing(text: decoded, baseline: snapshot)
            } catch is CancellationError {
                guard let self, self.loadOperationID == operationID else { return }
                state = stateBeforeLoad
                loadTask = nil
            } catch let error as RemoteFileError {
                guard let self, self.loadOperationID == operationID else { return }
                defer { loadTask = nil }
                switch error {
                case .tooLarge(_, let sizeBytes, let limit):
                    state = .tooLarge(sizeBytes: sizeBytes, limit: limit)
                case .notFound, .permissionDenied, .failure:
                    state = .failed(message: Self.message(for: error))
                }
            } catch {
                guard let self, self.loadOperationID == operationID else { return }
                defer { loadTask = nil }
                state = .failed(message: Self.message(for: error))
            }
        }
        loadTask = task
        await task.value
    }

    /// Checks the remote modification time immediately before the atomic write.
    /// A timestamp tie is permitted because a remote filesystem can only offer
    /// the precision it reported in the original snapshot.
    func save() async {
        guard !isSaving, case .editing(let draft, let baseline) = state else { return }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }

        do {
            let remote = try await access.statFile(path)
            try Task.checkCancellation()
            if let remote, Self.isNewer(remote.modified, than: baseline.modified) {
                state = .conflict(Conflict(text: text, baseline: baseline, remote: remote))
                return
            }
            await write(draft, replacing: baseline)
        } catch is CancellationError {
            // A cancelled save leaves the current draft and baseline untouched.
        } catch {
            saveErrorMessage = Self.message(for: error)
        }
    }

    func resolveConflict(_ resolution: ConflictResolution) async {
        guard case .conflict(let conflict) = state, !isSaving else { return }
        switch resolution {
        case .overwrite:
            isSaving = true
            saveErrorMessage = nil
            defer { isSaving = false }
            await write(conflict.text, replacing: conflict.baseline)
        case .reload:
            await reload()
        }
    }

    func dismissSaveError() {
        saveErrorMessage = nil
    }

    private func write(_ draft: String, replacing baseline: RemoteFileSnapshot) async {
        writeOperationID &+= 1
        let operationID = writeOperationID
        let data = Data(draft.utf8)
        do {
            let entry = try await access.writeFile(path, data)
            try Task.checkCancellation()
            guard writeOperationID == operationID else { return }
            let snapshot = RemoteFileSnapshot(
                path: path,
                data: data,
                modified: entry.modified,
                sizeBytes: entry.sizeBytes ?? UInt64(data.count))
            baselineText = draft
            // The editor is normally disabled while saving. Keeping a later
            // programmatic edit nevertheless prevents its text from being
            // silently replaced by the bytes that were sent.
            state = .editing(text: text, baseline: snapshot)
        } catch is CancellationError {
            // The text remains editable and dirty; a later explicit save can retry.
        } catch {
            saveErrorMessage = Self.message(for: error)
            if case .conflict = state {
                state = .editing(text: draft, baseline: baseline)
            }
        }
    }

    private static let binaryNotice =
        "This file appears to be binary and cannot be edited as UTF-8."

    private static func containsNUL(in data: Data) -> Bool {
        data.prefix(min(8 * 1024, data.count)).contains(0)
    }

    private static func isNewer(_ remote: Date?, than baseline: Date?) -> Bool {
        guard let remote, let baseline else { return false }
        return remote > baseline
    }

    private static func message(for error: Error) -> String {
        if let error = error as? RemoteFileError {
            switch error {
            case .notFound(let path):
                return "\(path) no longer exists."
            case .permissionDenied(let path):
                return "Permission was denied for \(path)."
            case .tooLarge(_, let sizeBytes, let limit):
                return "The file is \(sizeBytes) bytes; the editor limit is \(limit) bytes."
            case .failure(let message):
                return message
            }
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

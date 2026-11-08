import Foundation
import Observation

/// One open file's in-memory patch, independent of the Changes list's reads.
@MainActor
@Observable
final class FileDiffStore {
    enum Phase: Equatable {
        case loading
        case loaded(FilePatch)
        case failed(String)
    }

    enum Truncation: Equatable {
        case none
        case canLoadMore
        case tooLarge
    }

    enum ListChange: Equatable {
        case changed
        case removed
    }

    private(set) var file: ChangedFile
    let checkout: CheckoutLocation
    private(set) var phase: Phase = .loading
    private(set) var isRefreshing = false
    private(set) var readAt: Date?
    /// A refresh failure accompanies the earlier patch instead of replacing it.
    private(set) var refreshError: String?
    private(set) var listChange: ListChange?
    /// Nil means a complete list no longer contains this path. Keeping both
    /// observations prevents repeated notices after reloading a removed file.
    @ObservationIgnored private var latestListFile: ChangedFile?
    @ObservationIgnored private var loadedListFile: ChangedFile?
    @ObservationIgnored private let now: @MainActor () -> Date
    private var loadedLimit: FilePatchRequest.Limit = .initial

    var truncation: Truncation {
        guard case .loaded(let patch) = phase, patch.isTruncated else { return .none }
        return loadedLimit == .initial ? .canLoadMore : .tooLarge
    }

    /// The footer and VoiceOver share the counts from the opened file.
    var tooLargeMessage: String {
        String(localized: "This file is too large to display in full.")
            + (file.lineCounts.map { " " + $0.summary } ?? "")
    }

    @ObservationIgnored private let read:
        @Sendable (FilePatchRequest) async throws -> FilePatch
    @ObservationIgnored private var hasRead = false
    @ObservationIgnored private var activeRead: Task<FilePatch, any Error>?
    @ObservationIgnored private var readID = UUID()

    init(
        file: ChangedFile, checkout: CheckoutLocation,
        read: @escaping @Sendable (FilePatchRequest) async throws -> FilePatch,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.file = file
        self.checkout = checkout
        self.read = read
        self.now = now
        self.latestListFile = file
        self.loadedListFile = file
    }

    deinit {
        activeRead?.cancel()
    }

    func appear() async {
        guard !hasRead else { return }
        await refresh()
    }

    /// A pull reads this file alone, leaving the Checkout list untouched.
    /// It starts at the initial cap again, even after Load More.
    func refresh() async {
        await performRead(limit: .initial)
    }

    func reload() async {
        await refresh()
    }

    /// A list read never replaces the open patch or changes its reading
    /// position. Raw path identity also covers files beyond the display cap.
    func noteListRefresh(_ changes: CheckoutChanges) {
        guard changes.checkout.topLevel == checkout.topLevel else { return }
        if let latest = changes.files.first(where: { $0.id == file.id }) {
            latestListFile = latest
        } else {
            // Neither a capped status nor a collapsed untracked directory
            // proves that an individual file disappeared.
            guard !changes.isStatusTruncated,
                !changes.files.contains(where: {
                    $0.isUntrackedDirectory && file.path.starts(with: $0.path)
                })
            else { return }
            latestListFile = nil
        }
        updateListChange()
    }

    private func updateListChange() {
        switch (loadedListFile, latestListFile) {
        case (nil, nil): listChange = nil
        case (_, nil): listChange = .removed
        case (nil, _): listChange = .changed
        case (.some(let loaded), .some(let latest)):
            listChange = loaded.lineCounts != latest.lineCounts || loaded.kind != latest.kind
                || loaded.originalPath != latest.originalPath ? .changed : nil
        }
    }

    func loadMore() async {
        guard truncation == .canLoadMore else { return }
        await performRead(limit: .extended)
    }

    /// Closing or replacing the file cancels its request and invalidates any
    /// reply from a Transport that finishes after cancellation.
    func cancel() {
        readID = UUID()
        activeRead?.cancel()
        activeRead = nil
        isRefreshing = false
    }

    private func performRead(limit: FilePatchRequest.Limit) async {
        let listedFile = latestListFile
        let requestedFile = listedFile ?? file
        guard activeRead == nil, !Task.isCancelled,
            let request = FilePatchRequest(file: requestedFile, checkout: checkout, limit: limit)
        else { return }
        let id = UUID()
        readID = id
        let task = Task { [read] in try await read(request) }
        activeRead = task
        refreshError = nil
        if case .loaded = phase { isRefreshing = true }
        defer {
            if readID == id {
                activeRead = nil
                isRefreshing = false
            }
        }
        do {
            let patch = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard readID == id else { return }
            phase = .loaded(patch)
            loadedLimit = limit
            readAt = now()
            file = requestedFile
            loadedListFile = listedFile
            updateListChange()
            hasRead = true
        } catch is CancellationError, TransportError.cancelled {
            // A cancelled first read remains eligible for the next appearance.
        } catch {
            guard readID == id, !Task.isCancelled else { return }
            hasRead = true
            let message: String
            if let error = error as? ChangesReadError {
                message = error.message
            } else if let error = error as? TransportError {
                message = error.presentation.explanation
            } else {
                message = error.localizedDescription
            }
            if case .loaded = phase { refreshError = message } else { phase = .failed(message) }
        }
    }
}

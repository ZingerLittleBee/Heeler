import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A value-typed drop payload. The view adapts `Transferable` values into
/// these cases; the Composer store is the only place that mutates the draft
/// or starts staging.
enum ComposerDropItem: Equatable, Sendable {
    case text(String)
    case image(Data, suggestedName: String?)
    case file(URL, cleanupURL: URL?)
    case oversizedFile
    case unsupported

    static func textDrop(_ text: String) -> ComposerDropItem {
        text.isEmpty ? .unsupported : .text(text)
    }

    static func imageDrop(_ data: Data, suggestedName: String?) -> ComposerDropItem {
        data.isEmpty ? .unsupported : .image(data, suggestedName: suggestedName)
    }

    /// Copies an ephemeral dropped video/file URL into an app-owned inbox
    /// before `FileRepresentation`'s callback ends, rejecting oversized items
    /// without copying them.
    static func fileDrop(
        from sourceURL: URL,
        fallbackType: UTType,
        maximumByteCount: Int64 = Int64(FilePreparer.maximumByteCount),
        inboxRoot: URL = FilePreparer.defaultDirectory
    ) -> ComposerDropItem {
        do {
            let materialized = try FileInbox.copyToInbox(
                from: sourceURL,
                fallbackType: fallbackType,
                defaultStem: "video",
                maximumByteCount: maximumByteCount,
                inboxRoot: inboxRoot)
            return .file(materialized.url, cleanupURL: materialized.cleanupURL)
        } catch FilePreparationError.sourceTooLarge {
            return .oversizedFile
        } catch {
            return .unsupported
        }
    }
}

/// Drop is Composer-only. Direct Input and any future non-Composer mode
/// keep the destination uninstalled.
enum ComposerDropPolicy {
    static func acceptsDrops(in mode: AgentInputMode) -> Bool {
        mode == .composer
    }
}

/// Targeted-state chrome for the Composer card. Matches the existing idle
/// hairline; a drop hover uses the accent tint the tools keyboard already
/// uses for the selected tab.
struct ComposerDropHighlight: Equatable, Sendable {
    var isTargeted: Bool

    var strokeWidth: CGFloat { isTargeted ? 2 : 1 }
    var fillOpacity: Double { isTargeted ? 0.08 : 0 }
    var usesAccentStroke: Bool { isTargeted }
}

/// Import-only `Transferable` adapter for Notes/Files text and Photos/Files
/// videos and images. Video representations precede images so dragging a video
/// from Photos receives the video file rather than its poster thumbnail.
struct ComposerDropTransfer: Transferable, Equatable, Sendable {
    let item: ComposerDropItem

    init(_ item: ComposerDropItem) {
        self.item = item
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            ComposerDropTransfer(.fileDrop(from: received.file, fallbackType: .movie))
        }
        FileRepresentation(importedContentType: .video) { received in
            ComposerDropTransfer(.fileDrop(from: received.file, fallbackType: .video))
        }
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            return ComposerDropTransfer(.imageDrop(data, suggestedName: url.lastPathComponent))
        }
        DataRepresentation(importedContentType: .image) { data in
            ComposerDropTransfer(.imageDrop(data, suggestedName: nil))
        }
        DataRepresentation(importedContentType: .utf8PlainText) { data in
            ComposerDropTransfer(.textDrop(String(decoding: data, as: UTF8.self)))
        }
        DataRepresentation(importedContentType: .plainText) { data in
            ComposerDropTransfer(.textDrop(String(decoding: data, as: UTF8.self)))
        }
        ProxyRepresentation(importing: { (text: String) in
            ComposerDropTransfer(.textDrop(text))
        })
    }
}

extension View {
    /// Drop is a no-op when `isEnabled` is false (Direct Input / shell).
    func composerDropDestination(
        isEnabled: Bool,
        isTargeted: Binding<Bool>,
        accept: @escaping ([ComposerDropItem]) -> Void
    ) -> some View {
        modifier(
            ComposerDropDestinationModifier(
                isEnabled: isEnabled,
                isTargeted: isTargeted,
                accept: accept))
    }
}

private struct ComposerDropDestinationModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let accept: ([ComposerDropItem]) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.dropDestination(for: ComposerDropTransfer.self) { transfers, _ in
                accept(transfers.map(\.item))
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        } else {
            content
        }
    }
}

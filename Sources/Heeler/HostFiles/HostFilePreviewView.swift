import SwiftUI
import UIKit

/// One Host file, full screen over Files: text and Markdown read in place,
/// images, video, sound and documents from a copy made for the preview.
struct HostFilePreviewView: View {
    @Bindable var preview: HostFilePreview
    /// Puts this file's path in the Agent's message and closes Files.
    var insertPath: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("host-files-preview-done")
                    }
                    ToolbarItem(placement: .principal) {
                        HostFilePreviewTitle(name: preview.name, detail: preview.detail)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            preview.export(.share)
                        }
                        .disabled(!preview.canExport || preview.isCopying)
                        .accessibilityIdentifier("host-files-preview-share")
                        options
                    }
                }
        }
        .task { preview.open() }
        .overlay {
            if let progress = preview.exportProgress {
                HostFileExportProgress(received: progress.received, total: progress.total) {
                    preview.cancelExport()
                }
            }
        }
        .sheet(item: $preview.presentedExport) { export in
            switch export.export {
            case .share: HostFileShareSheet(url: export.url)
            case .save: HostFileSavePicker(url: export.url).ignoresSafeArea()
            }
        }
        .alert("Couldn't Copy the File", isPresented: exportFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(preview.exportFailure ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch preview.phase {
        case .loading:
            ProgressView()
        case .reading(let received, let total):
            VStack(spacing: 16) {
                Text("Reading from the Host…")
                    .font(.headline)
                HostFileProgressBar(received: received, total: total)
            }
            .padding(.horizontal, 40)
        case .copying(let received, let total):
            HostFileCopyingState(kind: preview.kind, received: received, total: total) {
                preview.cancel()
                dismiss()
            }
        case .text(let document):
            HostFileTextPage(preview: preview, document: document)
        case .image(let url):
            HostFileImageView(url: url, name: preview.name)
                .ignoresSafeArea(edges: .bottom)
        case .media(let url):
            HostFileMediaView(url: url)
        case .document(let url):
            HostFileDocumentView(url: url)
                .ignoresSafeArea(edges: .bottom)
        case .noPreview:
            ContentUnavailableView {
                Label("No Preview", systemImage: preview.kind.symbol)
            } description: {
                Text("Heeler can't show this kind of file. Share it or save it to open it in another app. Nothing is copied from the Host until you do.")
            } actions: {
                Button("Share…") { preview.export(.share) }
                    .buttonStyle(.borderedProminent)
                Button("Save to Files") { preview.export(.save) }
                Button("Copy Path") { copyPath() }
            }
        case .tooLarge:
            ContentUnavailableView {
                Label("Too Large to Open", systemImage: "arrow.up.left.and.arrow.down.right")
            } description: {
                if let size = preview.size {
                    Text("Heeler opens files up to \(HostFileFormat.size(HostFilePreview.copyLimit)). This one is \(HostFileFormat.size(size)).")
                }
            } actions: {
                Button("Copy Path") { copyPath() }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open the File", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { preview.open() }
                    .accessibilityIdentifier("host-files-preview-try-again")
            }
        }
    }

    private var options: some View {
        Menu {
            if case .text(let document) = preview.phase, document.markdown != nil {
                Button(
                    preview.showsMarkdownSource ? "View Rendered" : "View Source",
                    systemImage: preview.showsMarkdownSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right"
                ) {
                    preview.showsMarkdownSource.toggle()
                }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { copyPath() }
            if let insertPath {
                Button("Add Path to Message", systemImage: "text.insert", action: insertPath)
            }
            Button("Save to Files", systemImage: "folder") { preview.export(.save) }
                .disabled(!preview.canExport || preview.isCopying)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("host-files-preview-more")
    }

    private var exportFailure: Binding<Bool> {
        Binding(
            get: { preview.exportFailure != nil },
            set: { if !$0 { preview.exportFailure = nil } })
    }

    private func copyPath() {
        UIPasteboard.general.string = preview.path
    }
}

/// A preview's title: the file's name, with its size and when it last changed.
private struct HostFilePreviewTitle: View {
    let name: String
    let detail: String

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Text, or Markdown laid out. A long file shows one end at a time.
private struct HostFileTextPage: View {
    let preview: HostFilePreview
    let document: HostFilePreview.TextDocument

    var body: some View {
        VStack(spacing: 0) {
            if document.portion != .whole, let size = preview.size {
                portionBar(size: size)
                Divider()
            }
            if document.text.isEmpty {
                ContentUnavailableView("Empty File", systemImage: "doc")
            } else if let blocks = document.markdown, !preview.showsMarkdownSource {
                ScrollView {
                    ChatMarkdownView(blocks: blocks)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .frame(maxWidth: ReadableColumn.width)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("host-files-markdown")
            } else {
                HostFileTextView(text: document.text, startsAtEnd: document.portion == .end)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private func portionBar(size: UInt64) -> some View {
        let window = HostFileFormat.size(HostFilePreview.textWindow)
        let total = HostFileFormat.size(size)
        return HStack(spacing: 12) {
            Text(
                document.portion == .end
                    ? "Showing the last \(window) of \(total)."
                    : "Showing the first \(window) of \(total).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(document.portion == .end ? "Show Start" : "Show End") {
                preview.showText(document.portion == .end ? .start : .end)
            }
            .font(.footnote.weight(.semibold))
            .accessibilityIdentifier("host-files-text-portion")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A copy on its way to this device, for a viewer that needs the whole file.
private struct HostFileCopyingState: View {
    let kind: HostFileKind
    let received: UInt64
    let total: UInt64
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: kind.symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 96, height: 96)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)
            Text("Downloading from the Host…")
                .font(.headline)
            HostFileProgressBar(received: received, total: total)
            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("host-files-copy-cancel")
            Text(
                kind == .video || kind == .audio
                    ? "Plays when the download finishes. The copy is removed when you close the preview."
                    : "Opens when the download finishes. The copy is removed when you close the preview.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}

/// A copy being made for Share or Save, over whatever the page shows.
private struct HostFileExportProgress: View {
    let received: UInt64
    let total: UInt64
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Downloading from the Host…")
                    .font(.headline)
                HostFileProgressBar(received: received, total: total)
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 40)
        }
        .accessibilityAddTraits(.isModal)
    }
}

private struct HostFileProgressBar: View {
    let received: UInt64
    let total: UInt64

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(received), total: Double(max(total, 1)))
                .frame(maxWidth: 240)
            Text("\(HostFileFormat.size(received)) of \(HostFileFormat.size(total))")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

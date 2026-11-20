import AVKit
import QuickLook
import SwiftUI
import UIKit

/// A megabyte of text, laid out only where it is scrolled to. A SwiftUI
/// `Text` would lay all of it out before showing any.
struct HostFileTextView: UIViewRepresentable {
    let text: String
    /// The end of a file opens at its last line.
    let startsAtEnd: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1, whose noncontiguous layout keeps a long log's scrolling
        // and its scroll indicator steady.
        let view = UITextView(usingTextLayoutManager: false)
        view.layoutManager.allowsNonContiguousLayout = true
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        view.dataDetectorTypes = []
        view.isFindInteractionEnabled = true
        view.accessibilityIdentifier = "host-files-text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.text = text
        if startsAtEnd {
            let end = NSRange(location: (text as NSString).length, length: 0)
            // After the text is in place, so the range has a line to land on.
            DispatchQueue.main.async { view.scrollRangeToVisible(end) }
        } else {
            view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
        }
    }

    @MainActor
    final class Coordinator {
        var shown: String?
    }
}

/// An image copied from the Host, in Chat's zoomable viewer.
struct HostFileImageView: UIViewControllerRepresentable {
    let url: URL
    let name: String

    func makeUIViewController(context: Context) -> ChatImagePreviewController {
        ChatImagePreviewController(path: url.path, displayTitle: name) { path in
            try await Task.detached {
                try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            }.value
        }
    }

    func updateUIViewController(_ controller: ChatImagePreviewController, context: Context) {}
}

/// A document copied from the Host, in the system's viewer. Embedded, so the
/// page keeps its own bar.
struct HostFileDocumentView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

/// A video or sound copied from the Host, in the system's player.
struct HostFileMediaView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                guard player == nil else { return }
                let player = AVPlayer(url: url)
                self.player = player
                // The download was the wait: what was opened plays.
                player.play()
            }
            .onDisappear { player?.pause() }
            .accessibilityIdentifier("host-files-player")
    }
}

/// The system's share sheet for one copied file.
struct HostFileShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Save to Files: the system's picker, which keeps a copy of its own.
struct HostFileSavePicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

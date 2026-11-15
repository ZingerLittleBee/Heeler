import SwiftUI
import UIKit

/// Option C inline attachment strip above the Composer's text input: compact
/// 42pt horizontal pills with a 34×34 thumbnail, two-line metadata/progress,
/// and a remove/cancel button. Tapping an image opens a zoomable preview sheet.
struct ComposerImageStrip: View {
    private static let trailingMarginID = "composer.image-strip.trailing-margin"

    enum ScrollMilestone: Equatable, Sendable {
        case queued
        case preparing
        case uploading
        case ready
        case failed

        init(_ phase: ComposerImageAttachment.Phase) {
            switch phase {
            case .queued: self = .queued
            case .preparing: self = .preparing
            case .uploading: self = .uploading
            case .ready: self = .ready
            case .failed: self = .failed
            }
        }
    }

    struct ScrollEntry: Equatable, Sendable {
        let id: UUID
        let milestone: ScrollMilestone
        let hasPreview: Bool

        init(_ attachment: ComposerImageAttachment) {
            self.id = attachment.id
            self.milestone = ScrollMilestone(attachment.phase)
            self.hasPreview = attachment.preview != nil
        }
    }

    static func shouldScrollToEnd(from previous: [ScrollEntry], to current: [ScrollEntry]) -> Bool {
        guard current.count > 1, let last = current.last else { return false }
        guard current.count >= previous.count else { return false }
        if previous.isEmpty { return true }
        let previousIDs = Set(previous.map(\.id))
        if !previousIDs.contains(last.id) { return true }
        if let previousLast = previous.last, previousLast.id == last.id {
            if previousLast != last { return true }
            if last.milestone != .ready, previous != current { return true }
        }
        return false
    }

    let attachments: [ComposerImageAttachment]
    var horizontalMargin: CGFloat = 0
    let onPreview: (ComposerImagePreviewSheet.Item) -> Void
    let onRetry: (UUID) -> Void
    let onRemove: (UUID) -> Void

    @State private var scrollRequest = 0

    private var scrollEntries: [ScrollEntry] {
        attachments.map(ScrollEntry.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        HStack(spacing: 8) {
                            let indexed = Array(attachments.enumerated())
                            ForEach(indexed, id: \.element.id) { @Sendable entry in
                                MainActorContent {
                                    ComposerImagePill(
                                        attachment: entry.element,
                                        index: entry.offset,
                                        onPreview: {
                                            guard let preview = entry.element.preview else { return }
                                            onPreview(
                                                ComposerImagePreviewSheet.Item(
                                                    id: entry.element.id,
                                                    title: entry.element.previewTitle(at: entry.offset),
                                                    fileURL: preview.fileURL,
                                                    thumbnail: preview.thumbnail))
                                        },
                                        onRetry: { onRetry(entry.element.id) },
                                        onRemove: { onRemove(entry.element.id) })
                                }
                                .id(entry.element.id)
                            }
                        }
                        Color.clear
                            .frame(width: horizontalMargin, height: 1)
                            .id(Self.trailingMarginID)
                    }
                    .padding(.leading, horizontalMargin)
                    .padding(.vertical, 1)
                }
                .padding(.horizontal, -horizontalMargin)
                .accessibilityIdentifier("composer.image-strip")
                .onAppear {
                    if Self.shouldScrollToEnd(from: [], to: scrollEntries) {
                        scrollRequest &+= 1
                    }
                }
                .onChange(of: scrollEntries) { previous, current in
                    if Self.shouldScrollToEnd(from: previous, to: current) {
                        scrollRequest &+= 1
                    }
                }
                .task(id: scrollRequest) {
                    guard scrollRequest > 0 else { return }
                    try? await Task.sleep(for: .milliseconds(20))
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                        proxy.scrollTo(Self.trailingMarginID, anchor: .trailing)
                    }
                }
            }

            if let failureMessage = latestFailureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier("composer.image-strip.failure")
            }
        }
    }

    private var latestFailureMessage: String? {
        for attachment in attachments.reversed() {
            if case .failed(let message, _) = attachment.phase {
                return message
            }
        }
        return nil
    }
}

private struct ComposerImagePill: View {
    private static let pillWidth: CGFloat = 196
    private static let pillHeight: CGFloat = 42
    private static let pillCornerRadius: CGFloat = 12
    private static let thumbnailSize: CGFloat = 34
    private static let thumbnailCornerRadius: CGFloat = 8
    private static let infoWidth: CGFloat = 112

    let attachment: ComposerImageAttachment
    let index: Int
    let onPreview: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    private var title: String {
        ComposerImageAttachment.title(at: index)
    }

    private var isFailed: Bool {
        if case .failed = attachment.phase { return true }
        return false
    }

    private var isActiveUpload: Bool {
        switch attachment.phase {
        case .queued, .preparing, .uploading:
            true
        case .ready, .failed:
            false
        }
    }

    private var uploadFraction: Double? {
        if case .uploading(let progress) = attachment.phase {
            return min(1, max(0.05, progress.fractionCompleted))
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if isFailed {
                thumbnailButton
                retryInfoButton
            } else {
                mainPreviewButton
            }
            removeButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(width: Self.pillWidth, height: Self.pillHeight)
        .background {
            RoundedRectangle(cornerRadius: Self.pillCornerRadius, style: .continuous)
                .fill(pillBackground)
        }
        .overlay(alignment: .bottom) {
            if let fraction = uploadFraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 2.5)
                .allowsHitTesting(false)
            }
        }
        .clipShape(.rect(cornerRadius: Self.pillCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.pillCornerRadius, style: .continuous)
                .strokeBorder(pillStroke, lineWidth: isFailed ? 0.75 : 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.image-pill")
    }

    @ViewBuilder
    private var mainPreviewButton: some View {
        if attachment.preview != nil {
            Button(action: onPreview) {
                HStack(spacing: 8) {
                    thumbnailView
                    infoStack
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(attachment.subtitle)")
            .accessibilityHint(
                String(
                    localized: "Opens a large preview of the image",
                    comment: "Accessibility hint on a Composer image pill."))
            .accessibilityIdentifier("composer.image-pill.preview")
        } else {
            HStack(spacing: 8) {
                thumbnailView
                infoStack
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(attachment.subtitle)")
        }
    }

    @ViewBuilder
    private var thumbnailButton: some View {
        if attachment.preview != nil {
            Button(action: onPreview) {
                thumbnailView
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(
                String(
                    localized: "Opens a large preview of the image",
                    comment: "Accessibility hint on a Composer image pill."))
            .accessibilityIdentifier("composer.image-pill.preview")
        } else {
            thumbnailView
        }
    }

    private var retryInfoButton: some View {
        Button(action: onRetry) {
            infoStack
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(attachment.subtitle)")
        .accessibilityIdentifier("composer.image-pill.retry")
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous)
                .fill(Color(uiColor: .quaternarySystemFill))
            if let thumbnail = attachment.preview?.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .clipShape(.rect(cornerRadius: Self.thumbnailCornerRadius, style: .continuous))
                    .opacity(uploadFraction != nil ? 0.8 : 1)
            } else if case .preparing = attachment.phase {
                ProgressView()
                    .controlSize(.mini)
            } else if case .uploading = attachment.phase {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
        .overlay {
            RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    private var infoStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFailed ? Color(uiColor: .systemRed) : .primary)
                .lineLimit(1)
            Text(verbatim: attachment.subtitle)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: Self.infoWidth, alignment: .leading)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 20, height: 20)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 26, height: Self.thumbnailSize)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(removeAccessibilityLabel)
        .accessibilityIdentifier("composer.image-pill.remove")
    }

    private var removeAccessibilityLabel: String {
        if isActiveUpload {
            return String(
                localized: "Cancel \(title)",
                comment: "Accessibility label for cancelling an uploading image pill in the Composer.")
        }
        return String(
            localized: "Remove \(title)",
            comment: "Accessibility label for removing an attached image pill from the Composer.")
    }

    private var pillBackground: Color {
        if isFailed {
            return Color(uiColor: .systemRed).opacity(0.12)
        }
        return Color(uiColor: .tertiarySystemFill)
    }

    private var pillStroke: Color {
        if isFailed {
            return Color(uiColor: .systemRed).opacity(0.38)
        }
        return Color.primary.opacity(0.10)
    }

    private var subtitleColor: Color {
        switch attachment.phase {
        case .uploading:
            Color.accentColor
        case .failed:
            Color(uiColor: .systemRed).opacity(0.9)
        case .queued, .preparing, .ready:
            Color(uiColor: .secondaryLabel)
        }
    }
}

/// Hosts ``ChatImagePreviewController`` inside a sheet so tapping a Composer
/// image pill opens a full-screen zoomable preview from the local prepared file.
struct ComposerImagePreviewSheet: UIViewControllerRepresentable {
    struct Item: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let fileURL: URL
        let thumbnail: UIImage?
    }

    let item: Item
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let fileURL = item.fileURL
        let preview = ChatImagePreviewController(
            path: fileURL.path,
            displayTitle: item.title,
            placeholder: item.thumbnail,
            onDone: onDone
        ) { _ in
            try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL)
            }.value
        }
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

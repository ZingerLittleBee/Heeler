import AVKit
import SwiftUI
import UIKit

/// What a description's pictures and videos need from the detail: where
/// one loads from now, and how one opens.
struct GitHubMediaActions: Sendable {
    let resolve: GitHubMediaResolver
    let open: @MainActor @Sendable (GitHubBody.Item) -> Void
}

/// What the author wrote, laid out as Chat lays out Markdown, with the
/// pictures and videos GitHub shows where they are written (ADR 0065).
/// A tap opens a picture in Chat's zoomable viewer and a video in the
/// system's player.
struct GitHubBodyView: View {
    let text: String
    let media: [GitHubMedia]
    let actions: GitHubMediaActions
    @ScaledMetric(relativeTo: .body) private var nextLineGap: CGFloat = 4
    @ScaledMetric(relativeTo: .body) private var mediaGap: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var blankLineGap: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var aboveHeadingGap: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var belowHeadingGap: CGFloat = 12

    /// The last description laid out. The detail redraws the body when a
    /// sheet opens or a read lands, and laying out parses the Markdown.
    private static var memo: (text: String, media: [GitHubMedia], layout: GitHubBody.Layout)?

    private var layout: GitHubBody.Layout {
        if let memo = Self.memo, memo.text == text, memo.media == media { return memo.layout }
        let layout = GitHubBody.layout(markdown: text, media: media)
        Self.memo = (text, media, layout)
        return layout
    }

    var body: some View {
        let layout = layout
        let pieces = Piece.pieces(of: layout.elements)
        Group {
            if pieces.isEmpty {
                Text("No description provided.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pieces.indices, id: \.self) { @Sendable index in
                        MainActorContent {
                            pieceView(pieces[index])
                                .padding(.top, gap(before: index, in: pieces))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A link in text to a picture or video opens it.
                .environment(\.chatImageOpener, ChatImageOpener { [actions] path, _ in
                    if let item = layout.linkedItems[path] { actions.open(item) }
                })
                // The list row offers exactly the height it measured as a
                // limit, which the blocks' stack shares out by flexibility:
                // a long code block lost its last lines and a quote's bar
                // took them as a blank band. Chat's rows take their ideal
                // height for the same reason.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    static var placeholder: some View {
        Text(verbatim: "A description that is still being read from GitHub, a few lines long.")
            .redacted(reason: .placeholder)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func pieceView(_ piece: Piece) -> some View {
        switch piece {
        case .text(let blocks):
            ChatMarkdownView(blocks: blocks)
                .textSelection(.enabled)
        case .media(let group, _):
            GitHubIndented(listDepth: group.listDepth, quoteDepth: group.quoteDepth) {
                GitHubMediaFlow(items: group.items, actions: actions)
            }
        case .table(let table, _):
            GitHubIndented(listDepth: table.listDepth, quoteDepth: table.quoteDepth) {
                GitHubMediaTableView(table: table, actions: actions)
            }
        }
    }

    /// Chat's spacing between blocks, with a little more beside pictures.
    private func gap(before index: Int, in pieces: [Piece]) -> CGFloat {
        guard index > 0 else { return 0 }
        let piece = pieces[index]
        let previous = pieces[index - 1]
        guard piece.blankLineBefore else {
            return piece.isMedia || previous.isMedia ? mediaGap : nextLineGap
        }
        if previous.endsWithHeading { return belowHeadingGap }
        if piece.startsWithHeading { return aboveHeadingGap }
        return blankLineGap
    }

    /// Consecutive text blocks drawn together, or one group of pictures.
    private enum Piece: Sendable {
        case text([ChatMarkdownBlock])
        case media(GitHubBody.MediaGroup, blankLineBefore: Bool)
        case table(GitHubBody.MediaTable, blankLineBefore: Bool)

        static func pieces(of elements: [GitHubBody.Element]) -> [Piece] {
            var pieces: [Piece] = []
            for element in elements {
                switch element {
                case .block(let block):
                    if case .text(let blocks)? = pieces.last {
                        pieces[pieces.count - 1] = .text(blocks + [block])
                    } else {
                        pieces.append(.text([block]))
                    }
                case .media(let group, let blankLineBefore):
                    pieces.append(.media(group, blankLineBefore: blankLineBefore))
                case .table(let table, let blankLineBefore):
                    pieces.append(.table(table, blankLineBefore: blankLineBefore))
                }
            }
            return pieces
        }

        var blankLineBefore: Bool {
            switch self {
            case .text(let blocks): blocks.first?.blankLineBefore ?? false
            case .media(_, let blankLineBefore), .table(_, let blankLineBefore): blankLineBefore
            }
        }

        var isMedia: Bool {
            if case .text = self { return false }
            return true
        }

        var startsWithHeading: Bool {
            if case .text(let blocks) = self, case .heading? = blocks.first?.kind { return true }
            return false
        }

        var endsWithHeading: Bool {
            if case .text(let blocks) = self, case .heading? = blocks.last?.kind { return true }
            return false
        }
    }
}

/// Content set in as a block of its list items and quotes is: a bar for
/// each quote, and the indent of an item's text.
private struct GitHubIndented<Content: View>: View {
    let listDepth: Int
    let quoteDepth: Int
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(0..<quoteDepth, id: \.self) { @Sendable _ in
                MainActorContent {
                    Capsule()
                        .fill(Color(uiColor: .tertiaryLabel))
                        .frame(width: 3)
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(listDepth) * indent)
    }
}

// MARK: - Pictures and videos

/// Pictures and videos side by side while they fit, each at most its own
/// width, as a browser lays out images in a line.
private struct GitHubMediaFlow: View {
    let items: [GitHubBody.Item]
    let actions: GitHubMediaActions

    var body: some View {
        GitHubMediaFlowLayout(spacing: 8) {
            ForEach(items, id: \.viewID) { @Sendable item in
                MainActorContent {
                    switch item.media.kind {
                    case .image: GitHubImageTile(item: item, actions: actions)
                    case .video: GitHubVideoTile(item: item, actions: actions)
                    }
                }
            }
        }
    }
}

extension GitHubBody.Item {
    /// Its view's identity: the same picture in the same place keeps its
    /// view across reads.
    fileprivate var viewID: String { "\(id) \(media.id)" }
}

/// Places each tile at the size it asks for given the whole width, in rows
/// that wrap when the next tile does not fit.
private struct GitHubMediaFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(in: proposal.width ?? 320, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for entry in row.entries {
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(entry.size))
                x += entry.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var entries: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !row.entries.isEmpty, row.width + spacing + size.width > width + 0.5 {
                rows.append(row)
                row = Row()
            }
            row.width = row.entries.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.entries.append((index, size))
        }
        if !row.entries.isEmpty { rows.append(row) }
        return rows
    }
}

/// A picture: a placeholder of its size while it loads, then the picture
/// at most its own width, animated when it is an animation and Reduce
/// Motion is off. One that cannot be shown is its name in a box: a tap
/// tries again after a failed load, and otherwise opens its link or the
/// picture in the browser.
private struct GitHubImageTile: View {
    let item: GitHubBody.Item
    let actions: GitHubMediaActions
    @State private var phase: Phase
    @State private var attempt = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase {
        case loading
        case loaded(GitHubLoadedImage)
        case failed(GitHubMediaFailure)
    }

    init(item: GitHubBody.Item, actions: GitHubMediaActions) {
        self.item = item
        self.actions = actions
        _phase = State(initialValue: GitHubMediaLoader.shared.cachedImage(item.media.id).map(Phase.loaded) ?? .loading)
    }

    var body: some View {
        content
            .task(id: attempt) {
                if case .loaded = phase { return }
                switch await GitHubMediaLoader.shared.image(for: item.media, resolve: actions.resolve) {
                case .success(let loaded): phase = .loaded(loaded)
                case .failure(let failure): phase = .failed(failure)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loaded(let loaded):
            picture(loaded)
                .aspectRatio(ratio(loaded) ?? 1, contentMode: .fit)
                .frame(maxWidth: naturalWidth(loaded))
                .clipShape(.rect(cornerRadius: 6))
                .contentShape(.rect)
                .onTapGesture { actions.open(item) }
                .accessibilityElement()
                .accessibilityLabel(Text(item.name))
                .accessibilityHint(Text("Opens the image"))
                .accessibilityAddTraits([.isImage, .isButton])
                .accessibilityAction { actions.open(item) }
        case .loading:
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(uiColor: .tertiarySystemFill))
                .aspectRatio(ratio(nil) ?? 16 / 10, contentMode: .fit)
                .frame(maxWidth: naturalWidth(nil))
                .overlay { ProgressView() }
                .accessibilityElement()
                .accessibilityLabel(Text(item.name))
                .accessibilityAddTraits(.isImage)
        case .failed(let failure):
            failed(failure)
        }
    }

    @ViewBuilder
    private func picture(_ loaded: GitHubLoadedImage) -> some View {
        if let animation = loaded.animation, !reduceMotion {
            GitHubAnimatedPicture(image: loaded.image, animation: animation)
        } else {
            Image(uiImage: loaded.image).resizable()
        }
    }

    private func failed(_ failure: GitHubMediaFailure) -> some View {
        Button {
            switch failure {
            case .unavailable:
                phase = .loading
                attempt += 1
            case .unsupported, .tooLarge:
                Task {
                    let url: URL? = if let link = item.link { link } else { await actions.resolve(item.media, false) }
                    if let url { openURL(url) }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: failure == .unavailable ? "arrow.clockwise" : "photo")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(3)
                    switch failure {
                    case .unavailable:
                        Text("Couldn't load this image")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .tooLarge:
                        Text("Too large to show (20 MB maximum)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .unsupported:
                        EmptyView()
                    }
                }
            }
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Width over height: the tag's, else the picture's.
    private func ratio(_ loaded: GitHubLoadedImage?) -> CGFloat? {
        if let width = item.media.width, let height = item.media.height { return CGFloat(width) / CGFloat(height) }
        guard let size = loaded?.pixelSize, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// As a browser sizes it: the tag's width, else the picture's pixels as
    /// CSS pixels, and never wider than the column.
    private func naturalWidth(_ loaded: GitHubLoadedImage?) -> CGFloat? {
        item.media.width.map { CGFloat($0) } ?? loaded.map(\.pixelSize.width)
    }
}

/// An animated picture, which SwiftUI's `Image` shows as its first frame.
private struct GitHubAnimatedPicture: UIViewRepresentable {
    let image: UIImage
    let animation: Data

    func makeUIView(context: Context) -> AnimatedImageView {
        let view = AnimatedImageView(image: image)
        view.contentMode = .scaleAspectFit
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        view.animationData = animation
        return view
    }

    func updateUIView(_ view: AnimatedImageView, context: Context) {
        view.animationData = animation
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AnimatedImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? image.size.width, height: proposal.height ?? image.size.height)
    }
}

/// A video: its first frame, as wide as the video and at most 520 points
/// tall, with a play button and its length.
private struct GitHubVideoTile: View {
    let item: GitHubBody.Item
    let actions: GitHubMediaActions
    @State private var poster: GitHubVideoPoster?

    init(item: GitHubBody.Item, actions: GitHubMediaActions) {
        self.item = item
        self.actions = actions
        _poster = State(initialValue: GitHubMediaLoader.shared.cachedPoster(item.media.id))
    }

    var body: some View {
        Button {
            actions.open(item)
        } label: {
            ZStack {
                Color.black
                if let image = poster?.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                if let duration = poster?.duration {
                    Text(duration.formatted(.time(pattern: .minuteSecond)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: naturalWidth, maxHeight: 520)
            .clipShape(.rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.name))
        .accessibilityHint(Text("Plays the video"))
        .task(id: item.media.id) {
            guard poster?.image == nil else { return }
            poster = await GitHubMediaLoader.shared.poster(for: item.media, resolve: actions.resolve)
        }
    }

    private var ratio: CGFloat {
        if let size = poster?.pixelSize, size.width > 0, size.height > 0 { return size.width / size.height }
        if let width = item.media.width, let height = item.media.height { return CGFloat(width) / CGFloat(height) }
        return 16 / 9
    }

    private var naturalWidth: CGFloat? {
        item.media.width.map { CGFloat($0) } ?? poster?.pixelSize?.width
    }
}

// MARK: - Tables

/// A table that holds pictures or videos: Chat's table, with each cell's
/// pictures under its text, sized to its column.
private struct GitHubMediaTableView: View {
    let table: GitHubBody.MediaTable
    let actions: GitHubMediaActions
    @Environment(\.themeColors) private var themeColors
    @ScaledMetric(relativeTo: .subheadline) private var minimumColumnWidth: CGFloat = 112

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        }
    }

    private var grid: some View {
        ChatMarkdownTableLayout(columns: table.columns.count, minimumColumnWidth: minimumColumnWidth) {
            ForEach(table.rows.indices, id: \.self) { @Sendable row in
                MainActorContent {
                    ForEach(table.columns.indices, id: \.self) { @Sendable column in
                        MainActorContent {
                            cell(row: row, column: column)
                        }
                    }
                }
            }
        }
    }

    private func cell(row: Int, column: Int) -> some View {
        let cell = table.rows[row].indices.contains(column)
            ? table.rows[row][column] : GitHubBody.MediaTable.Cell(text: AttributedString(), items: [])
        let font: Font = row == 0 ? .subheadline.weight(.semibold) : .subheadline
        return VStack(alignment: horizontalAlignment(column), spacing: 6) {
            if !cell.text.characters.isEmpty {
                Text(ChatMarkdownView.styled(cell.text, in: font))
                    .font(font)
                    .multilineTextAlignment(textAlignment(column))
            }
            if !cell.items.isEmpty {
                GitHubMediaFlow(items: cell.items, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(column))
        .padding(8)
        .background(row == 0 ? themeColors.raised : themeColors.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5)
        }
    }

    private func alignment(_ column: Int) -> Alignment {
        switch table.columns[column] {
        case .left: .topLeading
        case .center: .top
        case .right: .topTrailing
        }
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch table.columns[column] {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.columns[column] {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}

// MARK: - Viewers

/// A picture in Chat's zoomable viewer, or a video in the system's player.
struct GitHubMediaViewer: View {
    let item: GitHubBody.Item
    let resolve: GitHubMediaResolver
    let onDone: @MainActor () -> Void

    var body: some View {
        switch item.media.kind {
        case .image:
            GitHubImageViewer(item: item, resolve: resolve, onDone: onDone)
                .presentationDetents([.large])
                .ignoresSafeArea()
        case .video:
            GitHubVideoViewer(item: item, resolve: resolve, onDone: onDone)
                .presentationDetents([.large])
        }
    }
}

private struct GitHubImageViewer: UIViewControllerRepresentable {
    let item: GitHubBody.Item
    let resolve: GitHubMediaResolver
    let onDone: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let media = item.media
        let preview = ChatImagePreviewController(
            path: media.id,
            displayTitle: item.name,
            placeholder: GitHubMediaLoader.shared.cachedImage(media.id)?.image,
            onDone: onDone,
            decodeImage: { try await GitHubMediaDecoder.shared.image(from: $0, maximumPixelSize: 4_096).image },
            animatesImages: true
        ) { [resolve] _ in
            try await GitHubMediaLoader.shared.data(for: media, resolve: resolve)
        }
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

/// A video in the system's player, from an address GitHub signed now.
private struct GitHubVideoViewer: View {
    let item: GitHubBody.Item
    let resolve: GitHubMediaResolver
    let onDone: @MainActor () -> Void
    @State private var url: URL?
    @State private var failed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    HostFileMediaView(url: url)
                } else if failed {
                    ContentUnavailableView {
                        Label("Couldn't load this video", systemImage: "film")
                    } actions: {
                        Button("Retry") {
                            failed = false
                            Task { await load() }
                        }
                    }
                    .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDone() }
                }
                if let url {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open in Browser", systemImage: "safari") { openURL(url) }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard url == nil else { return }
        url = await resolve(item.media, false)
        failed = url == nil
    }
}

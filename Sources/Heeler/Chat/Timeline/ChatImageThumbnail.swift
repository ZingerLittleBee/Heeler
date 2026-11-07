import SwiftUI

/// An image row's picture, under its title. Its height never changes, so
/// a picture arriving, failing or waiting never moves the rows around it;
/// only its width follows the picture. A tap opens the zoomable sheet.
struct ChatImageThumbnail: View {
    static let height: CGFloat = 180
    /// On a wide screen it stays a thumbnail.
    static let maximumWidth: CGFloat = 480
    /// The frame that stands in until a picture shows.
    static let placeholderWidth: CGFloat = 240
    private static let cornerRadius: CGFloat = 8

    let path: String
    let thumbnails: ChatImageThumbnails?
    /// Opens the sheet, with the picture shown so far.
    let open: (UIImage?) -> Void

    var body: some View {
        content
            .frame(maxWidth: Self.maximumWidth, alignment: .leading)
            .frame(height: Self.height, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { thumbnails?.appear(path) }
            .onDisappear { thumbnails?.disappear(path) }
            .onChange(of: path) { old, new in
                thumbnails?.disappear(old)
                thumbnails?.appear(new)
            }
    }

    private var name: String {
        RemoteHostPath.lastComponent(of: path)
    }

    @ViewBuilder
    private var content: some View {
        switch thumbnails?.phase(of: path) ?? .offline {
        case .loaded(let image):
            Button {
                open(image)
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Self.cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Image, \(name)")
            .accessibilityHint("Opens the image")
            .accessibilityIdentifier("chat.image-thumbnail")
        case .loading:
            placeholder {
                ProgressView()
            }
            .accessibilityElement()
            .accessibilityLabel("Loading image, \(name)")
            .accessibilityIdentifier("chat.image-thumbnail.loading")
        case .large(let bytes):
            let size = Int64(bytes).formatted(.byteCount(style: .file))
            Button {
                thumbnails?.load(path)
            } label: {
                placeholder {
                    note(size, action: String(localized: "Tap to Load"), symbol: "arrow.down.circle")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load image, \(name), \(size)")
            .accessibilityIdentifier("chat.image-thumbnail.large")
        case .offline:
            placeholder {
                note(String(localized: "Connect to the Host to show this image"), symbol: "wifi.slash")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.image-thumbnail.offline")
        case .failed(let message):
            Button {
                thumbnails?.load(path)
            } label: {
                placeholder {
                    note(message, action: String(localized: "Try Again"), symbol: "exclamationmark.triangle")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(message)
            .accessibilityHint("Tries again")
            .accessibilityIdentifier("chat.image-thumbnail.failed")
        }
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(maxWidth: Self.placeholderWidth, maxHeight: .infinity)
            .overlay {
                content()
                    .padding(12)
            }
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
    }

    /// What a frame without a picture says, and what a tap on it does when
    /// it is a button.
    private func note(_ text: String, action: String? = nil, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .foregroundStyle(.secondary)
            if let action {
                Text(verbatim: action)
                    .foregroundStyle(.tint)
            }
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .minimumScaleFactor(0.7)
    }
}

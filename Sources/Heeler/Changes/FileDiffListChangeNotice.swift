import SwiftUI

/// A bottom inset leaves the document's top and row identities untouched.
/// The read time continues to describe the patch until a reload succeeds.
struct FileDiffListChangeNotice: View {
    let change: FileDiffStore.ListChange?
    let readAt: Date
    let isRefreshing: Bool
    let reload: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    if let change {
                        Text(change == .changed
                            ? String(localized: "This file changed since this diff was read.")
                            : String(localized: "This file is no longer in Changes."))
                    }
                    Text(ChangesFreshness.readTime(readAt, relativeTo: context.date, locale: locale))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if change != nil {
                    Button("Reload", action: reload)
                        .disabled(isRefreshing)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
        }
    }
}

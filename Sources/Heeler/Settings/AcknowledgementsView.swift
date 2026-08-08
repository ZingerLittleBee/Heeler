import SwiftUI

/// Settings › About › Acknowledgements: the screen that makes the bundled
/// licence notices reachable rather than merely present (#161).
///
/// The list is driven by the audited `Notices/inventory.json` catalogue, not by
/// scanning whatever `.txt` files happen to be in the bundle. Each inventory
/// entry must resolve to a UTF-8 notice resource or the screen reports the
/// failure instead of silently omitting a dependency.
struct AcknowledgementsView: View {
    private let notices: [LicenseNotice]?
    private let failureMessage: String?

    init(notices: [LicenseNotice]) {
        self.notices = notices
        self.failureMessage = nil
    }

    init(bundle: Bundle = .main) {
        do {
            self.notices = try LicenseNoticeCatalog.bundledNotices(in: bundle)
            self.failureMessage = nil
        } catch {
            self.notices = nil
            self.failureMessage = error.localizedDescription
        }
    }

    var body: some View {
        Group {
            if let notices {
                noticeList(notices)
            } else {
                ContentUnavailableView(
                    "Notices Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        failureMessage
                            ?? "This build is missing its licence notices. Please report it."))
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func noticeList(_ notices: [LicenseNotice]) -> some View {
        List {
            Section {
                ForEach(notices) { notice in
                    NavigationLink {
                        LicenseNoticeDetailView(notice: notice)
                    } label: {
                        LabeledContent(notice.component, value: notice.license)
                    }
                }
            } footer: {
                Text(
                    "Heeler redistributes these components. Each licence is reproduced in full.")
            }
        }
        .overlay {
            if notices.isEmpty {
                ContentUnavailableView(
                    "No Notices Bundled",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "This build is missing its licence notices. Please report it."))
            }
        }
    }
}

/// One licence, verbatim.
///
/// Monospaced and scrollable on both axes: these texts are hard-wrapped at
/// around 75 columns upstream, and letting them soft-wrap again on a phone
/// interleaves their indentation with the reflowed remainder of the line above,
/// which is unreadable. Panning sideways is the lesser cost. Selectable, so the
/// text can be copied out rather than transcribed.
struct LicenseNoticeDetailView: View {
    let notice: LicenseNotice

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(notice.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle(notice.component)
        .navigationBarTitleDisplayMode(.inline)
    }
}

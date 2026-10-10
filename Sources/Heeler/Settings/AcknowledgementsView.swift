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
    private let sourceRevision: BuildSourceRevision?

    init(notices: [LicenseNotice], sourceRevision: BuildSourceRevision? = nil) {
        self.notices = notices
        self.failureMessage = nil
        self.sourceRevision = sourceRevision
    }

    init(bundle: Bundle = .main) {
        do {
            self.notices = try LicenseNoticeCatalog.bundledNotices(in: bundle)
            self.failureMessage = nil
        } catch {
            self.notices = nil
            self.failureMessage = error.localizedDescription
        }
        self.sourceRevision = BuildSourceRevision(infoDictionary: bundle.infoDictionary)
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Heeler redistributes these components. Each licence is reproduced in full.")
                    if let sourceRevision, let sourceURL = sourceRevision.sourceURL {
                        Text(
                            "This build was made from commit \(Text(sourceRevision.shortCommit).monospaced()), whose source pins each component's exact version.")
                        Link("Source for This Build", destination: sourceURL)
                            .font(.footnote)
                    }
                }
            }
        }
        .readableColumnPage()
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

/// One licence, verbatim, under the version and source it was audited at.
///
/// The licence text is monospaced and pans sideways: these texts are
/// hard-wrapped at around 75 columns upstream, and letting them soft-wrap again
/// on a phone interleaves their indentation with the reflowed remainder of the
/// line above, which is unreadable. Panning sideways is the lesser cost. The
/// version and source above it wrap instead. Both are selectable, so they can
/// be copied out rather than transcribed.
struct LicenseNoticeDetailView: View {
    let notice: LicenseNotice

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if notice.version != nil || notice.source != nil {
                    provenance
                        .padding(.horizontal)
                }
                ScrollView(.horizontal) {
                    Text(notice.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(notice.component)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var provenance: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            if let version = notice.version {
                GridRow {
                    Text("Version")
                        .foregroundStyle(.secondary)
                    // One line: wrapping a 40-digit commit id hyphenates it.
                    Text(version)
                        .monospaced()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .truncationMode(.middle)
                }
            }
            if let source = notice.source {
                GridRow {
                    Text("Source")
                        .foregroundStyle(.secondary)
                    Text(source)
                }
            }
        }
        .font(.footnote)
        .textSelection(.enabled)
    }
}

/// The commit a distributed build was archived from.
///
/// `make archive` (through `scripts/source-revision.sh`, only for a pushed
/// commit with nothing but the build number uncommitted) and the release
/// workflow set `HEELER_SOURCE_REVISION`, which Info.plist carries as
/// `HeelerSourceRevision`. Through
/// `Packages/HeelerOverlay/Package.swift` that commit names the exact
/// heeler-overlay-natives release, so a TestFlight build whose marketing
/// version predates its source still maps to the corresponding source that
/// LGPL-3.0 and MPL-2.0 require. Other builds leave it empty and show nothing.
struct BuildSourceRevision: Equatable, Sendable {
    static let infoKey = "HeelerSourceRevision"

    /// Full lowercase SHA-1 commit id.
    let commit: String

    init?(infoDictionary: [String: Any]?) {
        guard let value = infoDictionary?[Self.infoKey] as? String,
              value.count == 40, value.allSatisfy(\.isHexDigit)
        else { return nil }
        commit = value.lowercased()
    }

    var shortCommit: String { String(commit.prefix(8)) }

    var sourceURL: URL? {
        SettingsView.repositoryURL?.appending(path: "tree/\(commit)")
    }
}

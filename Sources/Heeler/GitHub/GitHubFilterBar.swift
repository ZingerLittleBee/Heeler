import SwiftUI
import UIKit

/// A filter sheet, for what the menus do not list.
enum GitHubFilterSheet: String, Identifiable {
    /// Someone Else…
    case person
    /// Other Repository…
    case repository
    /// Other Label…
    case label

    var id: Self { self }
}

/// What the filter menus offer beyond the defaults: the people,
/// repositories, owners and labels in the lists read on the Host, and what
/// the filter names already.
struct GitHubFilterOptions: Equatable {
    /// The account gh is signed in to, when a list has named it.
    var viewer: String?
    /// Authors and assignees of the segment's items, not the account and not
    /// an app's bot.
    var people: [String] = []
    /// Every list's repositories.
    var repositories: [String] = []
    /// The owners of those repositories, not the account.
    var owners: [String] = []
    /// The segment's labels.
    var labels: [GitHubLabel] = []

    @MainActor
    init(store: GitHubStore, host: GitHubHost, kind: GitHubItem.Kind) {
        let state = store.state(of: host)
        let filter = store.filter(for: kind)
        let viewer = state.list?.login ?? state.results.values.compactMap(\.login).first { !$0.isEmpty }
        self.viewer = viewer
        let lists: [(GitHubItem.Kind, GitHubItemList)] =
            [(.pullRequest, state.list?.pullRequests), (.issue, state.list?.issues)].compactMap { kind, list in
                list.map { (kind, $0) }
            } + state.results.compactMap { kind, results in results.list.map { (kind, $0) } }
        let everything = lists.flatMap { $0.1.items }
        let segment = lists.filter { $0.0 == kind }.flatMap { $0.1.items }
        let isViewer = { (login: String) in viewer.map { $0.caseInsensitiveCompare(login) == .orderedSame } ?? false }

        var people = Self.unique(
            segment.flatMap { item in
                (item.authorIsApp == true ? [] : [item.author].compactMap(\.self)) + (item.assignees ?? [])
            }
        ).filter { !isViewer($0) }
        if let login = filter.person?.login { people = Self.unique(people + [login]) }
        self.people = Self.sorted(people)

        var repositories = Self.unique(everything.map(\.repository))
        if case .repository(let name) = filter.repository { repositories = Self.unique(repositories + [name]) }
        self.repositories = Self.sorted(repositories)

        var owners = Self.unique(everything.map(\.repositoryOwner)).filter { !isViewer($0) }
        if case .owner(let login) = filter.repository, !isViewer(login) { owners = Self.unique(owners + [login]) }
        self.owners = Self.sorted(owners)

        var labels: [GitHubLabel] = []
        for label in segment.flatMap(\.labels) + [filter.label.map { GitHubLabel(name: $0, color: "") }].compactMap(\.self)
        where GitHubFilterInput.label(label.name) == label.name && !labels.contains(where: { $0.name == label.name }) {
            labels.append(label)
        }
        self.labels = labels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func sorted(_ names: [String]) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// The row of filters under the Pull Requests / Issues picker: State,
/// Person, Repository and Label, each a menu, and a leading × that clears
/// them once any is changed. The chips wrap onto more lines rather than
/// scroll, so every choice in force stays in sight.
struct GitHubFilterBar: View {
    let kind: GitHubItem.Kind
    let filter: GitHubListFilter
    let options: GitHubFilterOptions
    let apply: (GitHubListFilter) -> Void
    let openSheet: (GitHubFilterSheet) -> Void

    var body: some View {
        ChipWrap(spacing: 8, lineSpacing: 8) {
            if !filter.isDefault {
                Button {
                    apply(GitHubListFilter())
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .padding(8)
                        .frame(minWidth: 34, minHeight: 34)
                        .background(.fill.tertiary, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Filters"))
            }
            stateMenu
            personMenu
            repositoryMenu
            labelMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Self.accent)
    }

    /// The system's blue, which the app's tint is. The iPad's sidebar list
    /// tints its rows grey, and its views, a default tint included,
    /// resolve to that grey, so the filters name their colour.
    static let accent = Color(uiColor: .systemBlue)

    // MARK: State

    private var stateMenu: some View {
        Menu {
            ForEach(GitHubListFilter.states(for: kind), id: \.self) { state in
                choice(filter.state == state) { $0.state = state } label: {
                    Text(state.title(for: kind))
                    if let subtitle = state.subtitle(for: kind) { Text(subtitle) }
                }
            }
        } label: {
            GitHubFilterChip(title: filter.stateTitle(for: kind), isChanged: filter.state != .open)
        }
        .accessibilityLabel(Text("State"))
        .accessibilityValue(filter.stateTitle(for: kind))
    }

    // MARK: Person

    private var personMenu: some View {
        let roles = GitHubListFilter.roles(for: kind)
        return Menu {
            // Anyone needs a Repository, or it would search all of GitHub.
            if filter.repository != nil {
                Section {
                    choice(filter.whose == .anyone) { $0.people = .anyone } label: {
                        Text(String(localized: "GitHub person Anyone", defaultValue: "Anyone"))
                        Text("By anyone, not only you")
                    }
                }
            }
            Section(options.viewer.map { String(localized: "You, @\($0)") } ?? String(localized: "You")) {
                choice(filter.whose == .yours) { $0.people = .yours } label: {
                    Text(String(localized: "GitHub person Yours", defaultValue: "Yours"))
                    Text(
                        kind == .pullRequest
                            ? String(localized: "Created by you or needing your review")
                            : String(localized: "Assigned to you or created by you"))
                }
                ForEach(roles, id: \.self) { role in
                    let person = GitHubListFilter.Person(role: role, login: nil)
                    choice(filter.person == person) { $0.people = .person(person) } label: { Text(role.viewerTitle) }
                }
            }
            Section(String(localized: "Others", comment: "GitHub Person filter menu: people other than you.")) {
                ForEach(options.people, id: \.self) { login in
                    Menu {
                        ForEach(roles, id: \.self) { role in
                            let person = GitHubListFilter.Person(role: role, login: login)
                            choice(filter.person == person) { $0.people = .person(person) } label: { Text(role.title(for: login)) }
                        }
                    } label: {
                        if let person = filter.person, person.login == login {
                            Label(login, systemImage: "checkmark")
                            Text(person.title)
                        } else {
                            Text(login)
                        }
                    }
                }
                Button(String(localized: "Someone Else…")) { openSheet(.person) }
            }
        } label: {
            GitHubFilterChip(title: filter.personTitle, isChanged: filter.people != nil)
        }
        .accessibilityLabel(Text("Person"))
        .accessibilityValue(filter.personTitle)
    }

    // MARK: Repository

    private var repositoryMenu: some View {
        Menu {
            choice(filter.repository == nil) { $0.repository = nil } label: { Text("All Repositories") }
            if !options.repositories.isEmpty {
                Section(String(localized: "In Your Lists", comment: "GitHub filter menu: what the lists read showed.")) {
                    ForEach(options.repositories, id: \.self) { name in
                        let repository = GitHubListFilter.Repository.repository(name)
                        choice(filter.repository == repository) { $0.repository = repository } label: { Text(verbatim: name) }
                    }
                }
            }
            Section(String(localized: "Owners", comment: "GitHub Repository filter menu: accounts that own repositories.")) {
                ForEach(options.owners, id: \.self) { login in
                    let repository = GitHubListFilter.Repository.owner(login)
                    choice(filter.repository == repository) { $0.repository = repository } label: {
                        Text(verbatim: login)
                        Text("Every repository it owns")
                    }
                }
                if let viewer = options.viewer {
                    let repository = GitHubListFilter.Repository.owner(viewer)
                    choice(filter.repository == repository) { $0.repository = repository } label: {
                        Text(verbatim: viewer)
                        Text("Your own repositories")
                    }
                }
            }
            Section {
                Button(String(localized: "Other Repository…")) { openSheet(.repository) }
            }
        } label: {
            GitHubFilterChip(title: filter.repositoryTitle, isChanged: filter.repository != nil)
        }
        .accessibilityLabel(Text("Repository"))
        .accessibilityValue(filter.repository == nil ? String(localized: "All Repositories") : filter.repositoryTitle)
    }

    // MARK: Label

    private var labelMenu: some View {
        Menu {
            choice(filter.label == nil) { $0.label = nil } label: { Text("Any Label") }
            if !options.labels.isEmpty {
                Section(String(localized: "In Your Lists", comment: "GitHub filter menu: what the lists read showed.")) {
                    ForEach(options.labels, id: \.name) { label in
                        choice(filter.label == label.name) { $0.label = label.name } label: {
                            if let dot = Self.dot(for: label.color) {
                                Label { Text(verbatim: label.name) } icon: { Image(uiImage: dot) }
                            } else {
                                Text(verbatim: label.name)
                            }
                        }
                    }
                }
            }
            Section {
                Button(String(localized: "Other Label…")) { openSheet(.label) }
            }
        } label: {
            GitHubFilterChip(title: filter.labelTitle, isChanged: filter.label != nil)
        }
        .accessibilityLabel(Text("Label"))
        .accessibilityValue(filter.label ?? String(localized: "Any Label"))
    }

    // MARK: Pieces

    /// A menu item with a checkmark when chosen; choosing it applies the
    /// change.
    private func choice<Label: View>(
        _ isChosen: Bool, _ change: @escaping (inout GitHubListFilter) -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Toggle(isOn: Binding(
            get: { isChosen },
            set: { _ in
                var changed = filter
                change(&changed)
                apply(changed)
            }
        )) {
            label()
        }
    }

    /// A label's colour as a dot a menu draws as it is, since a menu tints
    /// its symbols.
    private static func dot(for hex: String) -> UIImage? {
        guard hex.count == 6, let rgb = Int(hex, radix: 16) else { return nil }
        let color = UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        return UIImage(systemName: "circle.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

/// Clear Filters under an empty, offline or failed filtered list: a grey
/// capsule, as the chips at their defaults are.
struct GitHubClearFiltersButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Clear Filters")
                .fontWeight(.semibold)
                // Not `.primary`, which in a button is the tint's.
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .background(.fill.tertiary, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One filter's chip: what it shows, tinted once changed from its default.
private struct GitHubFilterChip: View {
    let title: String
    let isChanged: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes a chip may take a line of its own and
        // still not fit, and its words wrap rather than lose the name.
        let wraps = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: 5) {
            Text(verbatim: title)
                .lineLimit(wraps ? 3 : 1)
                .multilineTextAlignment(.leading)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .imageScale(.small)
        }
        .font(.subheadline.weight(.medium))
        // `Color.primary`, not `.primary`: a menu's label takes the tint as
        // its foreground, and `.primary` is that foreground's first level.
        .foregroundStyle(isChanged ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
        // Narrow enough that the four chips at their defaults fit one line
        // on a 402-point iPhone.
        .padding(.leading, 12)
        .padding(.trailing, 10)
        // Room above and below the words at the larger text sizes.
        .padding(.vertical, 6)
        .frame(minHeight: 34)
        .background(isChanged ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.fill.tertiary), in: shape)
        .contentShape(shape)
    }

    /// A capsule, which wrapped words would overflow at its ends.
    private var shape: AnyShape {
        dynamicTypeSize.isAccessibilitySize
            ? AnyShape(RoundedRectangle(cornerRadius: 17, style: .continuous)) : AnyShape(Capsule())
    }
}

// MARK: - Sheets

/// Someone Else…, Other Repository… and Other Label…: a name typed in full,
/// for what the menus do not list.
struct GitHubFilterEntrySheet: View {
    let sheet: GitHubFilterSheet
    let kind: GitHubItem.Kind
    let options: GitHubFilterOptions
    let filter: GitHubListFilter
    let apply: (GitHubListFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var role = GitHubListFilter.Role.author
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 2) {
                        if sheet == .person {
                            Text(verbatim: "@")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        TextField(fieldLabel, text: $text, prompt: Text(verbatim: placeholder))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(sheet == .label ? .default : .asciiCapable)
                            .submitLabel(.done)
                            .focused($isFieldFocused)
                            .onSubmit(done)
                    }
                } header: {
                    Text(fieldLabel)
                } footer: {
                    Text(note)
                }
                if sheet == .person, !options.people.isEmpty {
                    Section {
                        ChipWrap(spacing: 8, lineSpacing: 8) {
                            ForEach(options.people, id: \.self) { login in
                                Button {
                                    text = login
                                } label: {
                                    Text(verbatim: login)
                                        .font(.subheadline)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .frame(minHeight: 34)
                                        .background(.fill.tertiary, in: Capsule())
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    }
                }
                if sheet == .person {
                    Section {
                        ForEach(GitHubListFilter.roles(for: kind), id: \.self) { role in
                            Button {
                                self.role = role
                            } label: {
                                HStack {
                                    Text(role.someoneTitle)
                                        // `.primary` in a button is the tint's.
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                    if self.role == role {
                                        Image(systemName: "checkmark")
                                            .fontWeight(.semibold)
                                            .foregroundStyle(GitHubFilterBar.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityAddTraits(self.role == role ? .isSelected : [])
                        }
                    } header: {
                        Text("Show")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                        .disabled(changed == nil)
                }
            }
        }
        .presentationDetents(sheet == .person ? [.large] : [.medium, .large])
        .presentationSizing(.form)
        .onAppear { isFieldFocused = true }
    }

    /// The filter with what was typed, or nil while it names nothing GitHub
    /// could.
    private var changed: GitHubListFilter? {
        var changed = filter
        switch sheet {
        case .person:
            guard let login = GitHubFilterInput.login(text) else { return nil }
            let isViewer = options.viewer.map { $0.caseInsensitiveCompare(login) == .orderedSame } ?? false
            changed.people = .person(GitHubListFilter.Person(role: role, login: isViewer ? nil : login))
        case .repository:
            guard let repository = GitHubFilterInput.repository(text) else { return nil }
            changed.repository = repository
        case .label:
            guard let label = GitHubFilterInput.label(text) else { return nil }
            changed.label = label
        }
        return changed
    }

    private func done() {
        guard let changed else { return }
        apply(changed)
        dismiss()
    }

    private var title: String {
        switch sheet {
        case .person: String(localized: "Person")
        case .repository: String(localized: "Repository")
        case .label: String(localized: "Label")
        }
    }

    private var fieldLabel: String {
        switch sheet {
        case .person: String(localized: "GitHub Username")
        case .repository: String(localized: "Repository or Owner")
        case .label: String(localized: "Label Name")
        }
    }

    /// The field's placeholder, a name in GitHub's own form.
    private var placeholder: String {
        switch sheet {
        case .person: String(localized: "username", comment: "Placeholder of the GitHub username field.")
        case .repository: String(localized: "owner/name", comment: "Placeholder of the GitHub repository field.")
        case .label: "needs-triage"
        }
    }

    private var note: String {
        switch sheet {
        case .person: String(localized: "Anyone on GitHub, not only the people in your lists.")
        case .repository: String(localized: "An owner on its own, such as acme, covers every repository it owns.")
        case .label: String(localized: "Labels are matched by name in every repository the other filters allow.")
        }
    }
}

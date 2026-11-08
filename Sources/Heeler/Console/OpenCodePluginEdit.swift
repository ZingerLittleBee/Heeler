import Foundation

/// The one edit that lets Chat follow an OpenCode Agent it can't otherwise bind
/// (ADR 0033): Heeler's OpenCode plugin copied into a folder of its own under
/// OpenCode's config directory, and that folder added to OpenCode's plugin list.
enum OpenCodePluginEdit {
    static let id = "opencode.plugin"
    static let offerTitle = String(localized: "Let Chat Follow OpenCode…")
    static let harness = "OpenCode"
    static let folderName = "heeler-opencode"
    /// Relative to the file that lists it, as OpenCode resolves it in both forms.
    static let entryValue = "./\(folderName)"
    /// Where the plugin sits in the Helper's tree.
    static let bundleFolder = "extensions/opencode"
    static let fileNames = ["package.json", "index.js", "tui.js"]

    /// The list and the file are the release's own: under the wrong key the entry
    /// does nothing, and looks as if it did.
    static func manualInstruction(fileName: String, form: ConfigForm) -> String {
        String(localized: "Add \"\(entryValue)\" to \(form.listKey) in \(fileName), with a copy of Heeler's plugin in a folder of that name beside the file.")
    }

    /// A top-level list flattens over the one inside this section, so the entry has
    /// to go inside it (herdr compatibility, OpenCode 1.19.5).
    static func manualInstruction(fileName: String, form: ConfigForm, inside section: String) -> String {
        String(localized: "Add \"\(entryValue)\" to \(form.listKey) inside \(section) in \(fileName), not at the top of the file, where a list would replace the one inside \(section), with a copy of Heeler's plugin in a folder of that name beside the file.")
    }

    /// For an Agent whose release Heeler can't read.
    static var manualInstructionForEitherRelease: String {
        let (tui, cli) = (ConfigForm.tuiConfig, ConfigForm.cliConfig)
        return String(localized: "Add \"\(entryValue)\" to \(tui.listKey) in \(tui.fileNames[0]) on OpenCode 1.x, or to \(cli.listKey) in \(cli.fileNames[0]) on 2.x, with a copy of Heeler's plugin in a folder of that name beside the file.")
    }

    /// Where a release of OpenCode lists its TUI plugins (herdr compatibility,
    /// OpenCode 1.19.5, 2.0.32 and 2.2.5, from source).
    struct ConfigForm: Equatable, Sendable {
        /// The files it reads, the one to create first.
        let fileNames: [String]
        let listKey: String
        let schema: String
        /// Set beside the list, it would take the list's meaning from it.
        let refusingKeys: Set<String>

        static let tuiConfig = ConfigForm(
            fileNames: ["tui.json", "tui.jsonc"], listKey: "plugin", schema: "https://opencode.ai/tui.json",
            refusingKeys: ["tui"])
        static let cliConfig = ConfigForm(
            fileNames: ["cli.json"], listKey: "plugins", schema: "https://opencode.ai/v2/cli.json",
            refusingKeys: [])

        /// Nil for a version this can't read, or a major release nobody has looked
        /// at: a list in the wrong file does nothing, and looks as if it did.
        static func of(version: String?) -> ConfigForm? {
            switch HerdrCoreLaunch.openCodeRelease(version: version)?.major {
            case 1: .tuiConfig
            case 2: .cliConfig
            default: nil
            }
        }
    }

    /// The program to ask for the release an Agent runs: what it ran, when that
    /// names OpenCode, or else `opencode` as its own PATH finds it.
    static func program(running argv: [String]) -> String {
        guard let first = argv.first, (first as NSString).lastPathComponent.hasPrefix("opencode") else {
            return SupportedAgentKind.opencode.executable
        }
        return first
    }

    /// `$XDG_CONFIG_HOME/opencode`, by default `~/.config/opencode`, on Linux and on
    /// a Mac. Nil when the Agent's `XDG_CONFIG_HOME` names no absolute path.
    static func configDirectory(xdgConfigHome: String?, home: String) -> String? {
        if let xdgConfigHome, !xdgConfigHome.isEmpty {
            guard xdgConfigHome.hasPrefix("/") else { return nil }
            return RemoteFilePath.join(trimmingTrailingSlashes(xdgConfigHome), "opencode")
        }
        return RemoteFilePath.join(trimmingTrailingSlashes(home), ".config", "opencode")
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Whether a running OpenCode 2.x may write this file by itself: it makes a
    /// `cli.json` out of `tui.json`, plugin list included, whenever it finds no
    /// `cli.json`, and not only at its start (herdr compatibility, OpenCode 2.2.2).
    /// An undo that takes such a file away comes last, once no `tui.json` of
    /// Heeler's names the folder any more.
    static func isMigratedInto(_ path: String) -> Bool {
        ConfigForm.cliConfig.fileNames.contains((path as NSString).lastPathComponent)
    }

    /// Every file of either release beside the folder, with the entry its list
    /// would name the folder by, for the folder's last undo to take out of a file
    /// OpenCode wrote it into meanwhile.
    static func listings(of folderPath: String) -> [HarnessConfigListing] {
        let directory = (folderPath as NSString).deletingLastPathComponent
        return [ConfigForm.tuiConfig, ConfigForm.cliConfig].flatMap { form in
            form.fileNames.map {
                HarnessConfigListing(
                    path: RemoteFilePath.join(directory, $0),
                    entry: HarnessConfigListEntry(key: form.listKey, value: entryValue))
            }
        }
    }

    /// A file of the form that exists, the first when none does: OpenCode reads
    /// them all, and its plugin list adds up across them.
    static func fileName(in directory: String, form: ConfigForm, over files: any HostServices) async throws -> String {
        for name in form.fileNames {
            let slice = try await files.readHostFileRange(
                RemoteFileRange(path: RemoteFilePath.join(directory, name), offset: 0, maxBytes: 1))
            if slice.length != nil { return name }
        }
        return form.fileNames[0]
    }

    /// The plugin's own files out of the Helper's bundle, which its manifest covers.
    static func pluginFiles(from bundle: HostHelperBundle) throws -> [HarnessConfigFolder.File] {
        try fileNames.map { name in
            let path = "\(bundleFolder)/\(name)"
            guard let contents = bundle.files[path] else { throw HostHelperBundle.LoadError.unreadable(path) }
            return HarnessConfigFolder.File(name: name, contents: contents)
        }
    }

    static func edit(
        configDirectory: String, fileName: String, form: ConfigForm, files: [HarnessConfigFolder.File]
    ) -> HarnessConfigEdit {
        let folderPath = RemoteFilePath.join(configDirectory, folderName)
        return HarnessConfigEdit(
            id: id, harness: harness, path: RemoteFilePath.join(configDirectory, fileName),
            transform: transform(form: form, folderPath: folderPath, fileName: fileName),
            folder: HarnessConfigFolder(path: folderPath, files: files),
            listEntry: HarnessConfigListEntry(key: form.listKey, value: entryValue),
            manualInstruction: manualInstruction(fileName: fileName, form: form))
    }

    private static let unreadableReason =
        String(localized: "Heeler can't read this file with certainty, so it won't change it.")
    private static let notAListReason =
        String(localized: "This file sets OpenCode's plugin list in a form Heeler won't change.")

    static func transform(
        form: ConfigForm, folderPath: String, fileName: String
    ) -> @Sendable (Data?) -> HarnessConfigEdit.Transform {
        { file in
            // OpenCode reads an empty file as no configuration at all.
            guard let file, !file.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else {
                return .change(to: Data(newFile(form: form).utf8))
            }
            let entry = HarnessConfigListEntry(key: form.listKey, value: entryValue)
            switch HarnessConfigJSONCList.adding(
                entry, sameAs: [folderPath, "file://\(folderPath)"], refusingKeys: form.refusingKeys, to: file)
            {
            case .changed(let after): return .change(to: after)
            case .alreadyThere: return .alreadyApplied
            case .unreadable: return .refused(reason: unreadableReason)
            case .notAList: return .refused(reason: notAListReason)
            case .keyInTheWay(let section):
                return .refused(
                    reason: notAListReason,
                    manualInstruction: manualInstruction(fileName: fileName, form: form, inside: section))
            }
        }
    }

    private static func newFile(form: ConfigForm) -> String {
        """
        {
          "$schema": "\(form.schema)",
          "\(form.listKey)": ["\(entryValue)"]
        }

        """
    }
}

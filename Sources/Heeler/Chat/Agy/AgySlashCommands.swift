import Foundation

/// Antigravity CLI's built-in `/` commands, which Chat's menu keeps clear of.
enum AgySlashCommands {
    /// Every command and alias agy 1.5.3 reserves, lowercased: those its `/`
    /// popup lists with their aliases in brackets, the commands it ships as
    /// bundled workflows (`/goal`, `/plan`, `/boost` and the like), and the
    /// names its binary registers without listing them, such as `/bug` and
    /// `/load`. Which of a skill and a built-in of the same name runs is not
    /// known, so Chat offers no skill named like one. Regenerate on version
    /// bumps.
    static let builtIns: Set<String> = [
        "add-dir", "agents", "artifact", "boost", "branch", "browser", "btw", "bug", "changelog", "clear",
        "codesearch", "compact", "config", "context", "conv-switch", "conversation", "copy", "credits", "cs",
        "diff", "effort", "exit", "feedback", "fork", "goal", "grill-me", "help", "hooks", "keybindings",
        "learn", "load", "logout", "mcp", "model", "new", "open", "permissions", "plan", "plugin", "plugins",
        "projects", "quit", "quota", "record", "remote-control", "rename", "resume", "rewind", "schedule",
        "search", "settings", "skills", "statusline", "switch", "tasks", "teamwork", "title", "undo", "usage",
        "voice",
    ]
}

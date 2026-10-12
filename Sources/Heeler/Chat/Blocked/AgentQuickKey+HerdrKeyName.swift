import Foundation

extension AgentQuickKey {
    /// The key's name for `agent.send_keys`, nil for keys herdr cannot
    /// send: it has no Home, End, Insert, Delete or page keys.
    var herdrKeyName: String? {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .shiftTab: "shift+tab"
        case .shiftEnter: "shift+enter"
        case .left: "left"
        case .up: "up"
        case .down: "down"
        case .right: "right"
        case .enter: "enter"
        case .backspace: "backspace"
        case .function(let key): "f\(key.rawValue)"
        case .character(let character):
            switch character {
            case " ": "space"
            case "+": "plus"
            default: character.unicodeScalars.count == 1 ? String(character) : nil
            }
        case .home, .end, .insert, .forwardDelete, .pageUp, .pageDown: nil
        }
    }
}

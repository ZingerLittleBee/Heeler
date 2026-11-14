import Foundation

/// A tmux Pane's size alongside the size of the window that holds it, read on
/// an Attach's control client while sizing that window (ADR 0045).
struct TmuxPaneGeometry: Equatable, Sendable {
    var windowID: String
    var windowWidth: Int
    var windowHeight: Int
    var paneWidth: Int
    var paneHeight: Int

    init(windowID: String, windowWidth: Int, windowHeight: Int, paneWidth: Int, paneHeight: Int) {
        self.windowID = windowID
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.paneWidth = paneWidth
        self.paneHeight = paneHeight
    }

    init?(_ line: Data) {
        let fields = String(decoding: line, as: UTF8.self)
            .split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 5, fields[0].hasPrefix("@"),
            let windowWidth = Int(fields[1]), let windowHeight = Int(fields[2]),
            let paneWidth = Int(fields[3]), let paneHeight = Int(fields[4]),
            windowWidth > 0, windowHeight > 0, paneWidth > 0, paneHeight > 0
        else { return nil }
        windowID = fields[0]
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.paneWidth = paneWidth
        self.paneHeight = paneHeight
    }
}

/// Control-mode commands that size one window on an Attach's control client and
/// hand it back with `ignore-size` when the device looks away (ADR 0045).
enum TmuxPaneSize {
    /// tmux's `WINDOW_MINIMUM` through `WINDOW_MAXIMUM` (`cmd-refresh-client.c`).
    static let windowRange = 2...10_000

    static let geometryFormat = "#{window_id} #{window_width} #{window_height} #{pane_width} #{pane_height}"
    static let clientsFormat =
        "#{client_control_mode} #{window_id} #{client_width} #{client_height} #{status} #{client_flags}"

    struct Request: Equatable, Sendable {
        var columns: Int
        var rows: Int
    }

    static func clamp(_ side: Int) -> Int {
        min(windowRange.upperBound, max(windowRange.lowerBound, side))
    }

    static func clientsCommand() -> TmuxControlCommand {
        TmuxControlCommand(["list-clients", "-F", clientsFormat])
    }

    /// Smallest window area (`client_width` by `client_height` minus that
    /// client's status lines) among non-control, non-`ignore-size` clients
    /// whose session currently shows `window`; nil when none qualify.
    static func clientCeiling(from lines: [Data], forWindow window: String) -> Request? {
        var minColumns: Int?
        var minRows: Int?
        for line in lines {
            let fields = String(decoding: line, as: UTF8.self)
                .split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 6,
                fields[0] == "0",
                fields[1] == window,
                let width = Int(fields[2]),
                let height = Int(fields[3]),
                width > 0, height > 0,
                let statusLines = statusLineCount(fields[4])
            else { continue }
            let flags = fields[5].split(separator: ",")
            guard !flags.contains("ignore-size"), !flags.contains("control-mode") else { continue }
            // tmux sets CLIENT_STATUSOFF when tty.sy <= s->statuslines (resize.c).
            let windowRows = height > statusLines ? height - statusLines : height
            minColumns = min(minColumns ?? width, width)
            minRows = min(minRows ?? windowRows, windowRows)
        }
        guard let minColumns, let minRows else { return nil }
        return Request(columns: minColumns, rows: minRows)
    }

    private static func statusLineCount(_ status: String) -> Int? {
        switch status {
        case "off":
            return 0
        case "on":
            return 1
        default:
            guard let count = Int(status), count >= 0 else { return nil }
            return count
        }
    }

    static func readCommand(pane: String) -> TmuxControlCommand {
        TmuxControlCommand(["display-message", "-p", "-t", pane, geometryFormat])
    }

    static func sizeCommand(
        window: String, columns: Int, rows: Int, clearingIgnoreSize: Bool = false
    ) -> TmuxControlCommand {
        let spec = "\(window):\(clamp(columns))x\(clamp(rows))"
        if clearingIgnoreSize {
            return TmuxControlCommand(["refresh-client", "-f", "!ignore-size", "-C", spec])
        }
        return TmuxControlCommand(["refresh-client", "-C", spec])
    }

    /// Turns `ignore-size` on. Once a client has set a per-window size, `-f
    /// ignore-size` alone leaves the window at that size until another client
    /// triggers a recalculation, and an empty `-C @<window>:` drops an
    /// unattached window to the client's 80x24 tty. Pairing `-f ignore-size`
    /// with `@<window>`'s current size recalculates immediately: another
    /// client takes the window back at once, and a window with none keeps the
    /// size it had.
    static func ignoreSizeCommand(
        releasing: (window: String, width: Int, height: Int)? = nil
    ) -> TmuxControlCommand {
        guard let releasing else {
            return TmuxControlCommand(["refresh-client", "-f", "ignore-size"])
        }
        let spec = "\(releasing.window):\(clamp(releasing.width))x\(clamp(releasing.height))"
        return TmuxControlCommand(["refresh-client", "-f", "ignore-size", "-C", spec])
    }
}

/// Scales `@<window>:<columns>x<rows>` from the Pane's share of the window and
/// corrects each axis from what tmux gave the Pane until the Pane fits inside
/// the device's grid or another client's smaller ceiling stops the window.
struct TmuxPaneSizer: Sendable {
    static let maxRequests = 8

    private struct Axis: Sendable {
        let target: Int
        let maxWindow: Int
        private(set) var lastRequest = 0
        private var bestFitRequest: Int?
        private var smallestTooLarge: Int?
        private(set) var converged = false

        init(target: Int, ceiling: Int?) {
            self.target = max(1, target)
            maxWindow = ceiling.map(TmuxPaneSize.clamp) ?? TmuxPaneSize.windowRange.upperBound
        }

        private func clamp(_ side: Int) -> Int {
            min(maxWindow, TmuxPaneSize.clamp(side))
        }

        mutating func initialRequest(window: Int, pane: Int) -> Int {
            let scaled = Int((Double(target) * Double(max(1, window)) / Double(max(1, pane))).rounded())
            let request = clamp(scaled)
            lastRequest = request
            return request
        }

        mutating func observe(window: Int, pane: Int, remainingRequests: Int) -> Int {
            if converged, pane <= target, window <= maxWindow {
                return lastRequest
            }
            converged = false

            if pane == target, window <= maxWindow {
                bestFitRequest = lastRequest
                converged = true
                return lastRequest
            }

            if pane > target {
                let effectiveWindow = min(lastRequest, window)
                smallestTooLarge = min(smallestTooLarge ?? Int.max, effectiveWindow)
                if effectiveWindow <= TmuxPaneSize.windowRange.lowerBound {
                    lastRequest = TmuxPaneSize.windowRange.lowerBound
                    converged = true
                    return lastRequest
                }
                if remainingRequests <= 1 {
                    lastRequest = clamp(bestFitRequest ?? TmuxPaneSize.windowRange.lowerBound)
                    converged = true
                    return lastRequest
                }
                if let best = bestFitRequest, best >= effectiveWindow - 1 {
                    lastRequest = clamp(best)
                    converged = true
                    return lastRequest
                }
                let drop = max(
                    1,
                    Int((Double(pane - target) * Double(max(1, window)) / Double(max(1, pane))).rounded()))
                var candidate = clamp(min(effectiveWindow - 1, effectiveWindow - drop))
                if let best = bestFitRequest, candidate <= best {
                    candidate = clamp((best + effectiveWindow) / 2)
                }
                lastRequest = candidate
                return lastRequest
            }

            // pane < target
            if window < lastRequest {
                bestFitRequest = lastRequest
                converged = true
                return lastRequest
            }
            bestFitRequest = max(bestFitRequest ?? TmuxPaneSize.windowRange.lowerBound, lastRequest)
            if lastRequest >= maxWindow || remainingRequests <= 0 {
                converged = true
                return lastRequest
            }
            if let upper = smallestTooLarge, lastRequest + 1 >= upper {
                converged = true
                return lastRequest
            }
            let gain = max(
                1,
                Int((Double(target - pane) * Double(max(1, window)) / Double(max(1, pane))).rounded()))
            var candidate = clamp(lastRequest + gain)
            if let upper = smallestTooLarge, candidate >= upper {
                candidate = clamp((lastRequest + upper) / 2)
            }
            lastRequest = candidate
            return lastRequest
        }
    }

    private var width: Axis
    private var height: Axis
    private var requestsSent = 0

    init(targetColumns: Int, targetRows: Int, ceiling: TmuxPaneSize.Request? = nil) {
        width = Axis(target: targetColumns, ceiling: ceiling?.columns)
        height = Axis(target: targetRows, ceiling: ceiling?.rows)
    }

    mutating func initialRequest(from geometry: TmuxPaneGeometry) -> TmuxPaneSize.Request {
        requestsSent = 1
        return TmuxPaneSize.Request(
            columns: width.initialRequest(window: geometry.windowWidth, pane: geometry.paneWidth),
            rows: height.initialRequest(window: geometry.windowHeight, pane: geometry.paneHeight))
    }

    mutating func nextRequest(after geometry: TmuxPaneGeometry) -> TmuxPaneSize.Request? {
        let remaining = max(0, Self.maxRequests - requestsSent)
        let previous = TmuxPaneSize.Request(columns: width.lastRequest, rows: height.lastRequest)
        let next = TmuxPaneSize.Request(
            columns: width.observe(
                window: geometry.windowWidth, pane: geometry.paneWidth, remainingRequests: remaining),
            rows: height.observe(
                window: geometry.windowHeight, pane: geometry.paneHeight, remainingRequests: remaining))
        guard remaining > 0 else { return nil }
        if width.converged, height.converged, next == previous {
            return nil
        }
        requestsSent += 1
        return next
    }
}

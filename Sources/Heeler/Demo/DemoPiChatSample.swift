#if DEBUG && targetEnvironment(simulator)
    import Foundation

    /// Synthetic JSONL, never copied from a user's conversation. The same
    /// production locator, follower and reducer used over SSH reads these.
    enum DemoPiChatSample {
        static let piID = "f3c2a481-54ed-4c7e-a240-6d036157dc80"
        static let ompID = "019a0b41-0c91-7bd1-8b27-2fd239a5a0e4"
        static let piPath =
            "/Users/developer/.pi/agent/sessions/--workspace-heeler--/2026-10-15T00-00-00-000Z_\(piID).jsonl"
        static let ompPath =
            "/Users/developer/.omp/agent/sessions/--workspace-product-docs--/2026-10-15T00-00-00-000Z_\(ompID).jsonl"

        static func identity(forPane pane: String) -> (kind: String, name: String, title: String)? {
            switch pane {
            case "mobile:p1": ("pi", "Pi", "Review the mobile layout")
            case "docs:p2": ("omp", "Oh My Pi", "Improve the setup guide")
            default: nil
            }
        }

        static func session(forPane pane: String) -> AgentSessionInfo? {
            switch pane {
            case "mobile:p1": AgentSessionInfo(agent: "pi", kind: .path, source: "herdr:pi", value: piPath)
            case "docs:p2": AgentSessionInfo(agent: "omp", kind: .path, source: "herdr:omp", value: ompPath)
            default: nil
            }
        }

        static let files = [
            piPath: conversation(id: piID, omp: false),
            ompPath: conversation(id: ompID, omp: true),
        ]

        static func screen(forPane pane: String) -> String? {
            switch pane {
            case "mobile:p1":
                "────────────────────────────────────────\r\n \u{1B}[7m \u{1B}[0m\r\n────────────────────────────────────────\r\n/workspace/heeler\r\n$0.000 1.2%/200k (auto)"
            case "docs:p2": "╭── Ready ──────────────────────────────╮\r\n╰─ ▏                                  ─╯"
            default: nil
            }
        }

        static func terminalOutput(forPane pane: String) -> String? {
            guard DemoScreenshotMode.showsPiChat, let identity = identity(forPane: pane),
                let input = screen(forPane: pane)
            else { return nil }
            return "\u{1B}[2J\u{1B}[H\u{1B}[1m\(identity.name)\u{1B}[0m\r\n"
                + "\(identity.title)\r\n\r\n"
                + "Read 1 file · Edited 1 file\r\n\r\n"
                + "The focused change is ready. Check small screens, reconnects and long output next.\r\n\r\n"
                + input
        }

        private static func conversation(id: String, omp: Bool) -> Data {
            var rows: [[String: Any]] = []
            if omp { rows.append(["type": "title", "v": 1, "title": "Improve the setup guide", "pad": ""]) }
            rows.append([
                "type": "session", "version": 3, "id": id, "timestamp": "2026-10-15T00:00:00.000Z",
                "cwd": "/workspace/sample",
            ])
            var parent: String?
            func add(_ type: String, _ fields: [String: Any]) {
                let entry = "entry-\(rows.count)"
                var row = fields
                row["type"] = type
                row["id"] = entry
                row["parentId"] = parent.map { $0 as Any } ?? NSNull()
                row["timestamp"] = "2026-10-15T00:00:\(String(format: "%02d", rows.count)).000Z"
                rows.append(row)
                parent = entry
            }
            let file = omp ? "docs/setup.md" : "Sources/MobileView.swift"
            add(
                "message",
                [
                    "message": [
                        "role": "user",
                        "content": omp
                            ? "请整理设置指南，让首次使用的人能更快完成配对。"
                            : "请检查手机界面的布局，修复窄屏时输入框被遮挡的问题。",
                    ]
                ])
            add(
                "message",
                [
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "thinking", "thinking": "先读相关文件，再确认现有行为和需要调整的部分。"],
                            ["type": "toolCall", "id": "read-1", "name": "read", "arguments": ["path": file]],
                        ], "stopReason": "toolUse",
                    ]
                ])
            add(
                "message",
                [
                    "message": [
                        "role": "toolResult", "toolCallId": "read-1", "toolName": "read",
                        "content": [
                            [
                                "type": "text",
                                "text": omp
                                    ? "# Setup\n1. Open Settings\n2. Pair your phone"
                                    : "struct MobileView: View {\n    var body: some View { content }\n}",
                            ]
                        ], "isError": false,
                    ]
                ])
            add(
                "message",
                [
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "toolCall", "id": "edit-1", "name": "edit", "arguments": ["path": file]]
                        ], "stopReason": "toolUse",
                    ]
                ])
            add(
                "message",
                [
                    "message": [
                        "role": "toolResult", "toolCallId": "edit-1", "toolName": "edit",
                        "content": [
                            [
                                "type": "text",
                                "text": "Updated \(file)\n+ Added the focused fix\n- Removed the old behavior",
                            ]
                        ], "isError": false,
                    ]
                ])
            add(
                "message",
                [
                    "message": [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "text",
                                "text": omp
                                    ? "已更新设置指南：\n\n- 合并重复步骤\n- 添加配对前的检查\n- 补充失败后的恢复方式\n\n现在可以按顺序完成首次设置。"
                                    : "已修复窄屏布局：\n\n- 输入框保持可见\n- 键盘弹出时保留阅读位置\n- 长消息可以正常换行\n\n相关检查已通过。",
                            ]
                        ], "stopReason": "stop",
                    ]
                ])
            add(
                "compaction",
                ["summary": "保留本轮修改和验证结论，释放较早的上下文。", "firstKeptEntryId": "entry-1", "tokensBefore": 42000])
            add("message", ["message": ["role": "user", "content": "下一步还需要检查哪些边界情况？"]])
            add(
                "message",
                [
                    "message": [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "thinking",
                                "thinking": String(repeating: "需要覆盖不同屏幕尺寸、断线恢复和长文本，避免只验证正常路径。\n", count: 40),
                            ],
                            [
                                "type": "text",
                                "text":
                                    "建议先检查这两项：\n\n| 检查 | 预期结果 |\n| --- | --- |\n| 小屏幕与大字体 | **表格**保持列对齐，长文本在单元格内换行。 |\n| 断线后返回 | 已读内容保留，恢复连接后继续更新；`restoreVisibleAnchor()` 仍保持格式。 |\n\n然后检查长工具输出，展开和收起后阅读位置应保持稳定。",
                            ],
                        ], "stopReason": "stop",
                    ]
                ])
            return rows.reduce(into: Data()) { data, row in
                if let encoded = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                    data.append(encoded)
                    data.append(0x0A)
                }
            }
        }
    }
#endif

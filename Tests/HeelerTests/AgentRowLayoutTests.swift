import Foundation
import Testing

@testable import Heeler

@Suite("Agent row layout")
struct AgentRowLayoutTests {
    @Test func missingFieldsUseHerdrDefaults() throws {
        for json in [#"{"v":1}"#, #"{"v":1,"sidebar":{"agents":{}}}"#] {
            let snapshot = try #require(AgentRowLayoutSnapshot.decode(Data(json.utf8)))
            #expect(snapshot.layout == .heelerDefault)
            #expect(snapshot.agentPanelSort == .spaces)
            #expect(snapshot.diagnostics.isEmpty)
        }
        #expect(AgentRowLayout.heelerDefault.rows.map { $0.map(\.token) }
                == [[.stateIcon, .workspace, .tab], [.agent]])
    }

    @Test func snapshotRetainsSortStylesOverridesAndDiagnostics() throws {
        let data = Data(#"""
            {"v":1,"generated_at":1757040000,"source":{"found":true},"future":true,
             "agent_panel_sort":"priority","sidebar":{"agents":{
               "row_gap":2,"rows":[[{"token":"workspace","dim":true},
                 {"token":"$pin_icon","fg":"#aBc","bold":false,"dim":false,"extra":7}]],
               "rows_by_agent":{"claude":[[{"token":"terminal_title_stripped"}]]}}},
             "diagnostics":["using defaults for an unrelated setting"]}
            """#.utf8)
        let snapshot = try #require(AgentRowLayoutSnapshot.decode(data))
        #expect(snapshot.agentPanelSort == .priority)
        #expect(snapshot.layout == AgentRowLayout(
            rows: [[.init(.workspace, dim: true),
                    .init(.custom("pin_icon"), fg: HexColor("#aBc"), bold: false, dim: false)]],
            rowGap: 2, rowsByAgent: ["claude": [[.init(.terminalTitleStripped)]]]))
        #expect(snapshot.diagnostics == ["using defaults for an unrelated setting"])
        #expect(snapshot.layout.rows(forAgentKind: "codex") == snapshot.layout.rows)
        let encoded = try JSONEncoder().encode(snapshot.layout)
        #expect(try JSONDecoder().decode(AgentRowLayout.self, from: encoded) == snapshot.layout)
        #expect(String(decoding: encoded, as: UTF8.self).contains("$pin_icon"))
    }

    @Test func unknownTokensDropIndividuallyAndInvalidColorDropsOnlyColor() throws {
        let data = Data(#"""
            {"v":1,"agent_panel_sort":"workspaces","sidebar":{"agents":{
              "rows":[[{"token":"future_builtin"},{"token":"$"},
                {"token":"agent","fg":"red","bold":true}], [{"token":"$valid-name_2"}]],
              "rows_by_agent":{"claude":[[{"token":"future_builtin"}]]}}}}
            """#.utf8)
        let snapshot = try #require(AgentRowLayoutSnapshot.decode(data))
        #expect(snapshot.agentPanelSort == .spaces)
        #expect(snapshot.layout.rows == [[.init(.agent, bold: true)], [.init(.custom("valid-name_2"))]])
        #expect(snapshot.layout.rows(forAgentKind: "claude") == [[]])
    }

    @Test func absentOrMalformedSnapshotFallsThrough() {
        #expect(AgentRowLayoutSnapshot.decode(nil) == nil)
        for json in ["", "not json", "[]", "null", "{}", #"{"v":2}"#,
                     #"{"v":"1"}"#, #"{"v":1,"agent_panel_sort":"unknown"}"#,
                     #"{"v":1,"sidebar":{"agents":{"rows":[["agent"]]}}}"#,
                     #"{"v":1,"sidebar":{"agents":{"row_gap":-1}}}"#,
                     #"{"v":1,"sidebar":{"agents":{"row_gap":65536}}}"#,
                     #"{"v":1,"sidebar":{"agents":{"row_gap":0.5}}}"#] {
            #expect(AgentRowLayoutSnapshot.decode(Data(json.utf8)) == nil)
        }
    }

    @Test func layoutLimitsApplyBeforeUnknownTokensAreDropped() throws {
        let unknown = ["token": "future"]
        for rows in [Array(repeating: [unknown], count: 17), [Array(repeating: unknown, count: 17)]] {
            for key in ["rows", "rows_by_agent"] {
                let value: Any = key == "rows" ? rows : ["claude": rows]
                let data = try JSONSerialization.data(withJSONObject: [
                    "v": 1, "sidebar": ["agents": [key: value]],
                ])
                #expect(AgentRowLayoutSnapshot.decode(data) == nil)
            }
        }
        let boundary = AgentRowLayout(rows: Array(repeating: Array(repeating: .init(.agent), count: 16), count: 16),
                                      rowGap: 65535)
        let encoded = try JSONEncoder().encode(boundary)
        #expect(try JSONDecoder().decode(AgentRowLayout.self, from: encoded) == boundary)
    }

    @Test func emptyLayoutsAndOverridesRemainIntentional() throws {
        let snapshot = try #require(AgentRowLayoutSnapshot.decode(Data(#"""
            {"v":1,"sidebar":{"agents":{"rows":[],"rows_by_agent":{"claude":[]}}}}
            """#.utf8)))
        #expect(snapshot.layout.rows.isEmpty)
        #expect(snapshot.layout.rows(forAgentKind: "claude").isEmpty)
    }

    @Test func tokenNamesValidateASCIIAndRetainCustomPrefix() throws {
        for token in AgentRowToken.builtins + [.custom("pin_icon"), .custom(String(repeating: "a", count: 32))] {
            #expect(AgentRowToken(rawValue: token.rawValue) == token)
            #expect(try JSONDecoder().decode(AgentRowToken.self, from: JSONEncoder().encode(token)) == token)
        }
        for name in ["pin_icon", "$", "$$pin", "$a b", "$café", "$中文", "$" + String(repeating: "a", count: 33)] {
            #expect(AgentRowToken(rawValue: name) == nil)
        }
    }

    @Test func hexColorsAcceptOnlyRGBAndRRGGBB() throws {
        let short = try #require(HexColor("#aBc"))
        let long = try #require(HexColor("#aabbcc"))
        #expect(short.red == 170 && short.green == 187 && short.blue == 204)
        #expect(short.red == long.red && short.green == long.green && short.blue == long.blue)
        #expect(short.rawValue == "#aBc")
        #expect(try JSONDecoder().decode(HexColor.self, from: JSONEncoder().encode(short)) == short)
        for value in ["abc", "#ab", "#abcd", "#aabbccdd", " #abc", "#abc\n", "#ggg", "#+ff", "#１２３"] {
            #expect(HexColor(value) == nil)
        }
    }
}

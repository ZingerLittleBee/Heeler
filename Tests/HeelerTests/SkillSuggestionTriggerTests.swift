import Foundation
import Testing

@testable import Heeler

@Suite("skill suggestion trigger")
struct SkillSuggestionTriggerTests {
    private static func skill(
        _ name: String, prefix: String = "/", description: String? = nil
    ) -> AgentSkill {
        AgentSkill(
            scope: .project, name: name, description: description,
            commandPrefix: prefix)
    }

    // MARK: Detection

    @Test func detectsAPrefixAtTheStartOfTheDraft() {
        let trigger = SkillSuggestionTrigger.detect(draft: "/re", prefixes: ["/"])
        #expect(trigger == SkillSuggestionTrigger(token: "/re", prefix: "/"))
        #expect(trigger?.query == "re")
    }

    @Test func detectsAPrefixAfterWhitespaceAndNewlines() {
        #expect(
            SkillSuggestionTrigger.detect(draft: "fix this /rev", prefixes: ["/"])
                == SkillSuggestionTrigger(token: "/rev", prefix: "/"))
        #expect(
            SkillSuggestionTrigger.detect(draft: "line one\n$pd", prefixes: ["$"])
                == SkillSuggestionTrigger(token: "$pd", prefix: "$"))
    }

    @Test func aPrefixInsideATokenDoesNotTrigger() {
        #expect(SkillSuggestionTrigger.detect(draft: "path/to", prefixes: ["/"]) == nil)
        #expect(SkillSuggestionTrigger.detect(draft: "us$", prefixes: ["$"]) == nil)
    }

    @Test func anEmptyOrCompletedTokenDoesNotTrigger() {
        #expect(SkillSuggestionTrigger.detect(draft: "", prefixes: ["/"]) == nil)
        // The trailing space after an insertion ends the token, so the menu
        // closes itself once a suggestion lands.
        #expect(SkillSuggestionTrigger.detect(draft: "/review ", prefixes: ["/"]) == nil)
    }

    @Test func theLongestPrefixWins() {
        #expect(
            SkillSuggestionTrigger.detect(draft: "/skill:pd", prefixes: ["/", "/skill:"])
                == SkillSuggestionTrigger(token: "/skill:pd", prefix: "/skill:"))
    }

    @Test func withoutAMatchingPrefixThereIsNoTrigger() {
        #expect(SkillSuggestionTrigger.detect(draft: "$pdf", prefixes: ["/"]) == nil)
        #expect(SkillSuggestionTrigger.detect(draft: "review", prefixes: ["/", "$"]) == nil)
    }

    // MARK: Filtering

    @Test func aBarePrefixOffersEverySkillOnThatPrefix() {
        let skills = [
            Self.skill("code-review"),
            Self.skill("tdd"),
            Self.skill("pdf-tools", prefix: "$"),
        ]
        let trigger = SkillSuggestionTrigger(token: "/", prefix: "/")
        #expect(trigger.matches(in: skills).map(\.name) == ["code-review", "tdd"])
    }

    @Test func codexTokensMatchOnlyDollarSkills() {
        let skills = [
            Self.skill("pdf-tools", prefix: "$"),
            Self.skill("pdf-render"),
        ]
        let trigger = SkillSuggestionTrigger(token: "$pdf", prefix: "$")
        #expect(trigger.matches(in: skills).map(\.name) == ["pdf-tools"])
    }

    @Test func typingFiltersByNameAndDescriptionCaseInsensitively() {
        let skills = [
            Self.skill("code-review", description: "Review a pull request"),
            Self.skill("tdd", description: "REVIEW nothing, test first"),
            Self.skill("deploy", description: nil),
        ]
        let trigger = SkillSuggestionTrigger(token: "/Rev", prefix: "/")
        #expect(trigger.matches(in: skills).map(\.name) == ["code-review", "tdd"])
    }

    @Test func aPartialMultiCharacterPrefixStillOffersItsSkills() {
        let skills = [Self.skill("web", prefix: "/skill:")]
        let trigger = SkillSuggestionTrigger(token: "/sk", prefix: "/")
        #expect(trigger.matches(in: skills).map(\.name) == ["web"])
    }

    @Test func anUnmatchedQueryOffersNothing() {
        let skills = [Self.skill("code-review", description: "Review a pull request")]
        let trigger = SkillSuggestionTrigger(token: "/zzz", prefix: "/")
        #expect(trigger.matches(in: skills).isEmpty)
    }
}

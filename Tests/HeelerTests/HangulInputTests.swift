import Testing

@testable import Heeler

/// The iOS Korean keyboard commits jamo into a terminal and leaves syllable
/// building to the text system; these are the edits the terminal applies.
/// Sequences recorded from the iOS 26 Korean keyboard in the simulator.
@Suite("Hangul input composition")
struct HangulInputTests {
    @Test(arguments: [
        ("하", "ㄴ", "한"), ("그", "ㄹ", "글"), ("지", "ㅇ", "징"),
    ] as [(Character, Character, Character)])
    func finalConsonantJoinsTheOpenSyllable(base: Character, jamo: Character, composed: Character) {
        let finalIndex = HangulInput.finalIndexByJamo[jamo] ?? 0
        #expect(HangulInput.composeSyllable(base: base, finalIndex: finalIndex) == composed)
    }

    @Test(arguments: [
        ("우", "ㅓ", "워"), ("오", "ㅏ", "와"), ("개", "ㅣ", nil), ("으", "ㅣ", "의"),
        ("구", "ㅔ", "궤"), ("운", "ㅓ", nil),
    ] as [(Character, Character, Character?)])
    func compoundVowelJoinsAnOpenSyllable(base: Character, vowel: Character, composed: Character?) {
        #expect(HangulInput.composeCompoundVowel(base: base, followingVowel: vowel) == composed)
    }

    @Test(arguments: [
        ("달", "ㄱ", "닭"), ("안", "ㅈ", "앉"), ("괜", "ㅎ", "괞"), ("값", "ㅅ", nil),
        ("하", "ㄱ", nil), ("갑", "ㅅ", "값"),
    ] as [(Character, Character, Character?)])
    func doubleFinalJoinsAnExistingFinal(base: Character, consonant: Character, composed: Character?) {
        #expect(HangulInput.composeDoubleFinal(base: base, consonant: consonant) == composed)
    }

    @Test func vowelAfterAFinalMovesItToTheNextSyllable() {
        let edit = HangulInput.resyllabificationEdit(base: "핫", followingVowel: "ㅔ")
        #expect(edit == .init(charactersToDelete: 1, textToInsert: "하세"))
        #expect(HangulInput.resyllabificationEdit(base: "닭", followingVowel: "ㅣ")?.textToInsert == "달기")
    }

    /// "지원": after "징" the keyboard selects " 징", deletes it, reinserts
    /// " ", then commits "우" — the terminal must end with " 지우".
    @Test func keyboardResyllabificationReplacesThePrefix() {
        var transaction = HangulInput.ResyllabificationTransaction()
        transaction.begin(deletedText: " 징")
        #expect(transaction.consumeInsertion(" ") == .prefixReinserted)
        #expect(transaction.consumeInsertion("우") == .replacement(
            .init(charactersToDelete: 1, textToInsert: " 지우")))
    }

    @Test func unexpectedInsertionEndsTheTransaction() {
        var transaction = HangulInput.ResyllabificationTransaction()
        transaction.begin(deletedText: " 징")
        #expect(transaction.consumeInsertion("x") == .noMatch)
        #expect(transaction.consumeInsertion("우") == .noMatch)
    }
}

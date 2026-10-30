import Testing
@testable import PrismCore

@Suite struct DictationTermsTests {
    @Test func onlyWhatElevenLabsTakes() {
        let terms = Dictation.terms(from: ["Ana", "Future of Software Engineering", "ana", " Venue plan ", "", "Twenty chars exactly"])
        #expect(terms == ["Ana", "Venue plan", "Twenty chars exactly"])
        #expect(terms.allSatisfy { $0.count <= Dictation.termLength })
    }

    @Test func noMoreThanItTakes() {
        #expect(Dictation.terms(from: (0..<80).map { "Note \($0)" }).count == Dictation.termLimit)
    }
}

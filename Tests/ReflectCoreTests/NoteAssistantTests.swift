import Testing
import ReflectCore

@Suite struct NoteAssistantTests {
    @Test func aSummaryGoesAtTheTopAndReplacesTheLast() {
        let note = "# Design review\n\n- When: today\n- Notes\n"
        let once = NoteAssistant.withSummary(["Ship the cards", "Ana leads"], in: note)!
        #expect(once == "# Design review\n\n- Summary\n  - Ship the cards\n  - Ana leads\n- When: today\n- Notes\n")
        let twice = NoteAssistant.withSummary(["Ship it"], in: once)!
        #expect(twice == "# Design review\n\n- Summary\n  - Ship it\n- When: today\n- Notes\n")
    }

    @Test func tasksFoundGoAtTheEndOnce() {
        let note = "# Review\n\n- Notes\n  + [ ] Send the deck\n"
        let after = NoteAssistant.withTasks(["Send the deck", "Book the room"], in: note)!
        #expect(after == "# Review\n\n- Notes\n  + [ ] Send the deck\n- Actions\n  + [ ] Book the room\n")
        #expect(NoteAssistant.withTasks(["Send the deck"], in: note) == nil)
    }
}

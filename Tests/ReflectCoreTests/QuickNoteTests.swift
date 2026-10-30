import Testing
@testable import ReflectCore

@Suite struct QuickNoteTests {
    @Test func eachLineABulletAtTheTop() {
        let rows = QuickNote.rows("  Call Ana about the venue \n\n- not a list\n")
        #expect(QuickNote.prepending(rows, toDay: "- Coffee\n") == "- Call Ana about the venue\n- not a list\n- Coffee\n")
    }

    @Test func afterTheTitleAndIntoABlankDay() {
        let rows = QuickNote.rows("Buy milk")
        #expect(QuickNote.prepending(rows, toDay: "# Tuesday\n\n- x\n") == "# Tuesday\n\n- Buy milk\n- x\n")
        #expect(QuickNote.prepending(rows, toDay: "") == "- Buy milk\n")
        #expect(QuickNote.prepending(rows, toDay: "- \n") == "- Buy milk\n")
    }

    @Test func nothingToAddLeavesTheDay() {
        #expect(QuickNote.rows(" \n\n ").isEmpty)
        #expect(QuickNote.prepending([], toDay: "- x\n") == "- x\n")
    }
}

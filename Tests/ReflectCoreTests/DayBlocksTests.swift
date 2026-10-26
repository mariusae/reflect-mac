import Testing
@testable import ReflectCore

struct DayBlocksTests {
    let day = """
    - Morning
    - Timeblocks
      - 1-2pm do the first task
      - 2pm-2:30pm do the second one
        - [ ] Subtask 1
        - [x] Subtask 2
      - 4-5pm wind down
    - Evening

    """

    @Test func readsTheBlocks() {
        let blocks = DayBlocks.blocks(in: day)
        #expect(blocks.map(\.start) == [13 * 60, 14 * 60, 16 * 60])
        #expect(blocks.map(\.end) == [14 * 60, 14 * 60 + 30, 17 * 60])
        #expect(blocks.map(\.title) == ["do the first task", "do the second one", "wind down"])
        #expect(blocks[1].items.map(\.text) == ["Subtask 1", "Subtask 2"])
        #expect(blocks[1].items.map { $0.task?.isDone } == [false, true])
    }

    @Test func noneWithoutTheBullet() {
        #expect(DayBlocks.blocks(in: "- 1-2pm not under it\n").isEmpty)
    }

    @Test func addsInOrderOfTime() {
        let after = DayBlocks.adding(start: 15 * 60, end: 15 * 60 + 30, title: "Review", to: day)
        #expect(DayBlocks.blocks(in: after).map(\.title) == ["do the first task", "do the second one", "Review", "wind down"])
        #expect(after.contains("  - 3pm-3:30pm Review\n  - 4-5pm wind down"))
        #expect(after.hasSuffix("- Evening\n"))
    }

    @Test func makesTheBulletOnAnEmptyDay() {
        let after = DayBlocks.adding(start: 9 * 60, end: 10 * 60, title: "Deep work", checklist: true, to: "- \n")
        #expect(after.hasPrefix("- Timeblocks\n  - [ ] "))
        let blocks = DayBlocks.blocks(in: after)
        #expect(blocks.count == 1)
        #expect(blocks[0].task == .open)
        #expect(blocks[0].title == "Deep work")
    }

    @Test func retimesKeepingItsItems() {
        let second = DayBlocks.blocks(in: day)[1]
        let after = DayBlocks.retiming(row: second.row, start: 17 * 60, end: 18 * 60, in: day)
        let blocks = DayBlocks.blocks(in: after)
        #expect(blocks.map(\.title) == ["do the first task", "wind down", "do the second one"])
        #expect(blocks[2].start == 17 * 60)
        #expect(blocks[2].items.count == 2)
    }

    @Test func movesATaskIntoADay() {
        let note = "- Project\n  + [ ] Write the plan\n    - a detail\n  - other\n"
        let (left, task) = DayBlocks.takingTask(ordinal: 0, from: note)!
        #expect(left == "- Project\n  - other\n")
        let after = DayBlocks.inserting(task, start: 10 * 60, end: 11 * 60, into: day)
        let blocks = DayBlocks.blocks(in: after)
        #expect(blocks.first?.title == "Write the plan")
        #expect(blocks.first?.task == .open)
        #expect(blocks.first?.items.map(\.text) == ["a detail"])
        #expect(after.contains("  + [ ] 10am-11am Write the plan\n    - a detail\n"))
    }

    @Test func movesABlockToAnotherDay() {
        let first = DayBlocks.blocks(in: day)[0]
        let (left, subtree) = DayBlocks.removing(row: first.row, from: day)!
        #expect(DayBlocks.blocks(in: left).count == 2)
        let other = DayBlocks.inserting(subtree, start: 9 * 60, end: 10 * 60, into: "- \n")
        #expect(DayBlocks.blocks(in: other).map(\.title) == ["do the first task"])
        #expect(DayBlocks.blocks(in: other)[0].start == 9 * 60)
    }

    @Test func titlesAndItems() {
        let first = DayBlocks.blocks(in: day)[0]
        var after = DayBlocks.settingTitle(row: first.row, to: "renamed", in: day)
        #expect(DayBlocks.blocks(in: after)[0].title == "renamed")
        after = DayBlocks.addingItem("check", under: first.row, in: after)
        #expect(DayBlocks.blocks(in: after)[0].items.map(\.text) == ["check"])
        after = DayBlocks.settingTask(row: first.row, to: .open, in: after)
        #expect(DayBlocks.blocks(in: after)[0].task == .open)
    }
}

@testable import CPUCore
import Foundation
import Testing

struct TaskStoreTests {
    private func store() -> TaskStore {
        TaskStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("cpu-tests-\(UUID().uuidString)"))
    }

    @Test func shortcutNameExpandsToItsRequest() {
        let store = store()
        store.saveShortcut(name: "日报", request: "把 POPO 项目群今天的讨论整理到备忘录")
        #expect(store.expand("日报") == "把 POPO 项目群今天的讨论整理到备忘录")
        #expect(store.expand(" 日报。") == "把 POPO 项目群今天的讨论整理到备忘录")
        #expect(store.expand("写日报") == nil)
    }

    @Test func repeatPhraseExpandsToLastTask() {
        let store = store()
        #expect(store.expand("再做一次") == nil)
        store.record(TaskRecord(request: "用计算器算 37 乘以 3", title: "", result: "111", succeeded: true, date: Date()))
        #expect(store.expand("再做一次") == "用计算器算 37 乘以 3")
        #expect(store.expand("像上次那样！") == "用计算器算 37 乘以 3")
    }

    @Test func historyKeepsOneEntryPerRequest() {
        let store = store()
        store.record(TaskRecord(request: "A 任务", title: "", result: "", succeeded: true, date: Date()))
        store.record(TaskRecord(request: "B 任务", title: "", result: "", succeeded: true, date: Date()))
        store.record(TaskRecord(request: "a任务", title: "", result: "again", succeeded: true, date: Date()))
        #expect(store.history.map(\.request) == ["a任务", "B 任务"])
    }

    @Test func storeSurvivesReload() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-tests-\(UUID().uuidString)")
        TaskStore(directory: directory).saveShortcut(name: "六七", request: "用计算器算 6 乘以 7")
        TaskStore(directory: directory).saveTrajectory(["calls": [["tool": "open"]]], for: "用计算器算 6 乘以 7")
        let reloaded = TaskStore(directory: directory)
        #expect(reloaded.expand("六七") == "用计算器算 6 乘以 7")
        #expect(reloaded.trajectory(for: "用计算器算6乘以7") != nil)
    }

    @Test func onlyContextFreeRequestsAreReplayed() {
        #expect(Agent.isReplayable("用计算器算 37 乘以 3"))
        #expect(Agent.isReplayable("给王宁发微信说收到"))
        #expect(!Agent.isReplayable("把这封邮件里的会议加到日历"))
        #expect(!Agent.isReplayable("查一下明天上海的天气"))
        #expect(!Agent.isReplayable("Summarize the selected text"))
    }
}

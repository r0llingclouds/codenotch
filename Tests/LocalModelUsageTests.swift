import XCTest
@testable import Codenotch

final class LocalModelUsageTests: XCTestCase {
    private func codexTurn(_ model: String) -> String {
        #"{"timestamp":"2026-10-07T19:30:28.816Z","ordinal":7,"type":"turn_context","payload":{"turn_id":"t","model":"\#(model)","effort":"high"}}"#
    }

    private func codexTokens(at time: String, total: Int, input: Int, cached: Int, output: Int) -> String {
        #"{"timestamp":"2026-10-07T\#(time)Z","ordinal":15,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}},"rate_limits":{"limit_id":"codex"}}}"#
    }

    private func claudeLine(id: String, model: String = "claude-opus-5-5", at time: String = "18:45:04.648",
                            input: Int, written: Int, cached: Int, output: Int, type: String = "assistant") -> String {
        #"{"parentUuid":"p","isSidechain":false,"message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"\"output_tokens\": is only text here"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(written),"cache_read_input_tokens":\#(cached),"output_tokens":\#(output)}},"requestId":"r","type":"\#(type)","timestamp":"2026-10-07T\#(time)Z"}"#
    }

    func testCodexCountsEachResponseOnceUnderTheModelOfItsTurn() {
        let log = [codexTurn("gpt-6.1-sol"),
                   codexTokens(at: "19:30:40.409", total: 1_100, input: 1_000, cached: 600, output: 100),
                   // Sent again when only the rate limits changed.
                   codexTokens(at: "19:30:41.000", total: 1_100, input: 1_000, cached: 600, output: 100),
                   #"{"timestamp":"2026-10-07T19:30:42.000Z","type":"response_item","payload":{"type":"message","text":"\"type\":\"token_count\" quoted in a reply"}}"#,
                   codexTokens(at: "19:31:05", total: 1_650, input: 500, cached: 0, output: 50),
                   codexTurn("gpt-6-astra"),
                   codexTokens(at: "19:40:00.000", total: 1_950, input: 250, cached: 250, output: 50)]
        let complete = Data((log.joined(separator: "\n") + "\n").utf8)
        var state = ModelUsageLog.CodexState()
        var records: [ModelUsageRecord] = []
        // A line still being written is left for the next read.
        let partial = complete + Data(codexTokens(at: "19:41:00.000", total: 9_999, input: 1, cached: 0, output: 1).utf8.prefix(60))
        XCTAssertEqual(ModelUsageLog.codex(partial, state: &state, into: &records), complete.count)
        XCTAssertEqual(records.map(\.model), ["gpt-6.1-sol", "gpt-6.1-sol", "gpt-6-astra"])
        XCTAssertEqual(records.map(\.tokens), [
            ModelTokens(input: 400, cached: 600, output: 100, responses: 1),
            ModelTokens(input: 500, cached: 0, output: 50, responses: 1),
            ModelTokens(input: 0, cached: 250, output: 50, responses: 1)])
        XCTAssertEqual(state, .init(model: "gpt-6-astra", total: 1_950))

        // What is appended later continues the same turn and the same total.
        let grown = complete + Data((codexTokens(at: "19:41:00.000", total: 2_000, input: 40, cached: 0, output: 10) + "\n").utf8)
        XCTAssertEqual(ModelUsageLog.codex(grown, from: complete.count, state: &state, into: &records), grown.count)
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.last?.model, "gpt-6-astra")
        XCTAssertEqual(records.last?.tokens.total, 50)
    }

    func testClaudeCountsAStreamedOrCopiedResponseOnce() {
        let first = [claudeLine(id: "msg_1", input: 2, written: 100, cached: 5_000, output: 10),
                     // The same response, one content block later.
                     claudeLine(id: "msg_1", at: "18:45:05.905", input: 2, written: 100, cached: 5_000, output: 320),
                     claudeLine(id: "msg_2", model: "claude-fable-5-1", input: 10, written: 0, cached: 0, output: 40),
                     claudeLine(id: "msg_3", model: "<synthetic>", input: 0, written: 0, cached: 0, output: 0),
                     claudeLine(id: "msg_4", input: 9, written: 9, cached: 9, output: 9, type: "user")]
        var records: [String: ModelUsageRecord] = [:]
        let data = Data((first.joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(ModelUsageLog.claude(data, into: &records), data.count)
        XCTAssertEqual(Set(records.keys), ["msg_1", "msg_2"])
        XCTAssertEqual(records["msg_1"]?.tokens, ModelTokens(input: 102, cached: 5_000, output: 320, responses: 1))
        XCTAssertEqual(records["msg_2"]?.model, "claude-fable-5-1")

        // A resumed session copies the earlier messages into its own file.
        var resumed: [String: ModelUsageRecord] = [:]
        _ = ModelUsageLog.claude(Data((claudeLine(id: "msg_1", input: 2, written: 100, cached: 5_000, output: 320) + "\n").utf8), into: &resumed)
        records.merge(resumed) { ModelUsageLog.merged($0, $1) }
        XCTAssertEqual(records.values.reduce(0) { $0 + $1.tokens.total }, 422 + 50)
    }

    func testTrendsBucketByLocalDayHeaviestModelFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9))!
        func record(_ model: String, day: Int, hour: Int, _ tokens: Int) -> ModelUsageRecord {
            ModelUsageRecord(date: calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!,
                             model: model, tokens: ModelTokens(input: tokens, cached: 0, output: 0, responses: 1))
        }
        let trends = ModelUsageLog.trends([
            record("gpt-6-astra", day: 6, hour: 23, 10), record("gpt-6-astra", day: 7, hour: 1, 5),
            record("gpt-6.1-sol", day: 7, hour: 12, 100), record("gpt-6.1-sol", day: 5, hour: 12, 999),
            record("idle", day: 7, hour: 12, 0)], from: start, through: end, calendar: calendar)
        XCTAssertEqual(trends.map(\.name), ["Sol 6.1", "Astra 6"])
        XCTAssertEqual(trends.map(\.tokens.total), [100, 15])
        XCTAssertEqual(trends[1].days.map(\.consumed), [10, 5, nil])
        XCTAssertEqual(trends[1].days.map(\.readings), [1, 1, 0])
    }

    func testModelNamesAreDerivedFromTheirIdentifiers() {
        let names = ["claude-opus-5-5": "Opus 5.5", "claude-fable-5-1": "Fable 5.1",
                     "claude-haiku-4-5-20251001": "Haiku 4.5", "claude-3-5-sonnet-20241022": "Sonnet 3.5",
                     "gpt-6.1-sol": "Sol 6.1", "gpt-6-astra": "Astra 6", "gpt-5.3-codex-spark": "Codex Spark 5.3",
                     "codex-auto-review": "Codex Auto Review", "gpt-5": "GPT 5"]
        for (model, name) in names { XCTAssertEqual(ModelUsageTrend.name(for: model), name) }
    }

    func testTheNewestVersionOfAFamilyTakesItsCard() {
        func trend(_ model: String) -> ModelUsageTrend {
            ModelUsageTrend(model: model, tokens: ModelTokens(input: 1, cached: 0, output: 0, responses: 1), days: [])
        }
        let codex = ["gpt-6-sol", "gpt-6.1-sol", "gpt-5.6-sol", "gpt-6-astra", "codex-auto-review"].map(trend)
        XCTAssertEqual(ModelUsageTrend.newest(of: "sol", in: codex)?.model, "gpt-6.1-sol")
        XCTAssertEqual(ModelUsageTrend.newest(of: "astra", in: codex)?.model, "gpt-6-astra")
        let claude = ["claude-opus-5", "claude-opus-5-5", "claude-opus-4-8", "claude-haiku-4-5-20251001"].map(trend)
        XCTAssertEqual(ModelUsageTrend.newest(of: "opus", in: claude)?.model, "claude-opus-5-5")
        XCTAssertNil(ModelUsageTrend.newest(of: "fable", in: claude), "A model that did not run has no card to take")
        XCTAssertEqual(ModelUsageTrend.version(of: "claude-haiku-4-5-20251001"), [4, 5])
        XCTAssertEqual(ModelLineup.known["codex"], ModelLineup(flagship: "astra", standard: "sol"))
        XCTAssertEqual(ModelLineup.known["claude"], ModelLineup(flagship: "fable", standard: "opus"))
    }

    func testReadsOnlyWhatWasAppendedAndDropsACopiedMessageAcrossFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions/2026/10/07")
        let project = home.appendingPathComponent(".claude/projects/-Users-someone-project")
        let subagents = project.appendingPathComponent("session/subagents")
        for directory in [sessions, subagents] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let from = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let through = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 23))!
        let rollout = sessions.appendingPathComponent("rollout-1.jsonl")
        let codexLog = [codexTurn("gpt-6.1-sol"), codexTokens(at: "12:00:00.000", total: 300, input: 250, cached: 50, output: 50)]
        try Data((codexLog.joined(separator: "\n") + "\n").utf8).write(to: rollout)
        try Data((claudeLine(id: "msg_1", input: 10, written: 0, cached: 0, output: 90) + "\n").utf8)
            .write(to: project.appendingPathComponent("first.jsonl"))
        try Data(([claudeLine(id: "msg_1", input: 10, written: 0, cached: 0, output: 90),
                   claudeLine(id: "msg_2", input: 5, written: 0, cached: 0, output: 5)].joined(separator: "\n") + "\n").utf8)
            .write(to: subagents.appendingPathComponent("agent-1.jsonl"))
        let reader = LocalModelUsage(home: home)
        let codex = await reader.usage(providerID: "codex", from: from, through: through, calendar: calendar)
        XCTAssertEqual(codex.map(\.model), ["gpt-6.1-sol"])
        XCTAssertEqual(codex.first?.tokens, ModelTokens(input: 200, cached: 50, output: 50, responses: 1))
        XCTAssertEqual(codex.first?.days.count, 7)
        let claude = await reader.usage(providerID: "claude", from: from, through: through, calendar: calendar)
        XCTAssertEqual(claude.first?.tokens.total, 110)
        XCTAssertEqual(claude.first?.tokens.responses, 2)

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((codexTokens(at: "12:05:00.000", total: 400, input: 80, cached: 0, output: 20) + "\n").utf8))
        try handle.close()
        let grown = await reader.usage(providerID: "codex", from: from, through: through, calendar: calendar)
        XCTAssertEqual(grown.first?.tokens, ModelTokens(input: 280, cached: 50, output: 70, responses: 2))
        // Nothing outside the period is reported, however much was read.
        let earlier = await reader.usage(providerID: "codex", from: from, through: from.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertTrue(earlier.isEmpty)
    }
}

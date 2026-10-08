import Foundation

/// Tokens a model spent, as the CLI that ran it logged them on this Mac.
struct ModelTokens: Equatable, Sendable {
    /// Input the model read fresh, including what it wrote to the cache.
    var input = 0
    /// Input served from the cache.
    var cached = 0
    var output = 0
    var responses = 0

    /// Uncached input plus output, the total Codex itself reports for a
    /// session. Cache reads stay apart: an agent re-reads its whole context on
    /// every step, and counting that would bury the work actually done.
    var total: Int { input + output }

    static func += (lhs: inout Self, rhs: Self) {
        lhs.input += rhs.input; lhs.cached += rhs.cached
        lhs.output += rhs.output; lhs.responses += rhs.responses
    }
}

struct ModelUsageRecord: Equatable, Sendable {
    let date: Date
    let model: String
    var tokens: ModelTokens
}

struct ModelUsageTrend: Identifiable, Equatable, Sendable {
    var id: String { model }
    let model: String
    let tokens: ModelTokens
    /// `consumed` is the day's token total and `readings` its responses.
    let days: [UsageHistoryDay]
    var name: String { Self.name(for: model) }

    /// `claude-opus-5-5` → "Opus 5.5", `gpt-6.1-sol` → "Sol 6.1". Derived
    /// rather than listed, so a model released tomorrow needs no app update.
    static func name(for model: String) -> String {
        var parts = model.split(separator: "-").map(String.init)
        // A trailing release date is not part of the name.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        let vendor = ["claude", "gpt"].contains(parts.first ?? "") ? parts.removeFirst() : nil
        let version = parts.filter { $0.first?.isNumber == true }.joined(separator: ".")
        let words = parts.filter { $0.first?.isNumber != true }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let title = words.isEmpty ? [vendor?.uppercased() ?? model] : words
        return (title + [version]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func compact(_ tokens: Double) -> String {
        tokens.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// The numbers in a model's identifier: `gpt-6.1-sol` is 6.1.
    static func version(of model: String) -> [Int] {
        model.split(separator: "-").filter { $0.first?.isNumber == true && $0.count < 8 }
            .flatMap { $0.split(separator: ".") }.compactMap { Int($0) }
    }

    /// The latest version of a model family that ran in the period.
    static func newest(of family: String, in trends: [ModelUsageTrend]) -> ModelUsageTrend? {
        trends.filter { $0.model.split(separator: "-").contains(Substring(family)) }
            .max { version(of: $0.model).lexicographicallyPrecedes(version(of: $1.model)) }
    }
}

/// The two models a service is built around: the strongest it sells and the
/// one most work runs on. Named by family, so a new version takes over the
/// card of the one it replaces without a change here.
struct ModelLineup: Equatable, Sendable {
    let flagship: String
    let standard: String

    static let known = ["claude": ModelLineup(flagship: "fable", standard: "opus"),
                        "codex": ModelLineup(flagship: "astra", standard: "sol")]
}

/// How each CLI writes a response's tokens into its session log.
enum ModelUsageLog {
    /// What carries over between two reads of one growing Codex session.
    struct CodexState: Equatable, Sendable {
        var model: String?
        var total: Int?
    }

    private struct CodexLine: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let output_tokens: Int?
            let total_tokens: Int?
        }
        struct Info: Decodable {
            let total_token_usage: Usage?
            let last_token_usage: Usage?
        }
        struct Payload: Decodable {
            let type: String?
            let model: String?
            let info: Info?
        }
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct ClaudeLine: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
        }
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        let timestamp: String?
        let type: String?
        let message: Message?
    }

    /// Reads the responses logged after `offset` and returns where the last
    /// complete line ended, so a line still being written is read next time.
    ///
    /// A turn names its model once and every response after it reports the
    /// tokens it added. Codex repeats that report when only the rate limits
    /// changed, which the unchanged session total gives away.
    static func codex(_ data: Data, from offset: Int = 0, state: inout CodexState,
                      into records: inout [ModelUsageRecord]) -> Int {
        let decoder = JSONDecoder()
        // Both markers sit in a line's opening fields; the rest of a line can
        // be megabytes of tool output that never needs to be looked at.
        return lines(in: data, from: offset, containing: [#""type":"turn_context""#, #""type":"token_count""#], within: 200) { line in
            guard let entry = try? decoder.decode(CodexLine.self, from: line) else { return }
            if entry.type == "turn_context" {
                if let model = entry.payload?.model { state.model = model }
                return
            }
            guard entry.payload?.type == "token_count", let info = entry.payload?.info,
                  let total = info.total_token_usage?.total_tokens, let last = info.last_token_usage else { return }
            defer { state.total = total }
            guard total != state.total, let model = state.model,
                  let logged = entry.timestamp.flatMap(instant(from:)) else { return }
            let cached = min(last.cached_input_tokens ?? 0, last.input_tokens ?? 0)
            records.append(ModelUsageRecord(date: logged, model: model, tokens: ModelTokens(
                input: (last.input_tokens ?? 0) - cached, cached: cached, output: last.output_tokens ?? 0, responses: 1)))
        }
    }

    /// Reads the responses logged after `offset`, keyed by message.
    ///
    /// Claude Code writes one line per content block, each carrying the
    /// response's usage as it stood, and copies earlier messages into the new
    /// file when a session is resumed. Keying by message is what keeps either
    /// from being counted twice.
    static func claude(_ data: Data, from offset: Int = 0, into records: inout [String: ModelUsageRecord]) -> Int {
        let decoder = JSONDecoder()
        return lines(in: data, from: offset, containing: [#""output_tokens":"#], within: nil) { line in
            guard let entry = try? decoder.decode(ClaudeLine.self, from: line), entry.type == "assistant",
                  let message = entry.message, let id = message.id, let usage = message.usage,
                  let model = message.model, model != "<synthetic>",
                  let logged = entry.timestamp.flatMap(instant(from:)) else { return }
            let record = ModelUsageRecord(date: logged, model: model, tokens: ModelTokens(
                input: (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0),
                cached: usage.cache_read_input_tokens ?? 0, output: usage.output_tokens ?? 0, responses: 1))
            records[id] = merged(records[id], record)
        }
    }

    /// The fuller of two copies of one response: its output count grows while it streams.
    static func merged(_ existing: ModelUsageRecord?, _ record: ModelUsageRecord) -> ModelUsageRecord {
        guard let existing, existing.tokens.total >= record.tokens.total else { return record }
        return existing
    }

    /// One trend per model with any tokens in the period, heaviest first.
    static func trends(_ records: some Sequence<ModelUsageRecord>, from start: Date, through end: Date,
                       calendar: Calendar = .current) -> [ModelUsageTrend] {
        var days: [Date] = []
        var date = calendar.startOfDay(for: start)
        while date <= end {
            days.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        var models: [String: [Date: ModelTokens]] = [:]
        for record in records where record.date >= start && record.date <= end {
            models[record.model, default: [:]][calendar.startOfDay(for: record.date), default: ModelTokens()] += record.tokens
        }
        var trends: [ModelUsageTrend] = []
        for (model, byDay) in models {
            var total = ModelTokens()
            for tokens in byDay.values { total += tokens }
            guard total.total > 0 else { continue }
            let history = days.map { day -> UsageHistoryDay in
                let tokens = byDay[day]
                return UsageHistoryDay(date: day, readings: tokens?.responses ?? 0, peak: nil,
                                       consumed: tokens.map { Double($0.total) })
            }
            trends.append(ModelUsageTrend(model: model, tokens: total, days: history))
        }
        return trends.sorted { $0.tokens.total != $1.tokens.total ? $0.tokens.total > $1.tokens.total : $0.model < $1.model }
    }

    private static func instant(from text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }

    /// Hands `body` each complete line after `offset` that holds one of
    /// `needles` in its first `window` bytes, and returns where the last
    /// complete line ended.
    private static func lines(in data: Data, from offset: Int, containing needles: [String], within window: Int?,
                              _ body: (Data) -> Void) -> Int {
        let needles = needles.map { Array($0.utf8) }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else { return offset }
            var start = min(max(0, offset), buffer.count)
            while start < buffer.count, let newline = memchr(base + start, 0x0A, buffer.count - start) {
                let length = (base + start).distance(to: UnsafeRawPointer(newline))
                let scanned = min(length, window ?? length)
                if needles.contains(where: { memmem(base + start, scanned, $0, $0.count) != nil }) {
                    body(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: length, deallocator: .none))
                }
                start += length + 1
            }
            return start
        }
    }
}

/// How many tokens each model spent, read from the session logs its CLI keeps
/// on this Mac.
///
/// The services meter one shared allowance and say nothing about which model
/// spent it, so the logs are the only place a per-model figure exists. They
/// cover the CLI on this Mac alone: work done on another device, or in another
/// app on the same account, draws on the same quota without appearing here.
///
/// Only a response's model, time and token counts are kept. Nothing is written,
/// and no message text leaves the line it was read from.
///
/// A month of sessions runs to gigabytes, so a file is read once and after
/// that only for what was appended to it.
actor LocalModelUsage {
    private struct File: Sendable {
        var end = 0
        var codexState = ModelUsageLog.CodexState()
        var codex: [ModelUsageRecord] = []
        var claude: [String: ModelUsageRecord] = [:]
    }

    private let home: URL
    private var files: [String: File] = [:]

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) { self.home = home }

    func usage(providerID: String, from start: Date, through end: Date,
               calendar: Calendar = .current) async -> [ModelUsageTrend] {
        let codex = providerID == CodexProfile.defaultID
        let root = codex ? CodexProfile.default(home: home).configDirectory.appendingPathComponent("sessions")
                         : ClaudeProfile.default(home: home).projectsDirectory
        var read: [File] = []
        var grown: [(index: Int, url: URL)] = []
        for (url, size) in Self.logs(under: root, since: start) {
            var file = files[url.path] ?? File()
            if size < file.end { file = File() } // Replaced rather than appended to.
            if size > file.end { grown.append((read.count, url)) }
            read.append(file)
        }
        // The files are independent, so a first read is spread over every core.
        await withTaskGroup(of: (Int, File).self) { group in
            for (index, url) in grown {
                let file = read[index]
                group.addTask { (index, Task.isCancelled ? file : Self.reading(file, at: url, codex: codex)) }
            }
            for await (index, file) in group { read[index] = file }
        }
        guard !Task.isCancelled else { return [] }
        for (index, url) in grown { files[url.path] = read[index] }
        if codex { return ModelUsageLog.trends(read.lazy.flatMap(\.codex), from: start, through: end, calendar: calendar) }
        var messages: [String: ModelUsageRecord] = [:]
        for file in read {
            messages.merge(file.claude) { ModelUsageLog.merged($0, $1) }
        }
        return ModelUsageLog.trends(messages.values, from: start, through: end, calendar: calendar)
    }

    /// Session logs under `root` written since `start`, with their sizes. A
    /// session last written before the period cannot hold a response inside it.
    private static func logs(under root: URL, since start: Date) -> [(url: URL, size: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var logs: [(URL, Int)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize,
                  let modified = values.contentModificationDate, modified >= start else { continue }
            logs.append((url, size))
        }
        return logs
    }

    private static func reading(_ file: File, at url: URL, codex: Bool) -> File {
        var file = file
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return file }
        file.end = codex ? ModelUsageLog.codex(data, from: file.end, state: &file.codexState, into: &file.codex)
                         : ModelUsageLog.claude(data, from: file.end, into: &file.claude)
        return file
    }
}

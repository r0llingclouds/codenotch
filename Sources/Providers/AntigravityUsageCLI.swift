import Foundation
import os

/// Antigravity's own `/usage`, asked of the standalone `agy` CLI rather than
/// of the loopback language server or direct Cloud Code endpoint.
///
/// Modern `agy` requires a CSRF token on its loopback gRPC port without
/// advertising it on the command line, and personal Google accounts receive
/// 403 from `:retrieveUserQuotaSummary`. `agy --sandbox --print /usage` reads
/// the same official quota through the CLI's own signed-in session.
struct AntigravityUsageCLI: Sendable {
    let binary: URL
    let output: @Sendable () throws -> String

    init(binary: URL, output: @escaping @Sendable () throws -> String) {
        self.binary = binary
        self.output = output
    }

    /// Above `--print-timeout 20s` so the CLI can exit cleanly before the
    /// watchdog intervenes.
    static let timeout: TimeInterval = 25
    static let arguments = ["--sandbox", "--print-timeout", "20s", "--print", "/usage"]

    private static let searchPaths = [
        ".local/bin/agy",
        ".antigravity/bin/agy",
        ".gemini/antigravity-cli/bin/agy",
        ".gemini/antigravity/bin/agy"
    ]

    private static let systemPaths = [
        "opt/homebrew/bin/agy",
        "usr/local/bin/agy"
    ]

    /// Finds the `agy` binary even under launchd, where `PATH` excludes
    /// `~/.local/bin` and Homebrew.
    static func locate(
        home: URL = AntigravityProfile.homeDirectory,
        root: URL = URL(fileURLWithPath: "/"),
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> AntigravityUsageCLI? {
        var candidates = searchPaths.map { home.appendingPathComponent($0) }
            + systemPaths.map { root.appendingPathComponent($0) }
        if let pathEnv {
            for entry in pathEnv.split(separator: ":") {
                let dir = String(entry)
                guard dir.hasPrefix("/") else { continue }
                candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("agy"))
            }
        }
        guard let found = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else { return nil }
        return AntigravityUsageCLI(binary: found) { try run(binary: found) }
    }

    func read() async throws -> [LimitWindow] {
        let text = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try self.output() })
            }
        }
        return try Self.parse(text)
    }

    private static func run(binary: URL) throws -> String {
        let scratch = try ClaudeUsageCLI.scratchDirectory()

        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = scratch.path

        let process = Process()
        process.executableURL = binary
        process.arguments = Self.arguments
        process.currentDirectoryURL = scratch
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            Log.usage.debug("agy /usage exited \(process.terminationStatus)")
            throw UsageProviderError.needsAuth
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return text
    }

    // MARK: - Parsing

    /// Strips ANSI CSI, OSC, and 2-byte escape sequences and normalizes CR/LF.
    static func sanitize(_ input: String) -> String {
        var scalars = String.UnicodeScalarView()
        let view = input.unicodeScalars
        var index = view.startIndex
        while index < view.endIndex {
            let scalar = view[index]
            if scalar == "\u{1B}" {
                let next = view.index(after: index)
                guard next < view.endIndex else { break }
                let marker = view[next]
                if marker == "[" {
                    var cursor = view.index(after: next)
                    while cursor < view.endIndex {
                        let value = view[cursor].value
                        cursor = view.index(after: cursor)
                        if (0x40...0x7E).contains(value) { break }
                    }
                    index = cursor
                    continue
                } else if marker == "]" {
                    var cursor = view.index(after: next)
                    while cursor < view.endIndex {
                        let current = view[cursor]
                        cursor = view.index(after: cursor)
                        if current == "\u{07}" { break }
                        if current == "\u{1B}", cursor < view.endIndex, view[cursor] == "\\" {
                            cursor = view.index(after: cursor)
                            break
                        }
                    }
                    index = cursor
                    continue
                } else if (0x40...0x5F).contains(marker.value) {
                    index = view.index(after: next)
                    continue
                }
                index = next
                continue
            } else if scalar == "\r" {
                let next = view.index(after: index)
                if next < view.endIndex, view[next] == "\n" {
                    index = next
                    continue
                }
                scalars.append("\n")
            } else {
                scalars.append(scalar)
            }
            index = view.index(after: index)
        }
        return String(scalars)
    }

    private struct ParsedRow {
        let groupRank: Int
        let groupOrder: Int
        let cadenceRank: Int
        let rowOrder: Int
        let window: LimitWindow
    }

    /// Parses both current tab-separated `agy --print /usage` rows:
    ///   `Gemini Models\tWeekly Limit Remaining\t84%\t2026-11-28T11:24:27Z`
    /// and legacy space-separated rows:
    ///   `Gemini Models Weekly Limit Remaining 94% 2026-09-12T01:47:23Z`
    static func parse(_ text: String) throws -> [LimitWindow] {
        let clean = sanitize(text)
        var groupOrders: [String: Int] = [:]
        var rows: [ParsedRow] = []
        var seenIDs = Set<String>()

        for (index, rawLine) in clean.split(separator: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "Quota:" else { continue }
            guard let parsed = parseRow(line) else { continue }

            let groupInfo = classifyGroup(parsed.group)
            let cadenceInfo = classifyCadence(parsed.label)
            let id = makeWindowID(prefix: groupInfo.prefix, suffix: cadenceInfo.suffix, rawLabel: parsed.label)
            guard seenIDs.insert(id).inserted else { continue }

            let groupKey = groupInfo.displayName.lowercased()
            let groupOrder = groupOrders[groupKey] ?? {
                let next = groupOrders.count
                groupOrders[groupKey] = next
                return next
            }()

            let window = LimitWindow(
                id: id,
                group: groupInfo.displayName,
                label: cadenceInfo.label,
                usedFraction: min(max((100.0 - parsed.remainingPercent) / 100.0, 0.0), 1.0),
                resetsAt: parsed.resetsAt,
                duration: cadenceInfo.duration
            )
            rows.append(ParsedRow(
                groupRank: groupInfo.rank,
                groupOrder: groupOrder,
                cadenceRank: cadenceInfo.rank,
                rowOrder: index,
                window: window
            ))
        }

        guard !rows.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }

        return rows
            .sorted { lhs, rhs in
                if lhs.groupRank != rhs.groupRank { return lhs.groupRank < rhs.groupRank }
                if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
                if lhs.cadenceRank != rhs.cadenceRank { return lhs.cadenceRank < rhs.cadenceRank }
                return lhs.rowOrder < rhs.rowOrder
            }
            .map(\.window)
    }

    private struct RawRow {
        let group: String
        let label: String
        let remainingPercent: Double
        let resetsAt: Date?
    }

    private static func parseRow(_ line: String) -> RawRow? {
        if line.contains("\t") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3 else { return nil }
            let group = columns[0]
            let label = columns[1]
            let percentText = columns[2]
            guard !group.isEmpty, !label.isEmpty, percentText.hasSuffix("%"),
                  let remaining = Double(percentText.dropLast()),
                  remaining.isFinite, (0...100).contains(remaining)
            else { return nil }
            let resetText = columns.count >= 4 ? columns[3] : ""
            let resetsAt: Date?
            if resetText.isEmpty {
                resetsAt = nil
            } else if let parsed = AntigravityCredentials.parse(resetText) {
                resetsAt = parsed
            } else {
                return nil
            }
            return RawRow(group: group, label: label, remainingPercent: remaining, resetsAt: resetsAt)
        }

        guard let percentIndex = line.lastIndex(of: "%") else { return nil }
        let left = line[..<percentIndex].trimmingCharacters(in: .whitespaces)
        let right = line[line.index(after: percentIndex)...].trimmingCharacters(in: .whitespaces)
        guard let lastSpace = left.lastIndex(where: \.isWhitespace) else { return nil }
        let descriptor = left[..<lastSpace].trimmingCharacters(in: .whitespaces)
        let numberText = left[left.index(after: lastSpace)...].trimmingCharacters(in: .whitespaces)
        guard let remaining = Double(numberText),
              remaining.isFinite, (0...100).contains(remaining)
        else { return nil }
        let resetsAt: Date?
        if right.isEmpty {
            resetsAt = nil
        } else if let parsed = AntigravityCredentials.parse(right) {
            resetsAt = parsed
        } else {
            return nil
        }

        let cleanDescriptor = descriptor.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let knownSuffixes = [
            "Five Hour Limit Remaining", "5-hour Limit Remaining", "Weekly Limit Remaining",
            "Five Hour Limit", "5-hour Limit", "Weekly Limit"
        ]
        for suffix in knownSuffixes {
            if cleanDescriptor.lowercased().hasSuffix(" " + suffix.lowercased()) {
                let splitPoint = cleanDescriptor.index(cleanDescriptor.endIndex, offsetBy: -suffix.count)
                let group = cleanDescriptor[..<splitPoint].trimmingCharacters(in: .whitespaces)
                let label = String(cleanDescriptor[splitPoint...])
                guard !group.isEmpty else { continue }
                return RawRow(group: group, label: label, remainingPercent: remaining, resetsAt: resetsAt)
            }
        }
        return nil
    }

    private static func classifyGroup(_ raw: String) -> (rank: Int, prefix: String, displayName: String) {
        let lower = raw.lowercased()
        if lower.contains("argon") {
            return (2, "gemini-argon", raw)
        }
        if lower.contains("gemini") {
            return (0, "gemini", L10n.t("Gemini Models"))
        }
        if lower.contains("claude") || lower.contains("gpt") {
            return (1, "3p", L10n.t("Claude and GPT models"))
        }
        let slug = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return (3, slug.isEmpty ? "quota" : slug, raw)
    }

    private static func classifyCadence(_ raw: String) -> (rank: Int, suffix: String?, label: String, duration: TimeInterval?) {
        var stripped = raw.trimmingCharacters(in: .whitespaces)
        if stripped.lowercased().hasSuffix(" remaining") {
            stripped = String(stripped.dropLast(" remaining".count)).trimmingCharacters(in: .whitespaces)
        }
        let lower = stripped.lowercased()
        if lower.contains("five hour") || lower.contains("five-hour") || lower.contains("5-hour") || lower.contains("5h") || lower.contains("hourly") {
            return (0, "5h", L10n.t("5-hour Limit"), 5 * 3600)
        }
        if lower.contains("weekly") {
            return (1, "weekly", L10n.t("Weekly Limit"), 7 * 86400)
        }
        return (2, nil, stripped.isEmpty ? L10n.t("Usage") : stripped, nil)
    }

    private static func makeWindowID(prefix: String, suffix: String?, rawLabel: String) -> String {
        if let suffix {
            return "\(prefix)-\(suffix)"
        }
        let slug = rawLabel.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? prefix : "\(prefix)-\(slug)"
    }
}
